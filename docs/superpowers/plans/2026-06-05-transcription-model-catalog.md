# Transcription Model Catalog (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Transcription settings engine/model pickers with a model-first card catalog (Default Model header, language picker, Recommended/Local/Cloud/Custom tabs, Speed/Accuracy ratings, per-card Download/Set-as-Default actions), as a presentation layer over the existing settings fields.

**Architecture:** A pure `TranscriptionModelCatalog` builds `TranscriptionModelDescriptor`s from a curated table (grounded in real WhisperKit variant ids) + custom endpoints + optionally the dynamic Whisper list. "Set as Default" writes the existing `transcriptionEngine`/`whisperModelName`/`parakeetModelVariant`/`defaultTranscriptionEndpointId` fields — no migration. The merged download system is re-keyed from `LocalModelKind` to a string descriptor id + `ModelDownloadTarget` so each card downloads its own model. New SwiftUI views (`RatingDotsView`, `TranscriptionModelCard`, `TranscriptionModelCatalogView`) render the catalog; `SettingsTranscriptionTab` hosts it and keeps the endpoint editor.

**Tech Stack:** Swift 6.2, SwiftUI, swift-testing, WhisperKit, FluidAudio (Parakeet), Swift Concurrency.

---

## File Structure

**Create:**
- `Sources/dBrief/Models/TranscriptionModelCatalog.swift` — descriptor type, enums, curated table, pure assembly + card-state + selection-mapping + rating-bucket logic.
- `Sources/dBrief/UI/RatingDotsView.swift` — the Speed/Accuracy dots+number control.
- `Sources/dBrief/UI/TranscriptionModelCard.swift` — one model card (badges, ratings, action, ⋯ menu, inline download).
- `Sources/dBrief/UI/TranscriptionModelCatalogView.swift` — header + language + tabs + list + Advanced; hosts the cards.
- `Tests/dBriefTests/TranscriptionModelCatalogTests.swift` — pure-logic tests.

**Modify:**
- `Sources/dBrief/Models/ModelDownload.swift` — add `ModelDownloadTarget`; remove now-unused `LocalModelKind`.
- `Sources/dBrief/Services/RecordingManager.swift` — re-key `modelDownloads` to `[String: ModelDownloadPhase]`; `downloadModel(id:target:forceRedownload:)`, `cancelDownload(id:)`, `isModelCached(id:target:)`, `cancelAllActiveDownloads()` over string keys.
- `Sources/dBrief/UI/ModelDownloadButton.swift` — take `id: String` + `target: ModelDownloadTarget` instead of `kind: LocalModelKind`.
- `Sources/dBrief/UI/SettingsAITab.swift` — update the Gemma button call site.
- `Sources/dBrief/UI/SettingsTranscriptionTab.swift` — host `TranscriptionModelCatalogView`; remove the engine/language/vocabulary/chunking sections; keep the endpoint editor.

---

## Task 1: Catalog data model + pure logic (TDD)

**Files:**
- Create: `Sources/dBrief/Models/TranscriptionModelCatalog.swift`
- Test: `Tests/dBriefTests/TranscriptionModelCatalogTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/dBriefTests/TranscriptionModelCatalogTests.swift`:

```swift
import Foundation
import Testing
@testable import dBrief

@Suite("Transcription model catalog")
struct TranscriptionModelCatalogTests {

    // MARK: card action state

    @Test("selected model shows Default Model")
    func selectedShowsDefault() {
        #expect(cardActionState(requiresDownload: true, isCached: true, isSelected: true) == .defaultModel)
        #expect(cardActionState(requiresDownload: false, isCached: true, isSelected: true) == .defaultModel)
    }

    @Test("uncached local model shows Download")
    func uncachedShowsDownload() {
        #expect(cardActionState(requiresDownload: true, isCached: false, isSelected: false) == .download)
    }

    @Test("cached-or-builtin unselected model shows Set as Default")
    func availableShowsSetDefault() {
        #expect(cardActionState(requiresDownload: true, isCached: true, isSelected: false) == .setAsDefault)
        #expect(cardActionState(requiresDownload: false, isCached: true, isSelected: false) == .setAsDefault)
    }

    // MARK: rating buckets

    @Test("rating buckets split at 8 and 5")
    func ratingBuckets() {
        #expect(ratingBucket(9.5) == .high)
        #expect(ratingBucket(8.0) == .high)
        #expect(ratingBucket(7.9) == .medium)
        #expect(ratingBucket(5.0) == .medium)
        #expect(ratingBucket(4.9) == .low)
    }

    // MARK: selection mapping

    @Test("each descriptor maps to the correct settings writes")
    func selectionMapping() {
        let apple = TranscriptionModelDescriptor.apple
        #expect(apple.selection == TranscriptionSelection(engine: .appleSpeech, whisperModelName: nil, parakeetVariant: nil, endpointID: nil))

        let whisper = TranscriptionModelDescriptor.whisper(
            variant: "openai_whisper-tiny", title: "Tiny", scope: .multilingual,
            sizeMB: 75, speed: 9.5, accuracy: 6.0, blurb: "x", categories: [.local])
        #expect(whisper.selection == TranscriptionSelection(engine: .localWhisper, whisperModelName: "openai_whisper-tiny", parakeetVariant: nil, endpointID: nil))

        let parakeet = TranscriptionModelDescriptor.parakeet(
            variant: "v2", title: "Parakeet V2", scope: .englishOnly,
            sizeMB: 474, speed: 9.9, accuracy: 9.4, blurb: "x", categories: [.local])
        #expect(parakeet.selection == TranscriptionSelection(engine: .parakeetLocal, whisperModelName: nil, parakeetVariant: "v2", endpointID: nil))

        let endpointID = UUID()
        let custom = TranscriptionModelDescriptor.custom(endpointID: endpointID, title: "My Server")
        #expect(custom.selection == TranscriptionSelection(engine: .remoteEndpoint, whisperModelName: nil, parakeetVariant: nil, endpointID: endpointID))
    }

    // MARK: assembly

    @Test("curated whisper entries absent from the available set are dropped")
    func assemblyDropsUnknownVariants() {
        let available: Set<String> = ["openai_whisper-tiny"]   // only tiny is "available"
        let descriptors = TranscriptionModelCatalog.descriptors(
            endpoints: [], availableWhisperVariants: available, showAllWhisper: false)
        let whisperIDs = descriptors.filter { $0.engine == .localWhisper }.map { $0.backingModelName }
        #expect(whisperIDs.contains("openai_whisper-tiny"))
        #expect(!whisperIDs.contains("openai_whisper-base"))   // base not in available set
        // Apple + Parakeet always present
        #expect(descriptors.contains { $0.engine == .appleSpeech })
        #expect(descriptors.contains { $0.engine == .parakeetLocal })
    }

    @Test("custom endpoints become custom descriptors")
    func assemblyAddsCustom() {
        let ep = Endpoint(name: "My Server", baseURL: "http://localhost:8080", modelName: "whisper-1")
        let descriptors = TranscriptionModelCatalog.descriptors(
            endpoints: [ep], availableWhisperVariants: [], showAllWhisper: false)
        let custom = descriptors.first { $0.engine == .remoteEndpoint }
        #expect(custom?.endpointID == ep.id)
        #expect(custom?.categories.contains(.custom) == true)
    }

    @Test("show-all merges dynamic whisper variants with nil ratings")
    func assemblyShowAll() {
        let available: Set<String> = ["openai_whisper-tiny", "openai_whisper-medium"]
        let descriptors = TranscriptionModelCatalog.descriptors(
            endpoints: [], availableWhisperVariants: available, showAllWhisper: true)
        // medium is not curated; with showAll it should appear with nil ratings
        let medium = descriptors.first { $0.backingModelName == "openai_whisper-medium" }
        #expect(medium != nil)
        #expect(medium?.speed == nil)
    }

    // MARK: isSelected

    @Test("isSelected matches current settings for each engine")
    func isSelectedMatching() {
        let whisper = TranscriptionModelDescriptor.whisper(
            variant: "openai_whisper-tiny", title: "Tiny", scope: .multilingual,
            sizeMB: 75, speed: 9.5, accuracy: 6.0, blurb: "x", categories: [.local])
        #expect(whisper.isSelected(engine: .localWhisper, whisperModelName: "openai_whisper-tiny", parakeetVariant: "v3", defaultEndpointID: nil))
        #expect(!whisper.isSelected(engine: .localWhisper, whisperModelName: "openai_whisper-base", parakeetVariant: "v3", defaultEndpointID: nil))
        #expect(!whisper.isSelected(engine: .appleSpeech, whisperModelName: "openai_whisper-tiny", parakeetVariant: "v3", defaultEndpointID: nil))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TranscriptionModelCatalogTests`
Expected: FAIL — `cannot find 'cardActionState'` / `'TranscriptionModelDescriptor'` in scope.

- [ ] **Step 3: Write the implementation**

Create `Sources/dBrief/Models/TranscriptionModelCatalog.swift`:

```swift
import Foundation

// MARK: - Enums

enum ModelLanguageScope: Sendable, Equatable { case englishOnly, multilingual, nativeApple }
enum ModelLocation: Sendable, Equatable { case onDevice, builtIn, cloud }
enum ModelCategory: Sendable, Hashable, CaseIterable { case recommended, local, cloud, custom }  // Hashable: used in a Set

enum CardActionState: Sendable, Equatable { case download, setAsDefault, defaultModel }
enum RatingBucket: Sendable, Equatable { case high, medium, low }

// MARK: - Card action state (pure)

/// Resolve the action a card should offer.
/// - selected → it's the current default
/// - needs download and not yet cached → Download
/// - otherwise (cached local, or built-in / custom) → Set as Default
func cardActionState(requiresDownload: Bool, isCached: Bool, isSelected: Bool) -> CardActionState {
    if isSelected { return .defaultModel }
    if requiresDownload && !isCached { return .download }
    return .setAsDefault
}

/// Color bucket for a 0–10 rating: green ≥ 8, yellow 5–8, red < 5.
func ratingBucket(_ value: Double) -> RatingBucket {
    if value >= 8 { return .high }
    if value >= 5 { return .medium }
    return .low
}

// MARK: - Selection mapping

/// The settings writes a descriptor performs when chosen as default.
struct TranscriptionSelection: Equatable, Sendable {
    var engine: AppSettings.TranscriptionEngine
    var whisperModelName: String?
    var parakeetVariant: String?
    var endpointID: UUID?
}

// MARK: - Descriptor

struct TranscriptionModelDescriptor: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let engine: AppSettings.TranscriptionEngine
    let backingModelName: String?   // whisper variant id / parakeet "v2"|"v3" / nil
    let endpointID: UUID?
    let languageScope: ModelLanguageScope
    let location: ModelLocation
    let sizeMB: Int?
    let speed: Double?
    let accuracy: Double?
    let blurb: String
    let categories: Set<ModelCategory>

    /// Whether choosing this card requires a prior download (local models only).
    var requiresDownload: Bool { location == .onDevice }

    var selection: TranscriptionSelection {
        switch engine {
        case .appleSpeech:
            return TranscriptionSelection(engine: .appleSpeech, whisperModelName: nil, parakeetVariant: nil, endpointID: nil)
        case .localWhisper:
            return TranscriptionSelection(engine: .localWhisper, whisperModelName: backingModelName, parakeetVariant: nil, endpointID: nil)
        case .parakeetLocal:
            return TranscriptionSelection(engine: .parakeetLocal, whisperModelName: nil, parakeetVariant: backingModelName, endpointID: nil)
        case .remoteEndpoint:
            return TranscriptionSelection(engine: .remoteEndpoint, whisperModelName: nil, parakeetVariant: nil, endpointID: endpointID)
        }
    }

    func isSelected(engine: AppSettings.TranscriptionEngine,
                    whisperModelName: String,
                    parakeetVariant: String,
                    defaultEndpointID: UUID?) -> Bool {
        guard self.engine == engine else { return false }
        switch engine {
        case .appleSpeech: return true
        case .localWhisper: return backingModelName == whisperModelName
        case .parakeetLocal: return backingModelName == parakeetVariant
        case .remoteEndpoint: return endpointID == defaultEndpointID
        }
    }

    // MARK: factories

    static let apple = TranscriptionModelDescriptor(
        id: "apple", title: "Apple Speech", engine: .appleSpeech, backingModelName: nil,
        endpointID: nil, languageScope: .nativeApple, location: .builtIn, sizeMB: nil,
        speed: nil, accuracy: nil,
        blurb: "Uses the native Apple Speech framework. Requires macOS 26.",
        categories: [.local])

    static func whisper(variant: String, title: String, scope: ModelLanguageScope,
                        sizeMB: Int?, speed: Double?, accuracy: Double?, blurb: String,
                        categories: Set<ModelCategory>) -> TranscriptionModelDescriptor {
        TranscriptionModelDescriptor(
            id: "whisper:\(variant)", title: title, engine: .localWhisper, backingModelName: variant,
            endpointID: nil, languageScope: scope, location: .onDevice, sizeMB: sizeMB,
            speed: speed, accuracy: accuracy, blurb: blurb, categories: categories)
    }

    static func parakeet(variant: String, title: String, scope: ModelLanguageScope,
                         sizeMB: Int?, speed: Double?, accuracy: Double?, blurb: String,
                         categories: Set<ModelCategory>) -> TranscriptionModelDescriptor {
        TranscriptionModelDescriptor(
            id: "parakeet:\(variant)", title: title, engine: .parakeetLocal, backingModelName: variant,
            endpointID: nil, languageScope: scope, location: .onDevice, sizeMB: sizeMB,
            speed: speed, accuracy: accuracy, blurb: blurb, categories: categories)
    }

    static func custom(endpointID: UUID, title: String) -> TranscriptionModelDescriptor {
        TranscriptionModelDescriptor(
            id: "custom:\(endpointID.uuidString)", title: title, engine: .remoteEndpoint,
            backingModelName: nil, endpointID: endpointID, languageScope: .multilingual,
            location: .cloud, sizeMB: nil, speed: nil, accuracy: nil,
            blurb: "Custom OpenAI-compatible endpoint.", categories: [.custom])
    }
}

// MARK: - Catalog assembly

enum TranscriptionModelCatalog {

    /// Curated local entries, ratings/sizes from the design (mockup) overlay.
    /// Whisper variant ids are real WhisperKit ids; entries absent from the
    /// available set are dropped at assembly time.
    static let curated: [TranscriptionModelDescriptor] = [
        .apple,
        .parakeet(variant: "v2", title: "Parakeet V2", scope: .englishOnly, sizeMB: 474,
                  speed: 9.9, accuracy: 9.4,
                  blurb: "NVIDIA's Parakeet V2, lightning-fast English-only transcription.",
                  categories: [.recommended, .local]),
        .parakeet(variant: "v3", title: "Parakeet V3", scope: .multilingual, sizeMB: 494,
                  speed: 9.9, accuracy: 9.4,
                  blurb: "Parakeet V3 with English and 25 European languages.",
                  categories: [.local]),
        .whisper(variant: "openai_whisper-tiny", title: "Tiny", scope: .multilingual, sizeMB: 75,
                 speed: 9.5, accuracy: 6.0, blurb: "Tiny model, fastest, least accurate.",
                 categories: [.local]),
        .whisper(variant: "openai_whisper-tiny.en", title: "Tiny (English)", scope: .englishOnly, sizeMB: 75,
                 speed: 9.5, accuracy: 6.5, blurb: "Tiny model optimized for English, fastest.",
                 categories: [.local]),
        .whisper(variant: "openai_whisper-base", title: "Base", scope: .multilingual, sizeMB: 142,
                 speed: 8.5, accuracy: 7.2, blurb: "Base model, good speed/accuracy balance.",
                 categories: [.local]),
        .whisper(variant: "openai_whisper-base.en", title: "Base (English)", scope: .englishOnly, sizeMB: 142,
                 speed: 8.5, accuracy: 7.5, blurb: "Base model optimized for English.",
                 categories: [.recommended, .local]),
        .whisper(variant: "openai_whisper-large-v3_turbo_934MB", title: "Large v3 Turbo (Quantized)",
                 scope: .multilingual, sizeMB: 934, speed: 7.5, accuracy: 9.5,
                 blurb: "Quantized Large v3 Turbo, faster with slightly lower accuracy.",
                 categories: [.recommended, .local]),
        .whisper(variant: "openai_whisper-large-v3_1550MB", title: "Large v3", scope: .multilingual, sizeMB: 1550,
                 speed: 3.0, accuracy: 9.8, blurb: "Large v3, very slow but most accurate.",
                 categories: [.local]),
        .whisper(variant: "distil-whisper_distil-large-v3_turbo_600MB", title: "Distil Large v3 Turbo",
                 scope: .englishOnly, sizeMB: 600, speed: 9.0, accuracy: 9.0,
                 blurb: "Distilled Large v3 Turbo, fast English-only.",
                 categories: [.local]),
    ]

    /// Build the full descriptor list for the current state.
    static func descriptors(endpoints: [Endpoint],
                            availableWhisperVariants: Set<String>,
                            showAllWhisper: Bool) -> [TranscriptionModelDescriptor] {
        var result: [TranscriptionModelDescriptor] = []

        for entry in curated {
            if entry.engine == .localWhisper, let variant = entry.backingModelName {
                if availableWhisperVariants.contains(variant) { result.append(entry) }
            } else {
                result.append(entry)   // apple + parakeet always
            }
        }

        if showAllWhisper {
            let curatedVariants = Set(curated.compactMap { $0.engine == .localWhisper ? $0.backingModelName : nil })
            for variant in availableWhisperVariants.sorted() where !curatedVariants.contains(variant) {
                let info = WhisperModelInfo.parse(variant)
                result.append(.whisper(
                    variant: variant, title: info.displayName,
                    scope: info.isEnglishOnly ? .englishOnly : .multilingual,
                    sizeMB: info.quantizedSizeMB, speed: nil, accuracy: nil,
                    blurb: "On-device WhisperKit model.", categories: [.local]))
            }
        }

        for ep in endpoints {
            result.append(.custom(endpointID: ep.id, title: ep.name.isEmpty ? ep.baseURL : ep.name))
        }

        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TranscriptionModelCatalogTests`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Models/TranscriptionModelCatalog.swift Tests/dBriefTests/TranscriptionModelCatalogTests.swift
git commit -m "feat(models): add transcription model catalog descriptors and pure logic"
```

End every commit message with this trailer (blank line, then the line):

```
Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```

---

## Task 2: RatingDotsView

**Files:**
- Create: `Sources/dBrief/UI/RatingDotsView.swift`

> SwiftUI glue — verified via `swift build`.

- [ ] **Step 1: Write the view**

Create `Sources/dBrief/UI/RatingDotsView.swift`:

```swift
import SwiftUI

/// A labelled 0–10 rating shown as five color-coded dots plus the numeric value.
/// Renders "—" when `value` is nil (unrated dynamic entries).
struct RatingDotsView: View {
    let label: String
    let value: Double?

    private var color: Color {
        guard let value else { return .secondary }
        switch ratingBucket(value) {
        case .high: return .green
        case .medium: return .yellow
        case .low: return .red
        }
    }

    /// Number of filled dots out of five (value/10 * 5, rounded).
    private var filledDots: Int {
        guard let value else { return 0 }
        return Int((value / 10.0 * 5.0).rounded())
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    Circle()
                        .fill(index < filledDots ? color : Color.secondary.opacity(0.25))
                        .frame(width: 6, height: 6)
                }
            }
            Text(value.map { String(format: "%.1f", $0) } ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/UI/RatingDotsView.swift
git commit -m "feat(ui): add RatingDotsView for model speed/accuracy ratings"
```

---

## Task 3: Re-key the download system to id + target

**Files:**
- Modify: `Sources/dBrief/Models/ModelDownload.swift`
- Modify: `Sources/dBrief/Services/RecordingManager.swift`
- Modify: `Sources/dBrief/UI/ModelDownloadButton.swift`
- Modify: `Sources/dBrief/UI/SettingsAITab.swift`
- Modify: `Sources/dBrief/UI/SettingsTranscriptionTab.swift` (call-site fix only; full replacement is Task 5)

> Verified via `swift build` + `swift test` (existing tests must still pass).

- [ ] **Step 1: Add `ModelDownloadTarget`, remove `LocalModelKind`**

In `Sources/dBrief/Models/ModelDownload.swift`, delete the `LocalModelKind` enum entirely and add `ModelDownloadTarget` in its place:

```swift
/// What to download for a given catalog card, and how.
enum ModelDownloadTarget: Sendable, Equatable {
    case whisper(modelName: String)
    case parakeet(variant: String)
    case gemma
}
```

Leave `ModelDownloadPhase`, `DownloadStage.downloadLabel`, `EngineGuideEntry`, and `TranscriptionEngineGuide` unchanged.

- [ ] **Step 2: Re-key RecordingManager download state and methods**

In `Sources/dBrief/Services/RecordingManager.swift`, change the stored properties (currently keyed by `LocalModelKind`):

```swift
    /// Observable per-model download state, keyed by catalog descriptor id.
    var modelDownloads: [String: ModelDownloadPhase] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var downloadObservers: [String: Task<Void, Never>] = [:]
```

Replace the whole block of `isModelCached(_:)` / `downloadModel(_:forceRedownload:)` / `cancelDownload(_:)` / `cancelAllActiveDownloads()` / `purgeModel(_:)` (the methods added in the prior feature) with these:

```swift
    /// Best-effort check for whether the model for `target` is cached.
    func isModelCached(target: ModelDownloadTarget) async -> Bool {
        switch target {
        case .whisper(let modelName):
            return await localAIPluginService.isWhisperModelCached(name: modelName)
        case .parakeet:
            return parakeetService.isModelDownloaded()
        case .gemma:
            return await localAIPluginService.isLLMModelCached()
        }
    }

    /// Start downloading `target`, tracked under `id`. When `forceRedownload`
    /// is true the engine's cache is purged first.
    func downloadModel(id: String, target: ModelDownloadTarget, forceRedownload: Bool = false) {
        guard canDownloadModels else { return }

        downloadObservers[id]?.cancel()
        downloadTasks[id]?.cancel()
        modelDownloads[id] = .downloading(progress: nil, label: "Starting…")

        let isParakeet: Bool = { if case .parakeet = target { return true } else { return false } }()
        let stream = isParakeet ? parakeetService.stateStream : localAIPluginService.stateStream

        downloadObservers[id] = Task { @MainActor [weak self] in
            for await state in stream {
                guard let self else { return }
                if Task.isCancelled { return }
                if let phase = ModelDownloadPhase.from(pluginState: state) {
                    self.modelDownloads[id] = phase
                }
            }
        }

        downloadTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if forceRedownload {
                    try? await self.purgeModel(target)
                }
                switch target {
                case .whisper(let modelName):
                    let config = WhisperRuntimeConfig(
                        modelName: modelName,
                        language: self.appSettings.transcriptionLanguage.isEmpty ? nil : self.appSettings.transcriptionLanguage,
                        diarizationEnabled: false
                    )
                    try await self.localAIPluginService.downloadWhisperModel(config: config)
                case .parakeet(let variant):
                    try await self.parakeetService.prepareModel(variant: variant)
                case .gemma:
                    try await self.localAIPluginService.downloadLLMModel()
                }
                self.downloadObservers[id]?.cancel()
                self.downloadObservers[id] = nil
                self.modelDownloads[id] = .idle
            } catch is CancellationError {
                self.downloadObservers[id]?.cancel()
                self.downloadObservers[id] = nil
                self.modelDownloads[id] = .idle
            } catch {
                self.downloadObservers[id]?.cancel()
                self.downloadObservers[id] = nil
                self.modelDownloads[id] = .failed(error.localizedDescription)
            }
        }
    }

    /// Cancel an in-flight download and reset its row to idle.
    func cancelDownload(id: String) {
        downloadObservers[id]?.cancel()
        downloadObservers[id] = nil
        downloadTasks[id]?.cancel()
        downloadTasks[id] = nil
        modelDownloads[id] = .idle
    }

    /// Cancel every in-flight model download (e.g. when a recording starts).
    func cancelAllActiveDownloads() {
        for (id, phase) in modelDownloads {
            if case .downloading = phase { cancelDownload(id: id) }
        }
    }

    private func purgeModel(_ target: ModelDownloadTarget) async throws {
        switch target {
        case .whisper: try await purgeLocalWhisperModel()
        case .parakeet: try await purgeLocalParakeetModel()
        case .gemma: try await purgeLocalQwenModel()
        }
    }
```

Leave `canDownloadModels` and the `purgeLocal*Model()` wrappers as they are. The `cancelAllActiveDownloads()` call already inside `startRecording()` stays.

- [ ] **Step 3: Update `ModelDownloadButton` to id + target**

Replace the property and all `recordingManager` calls in `Sources/dBrief/UI/ModelDownloadButton.swift`. Change the stored input and the three call sites:

```swift
struct ModelDownloadButton: View {
    @Environment(RecordingManager.self) private var recordingManager
    let id: String
    let target: ModelDownloadTarget

    @State private var cached = false

    private var phase: ModelDownloadPhase {
        recordingManager.modelDownloads[id] ?? .idle
    }
    // ... phaseKey unchanged ...

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // ... switch unchanged ...
        }
        .task(id: phaseKey) {
            cached = await recordingManager.isModelCached(target: target)
        }
    }
```

In `idleRow`, change the two button actions:
- `Re-download` → `recordingManager.downloadModel(id: id, target: target, forceRedownload: true)`
- `Download model` → `recordingManager.downloadModel(id: id, target: target)`

In `downloadingRow`, change Cancel → `recordingManager.cancelDownload(id: id)`.
In `failedRow`, change Retry → `recordingManager.downloadModel(id: id, target: target)`.
(Keep all layout/styling identical.)

- [ ] **Step 4: Update the Gemma call site**

In `Sources/dBrief/UI/SettingsAITab.swift`, change:

```swift
                        ModelDownloadButton(kind: .gemma)
```
to:
```swift
                        ModelDownloadButton(id: "gemma", target: .gemma)
```

- [ ] **Step 5: Fix the two transcription-tab call sites so it compiles**

In `Sources/dBrief/UI/SettingsTranscriptionTab.swift`, change the existing `ModelDownloadButton(kind: .whisper)` to:

```swift
                    ModelDownloadButton(id: "whisper:\(appSettings.whisperModelName)",
                                        target: .whisper(modelName: appSettings.whisperModelName))
```
and `ModelDownloadButton(kind: .parakeet)` to:
```swift
            ModelDownloadButton(id: "parakeet:\(appSettings.parakeetModelVariant)",
                                target: .parakeet(variant: appSettings.parakeetModelVariant))
```
(These call sites are removed entirely in Task 5; this keeps the build green meanwhile.)

- [ ] **Step 6: Build + test**

Run: `swift build`
Expected: Build succeeds.
Run: `swift test`
Expected: PASS (82 prior tests + the Task 1 catalog tests; the `ModelDownloadTests` still pass since they don't reference `LocalModelKind`).

- [ ] **Step 7: Commit**

```bash
git add Sources/dBrief/Models/ModelDownload.swift Sources/dBrief/Services/RecordingManager.swift Sources/dBrief/UI/ModelDownloadButton.swift Sources/dBrief/UI/SettingsAITab.swift Sources/dBrief/UI/SettingsTranscriptionTab.swift
git commit -m "refactor(download): key model downloads by descriptor id + target"
```

---

## Task 4: TranscriptionModelCard

**Files:**
- Create: `Sources/dBrief/UI/TranscriptionModelCard.swift`

> SwiftUI glue — verified via `swift build`.

- [ ] **Step 1: Write the card view**

Create `Sources/dBrief/UI/TranscriptionModelCard.swift`:

```swift
import SwiftUI

/// One model card in the transcription catalog. Renders metadata, ratings, and a
/// context-appropriate action (Download / Set as Default / Default Model), reading
/// download state from `RecordingManager.modelDownloads[descriptor.id]`.
struct TranscriptionModelCard: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(AppSettings.self) private var appSettings

    let descriptor: TranscriptionModelDescriptor
    /// Called when the user picks this model (Set as Default / a custom Configure tap).
    let onSelect: () -> Void
    /// Called for custom endpoints' edit/Configure action (nil for non-custom).
    var onConfigure: (() -> Void)? = nil

    @State private var cached = false

    private var phase: ModelDownloadPhase { recordingManager.modelDownloads[descriptor.id] ?? .idle }

    private var target: ModelDownloadTarget? {
        switch descriptor.engine {
        case .localWhisper: return descriptor.backingModelName.map { .whisper(modelName: $0) }
        case .parakeetLocal: return descriptor.backingModelName.map { .parakeet(variant: $0) }
        case .appleSpeech, .remoteEndpoint: return nil
        }
    }

    private var isSelected: Bool {
        descriptor.isSelected(
            engine: appSettings.transcriptionEngine,
            whisperModelName: appSettings.whisperModelName,
            parakeetVariant: appSettings.parakeetModelVariant,
            defaultEndpointID: appSettings.defaultTranscriptionEndpointId)
    }

    private var actionState: CardActionState {
        cardActionState(requiresDownload: descriptor.requiresDownload, isCached: cached, isSelected: isSelected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(descriptor.title).font(.headline)
                    metadataRow
                    if descriptor.speed != nil || descriptor.accuracy != nil {
                        HStack(spacing: 16) {
                            RatingDotsView(label: "Speed", value: descriptor.speed)
                            RatingDotsView(label: "Accuracy", value: descriptor.accuracy)
                        }
                    }
                }
                Spacer()
                actionArea
            }
            Text(descriptor.blurb).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .task(id: phase) {
            if let target { cached = await recordingManager.isModelCached(target: target) }
            else { cached = true }   // built-in / custom always "available"
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 12) {
            Label(scopeText, systemImage: scopeIcon).labelStyle(.titleAndIcon)
            if let sizeMB = descriptor.sizeMB {
                Label(formatSize(sizeMB), systemImage: "internaldrive")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var scopeText: String {
        switch descriptor.languageScope {
        case .englishOnly: return "English-only"
        case .multilingual: return "Multilingual"
        case .nativeApple: return "Native Apple"
        }
    }
    private var scopeIcon: String {
        descriptor.languageScope == .nativeApple ? "apple.logo" : "globe"
    }

    private func formatSize(_ mb: Int) -> String {
        mb >= 1000 ? String(format: "%.1f GB", Double(mb) / 1000.0) : "\(mb) MB"
    }

    @ViewBuilder
    private var actionArea: some View {
        switch phase {
        case .downloading(let progress, let label):
            HStack(spacing: 8) {
                if let progress {
                    ProgressView(value: progress).progressViewStyle(.linear).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(label).font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { recordingManager.cancelDownload(id: descriptor.id) }
                    .buttonStyle(.borderless).controlSize(.small)
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
                if let target {
                    Button("Retry") { recordingManager.downloadModel(id: descriptor.id, target: target) }
                        .buttonStyle(.borderless).controlSize(.small)
                }
            }
        case .idle:
            idleAction
        }
    }

    @ViewBuilder
    private var idleAction: some View {
        switch actionState {
        case .download:
            Button("Download") {
                if let target { recordingManager.downloadModel(id: descriptor.id, target: target) }
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(!recordingManager.canDownloadModels)
        case .setAsDefault:
            HStack(spacing: 6) {
                if descriptor.engine == .remoteEndpoint, let onConfigure {
                    Button("Configure", action: onConfigure).buttonStyle(.bordered).controlSize(.small)
                }
                Button("Set as Default", action: onSelect).buttonStyle(.bordered).controlSize(.small)
            }
        case .defaultModel:
            HStack(spacing: 6) {
                Text("Default Model").font(.caption).foregroundStyle(.secondary)
                if let target {
                    Menu {
                        Button("Re-download") {
                            recordingManager.downloadModel(id: descriptor.id, target: target, forceRedownload: true)
                        }
                        Button("Delete", role: .destructive) {
                            recordingManager.cancelDownload(id: descriptor.id)
                            Task { try? await purge(target) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
        }
    }

    private func purge(_ target: ModelDownloadTarget) async throws {
        switch target {
        case .whisper: try await recordingManager.purgeLocalWhisperModel()
        case .parakeet: try await recordingManager.purgeLocalParakeetModel()
        case .gemma: try await recordingManager.purgeLocalQwenModel()
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/UI/TranscriptionModelCard.swift
git commit -m "feat(ui): add TranscriptionModelCard with ratings, badges, and per-card download"
```

---

## Task 5: Catalog view + host in SettingsTranscriptionTab

**Files:**
- Create: `Sources/dBrief/UI/TranscriptionModelCatalogView.swift`
- Modify: `Sources/dBrief/UI/SettingsTranscriptionTab.swift`

> SwiftUI integration — verified via `swift build` + manual run.

- [ ] **Step 1: Write the catalog view**

Create `Sources/dBrief/UI/TranscriptionModelCatalogView.swift`:

```swift
import SwiftUI
import WhisperKit

/// The model-first transcription catalog: default-model header, language picker,
/// category tabs, model cards, and an inline Advanced section. Presentation layer
/// over the existing AppSettings selection fields.
struct TranscriptionModelCatalogView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager

    /// Opens the endpoint editor for a custom endpoint (nil = new).
    let onAddEndpoint: () -> Void
    let onEditEndpoint: (Endpoint) -> Void

    @State private var selectedTab: ModelCategory = .recommended
    @State private var whisperVariants: Set<String> = Set(WhisperModelInfo.fallbackModelNames)
    @State private var showAdvanced = false

    private var descriptors: [TranscriptionModelDescriptor] {
        TranscriptionModelCatalog.descriptors(
            endpoints: appSettings.transcriptionEndpoints,
            availableWhisperVariants: whisperVariants,
            showAllWhisper: appSettings.powerUserMode ? showAllModels : false)
    }

    @State private var showAllModels = false

    private var currentDefaultTitle: String {
        descriptors.first { $0.isSelected(
            engine: appSettings.transcriptionEngine,
            whisperModelName: appSettings.whisperModelName,
            parakeetVariant: appSettings.parakeetModelVariant,
            defaultEndpointID: appSettings.defaultTranscriptionEndpointId) }?.title
            ?? appSettings.transcriptionEngine.displayName
    }

    private var visibleCards: [TranscriptionModelDescriptor] {
        descriptors.filter { $0.categories.contains(selectedTab) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                languageSection
                tabBar
                if selectedTab == .cloud {
                    cloudPlaceholder
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(visibleCards) { descriptor in
                            TranscriptionModelCard(
                                descriptor: descriptor,
                                onSelect: { select(descriptor) },
                                onConfigure: descriptor.endpointID.flatMap { id in
                                    appSettings.transcriptionEndpoints.first { $0.id == id }
                                }.map { ep in { onEditEndpoint(ep) } })
                        }
                    }
                    if selectedTab == .custom {
                        customFooter
                    }
                }
                advancedSection
            }
            .padding(20)
        }
        .scrollContentBackground(.hidden)
        .task { await fetchWhisperVariants() }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Default Model").font(.caption).foregroundStyle(.secondary)
            Text(currentDefaultTitle).font(.title2).fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    private var languageSection: some View {
        @Bindable var settings = appSettings
        return VStack(alignment: .leading, spacing: 6) {
            Text("Transcription Language").font(.headline)
            Picker("Select Language", selection: $settings.transcriptionLanguage) {
                Text(settings.transcriptionEngine == .appleSpeech ? "Auto (System language)" : "Auto-detect").tag("")
                Divider()
                Text("English").tag("en")
                Text("Dutch").tag("nl")
                Text("German").tag("de")
                Text("French").tag("fr")
                Text("Spanish").tag("es")
                Text("Italian").tag("it")
                Text("Portuguese").tag("pt")
                Text("Japanese").tag("ja")
                Text("Chinese").tag("zh")
                Text("Korean").tag("ko")
                Text("Russian").tag("ru")
                Text("Arabic").tag("ar")
                Text("Hindi").tag("hi")
                Text("Polish").tag("pl")
                Text("Turkish").tag("tr")
                Text("Ukrainian").tag("uk")
                Text("Swedish").tag("sv")
                Text("Danish").tag("da")
                Text("Norwegian").tag("no")
            }
            .pickerStyle(.menu)
        }
    }

    private var tabBar: some View {
        Picker("", selection: $selectedTab) {
            Text("Recommended").tag(ModelCategory.recommended)
            Text("Local").tag(ModelCategory.local)
            Text("Cloud").tag(ModelCategory.cloud)
            Text("Custom").tag(ModelCategory.custom)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var cloudPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "cloud").font(.largeTitle).foregroundStyle(.secondary)
            Text("Cloud transcription providers are coming soon.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    private var customFooter: some View {
        VStack(spacing: 8) {
            Label("Only OpenAI-compatible transcription APIs are supported.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
            Button(action: onAddEndpoint) {
                Label("Add Model", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var advancedSection: some View {
        @Bindable var settings = appSettings
        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Speaker diarization", isOn: $settings.diarizationEnabled)
                Text("Identifies who said what. Adds processing time and ~500 MB memory.")
                    .font(.caption).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom vocabulary").font(.subheadline)
                    NativeTextField(placeholder: "e.g. Acme Corp, JIRA, Kubernetes", text: $settings.whisperPrompt)
                        .frame(height: 22)
                    Text("Helps Whisper recognize proper nouns and domain terms.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if appSettings.powerUserMode {
                    Toggle("Show all models", isOn: $showAllModels)
                }

                if appSettings.transcriptionEngine == .remoteEndpoint {
                    Toggle("Enable chunking for large files", isOn: $settings.remoteChunkingEnabled)
                }
            }
            .padding(.top, 8)
        }
        .font(.headline)
    }

    private func select(_ descriptor: TranscriptionModelDescriptor) {
        let s = descriptor.selection
        appSettings.transcriptionEngine = s.engine
        if let w = s.whisperModelName { appSettings.whisperModelName = w }
        if let p = s.parakeetVariant { appSettings.parakeetModelVariant = p }
        if s.engine == .remoteEndpoint { appSettings.defaultTranscriptionEndpointId = s.endpointID }
    }

    private func fetchWhisperVariants() async {
        if let names = try? await WhisperKit.fetchAvailableModels(from: "argmaxinc/whisperkit-coreml") {
            whisperVariants = Set(names)
        }
    }
}
```

- [ ] **Step 2: Host the catalog in `SettingsTranscriptionTab`**

In `Sources/dBrief/UI/SettingsTranscriptionTab.swift`, replace the `body`'s `else` branch (the whole `Form { … }`) with the catalog view, and delete the now-dead `engineSection`, `parakeetSection`, `languageSection`, `vocabularySection`, `chunkingSection` computed properties and the `fetchWhisperModels()` helper + whisper-fetch `@State` (`whisperModels`, `isFetchingWhisperModels`, `whisperModelFetchError`, `showAllWhisperModels`). Keep `endpointsSection`'s logic only if still referenced; the Custom tab now uses `onAddEndpoint`/`onEditEndpoint`. Keep `isEditing`, `editingEndpoint`, `isNew`, `endpointEditor`, `testAndLoadModels()`, and the endpoint `@State`.

The new `body`:

```swift
    var body: some View {
        if isEditing {
            endpointEditor
        } else {
            TranscriptionModelCatalogView(
                onAddEndpoint: {
                    editingEndpoint = Endpoint(name: "", baseURL: "http://localhost:8080", modelName: "whisper-1")
                    isNew = true
                    testResult = nil
                    availableModels = []
                    isEditing = true
                },
                onEditEndpoint: { endpoint in
                    editingEndpoint = endpoint
                    isNew = false
                    testResult = nil
                    availableModels = []
                    isEditing = true
                })
        }
    }
```

Note: when an endpoint is saved in `endpointEditor`'s Save button, it must also set `appSettings.defaultTranscriptionEndpointId` if it is the first endpoint, mirroring prior behavior; otherwise leave the Save logic unchanged. Remove the `import WhisperKit` from `SettingsTranscriptionTab.swift` if it is now unused (the catalog view imports it instead) — verify with the build.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: Build succeeds. If the compiler reports unused/dead helpers, delete them. If it reports `endpointsSection` or `endpointRow` are now unused, delete them too (the Custom tab renders endpoints as cards).

- [ ] **Step 4: Commit**

```bash
git add Sources/dBrief/UI/TranscriptionModelCatalogView.swift Sources/dBrief/UI/SettingsTranscriptionTab.swift
git commit -m "feat(settings): replace transcription engine pickers with model catalog"
```

---

## Task 6: Full verification

- [ ] **Step 1: Full test suite**

Run: `swift test`
Expected: PASS — all prior tests + `TranscriptionModelCatalogTests`.

- [ ] **Step 2: Build the app bundle**

Run: `swift build -c release`
Expected: Build succeeds.

- [ ] **Step 3: Commit (if any cleanup was needed)**

```bash
git add -A
git commit -m "chore: model catalog phase 1 cleanup" || echo "nothing to commit"
```

---

## Manual Verification (after all tasks)

1. `make run`. Settings → Recording shows the new catalog: a **Default Model** header reflecting the current selection, a **Transcription Language** picker, **Recommended/Local/Cloud/Custom** tabs.
2. **Recommended** lists Parakeet V2, Base (English), Large v3 Turbo (Quantized) with Speed/Accuracy dots.
3. **Local** lists Apple Speech + Parakeet v2/v3 + the curated Whisper models. An uncached model shows **Download** → inline progress → **Cancel** works → finishes to **Set as Default**.
4. **Set as Default** on a cached model updates the header and flips the card to **Default Model** with a **⋯** menu (Re-download / Delete).
5. **Cloud** shows the "coming soon" placeholder.
6. **Custom** shows existing endpoints as cards + **Add Model** (opens the endpoint editor) + the OpenAI-compatible note.
7. **Advanced** disclosure exposes diarization, custom vocabulary, show-all-models (power user), and chunking (when a remote endpoint is the default).
8. Start a recording → Download actions are disabled (`canDownloadModels`).

---

## Notes / Known Trade-offs

- **Presentation layer only** — selection still lives in `transcriptionEngine` + `whisperModelName`/`parakeetModelVariant`/`defaultTranscriptionEndpointId`; profiles unaffected.
- **Re-download / Delete purge the whole engine cache** (inherited from the merged download feature) — acceptable for these rare actions.
- **Curated ratings are editorial** (from the mockup); dynamic "show all" entries are unrated ("—").
- **Cloud tab is a placeholder** (Phase 2); **AI Analysis page** unchanged (Phase 3).
- Mockup models without a real WhisperKit variant (plain Large v2, unquantized 2.9 GB Large v3) are intentionally omitted; "Large v3" maps to `openai_whisper-large-v3_1550MB`, "Quantized Turbo" to `openai_whisper-large-v3_turbo_934MB`.
