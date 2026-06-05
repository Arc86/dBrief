# Model Settings UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an explicit, cancelable "Download model" button (with cached state) for WhisperKit, Parakeet, and Gemma local models in Settings, plus a "Need some help?" engine-comparison disclosure in the transcription settings.

**Architecture:** Download orchestration and observable progress state live on `RecordingManager` (already in the environment, already owns the service refs, purge wrappers, and `stateStream` consumers). New parameterized download methods on the transcription/LLM services download the *user-selected* model and emit existing `LocalAIPluginState.downloading` progress. A pure `ModelDownloadPhase.from(pluginState:)` mapping (unit-tested) feeds a reusable `ModelDownloadButton` SwiftUI view rendered next to each engine's Purge button.

**Tech Stack:** Swift 6.2, SwiftUI, swift-testing, WhisperKit, FluidAudio (Parakeet), MLX (Gemma), Swift Concurrency (actors, AsyncStream, Task).

---

## File Structure

**Create:**
- `Sources/dBrief/Models/ModelDownload.swift` — `LocalModelKind`, `ModelDownloadPhase`, the pure `from(pluginState:)` mapping, `DownloadStage.downloadLabel`, and the static `TranscriptionEngineGuide` content. Pure/`Sendable`, no `@MainActor` — so it is unit-testable.
- `Sources/dBrief/UI/ModelDownloadButton.swift` — the reusable `ModelDownloadButton` view + `TranscriptionEngineGuideView`.
- `Tests/dBriefTests/ModelDownloadTests.swift` — tests for the pure mapping and guide content.

**Modify:**
- `Sources/dBrief/Services/WhisperKitTranscriptionService.swift` — add `prepareModel(config:)`, `isModelDownloaded(name:)`.
- `Sources/dBrief/Services/ParakeetTranscriptionService.swift` — add `unload()`, `prepareModel(variant:)`, `isModelDownloaded()`.
- `Sources/dBrief/Services/MLXInsightsService.swift` — add `isModelDownloaded()`.
- `Sources/dBrief/Services/LocalAIPluginService.swift` — add `downloadWhisperModel(config:)`, `downloadLLMModel()`, `isWhisperModelCached(name:)`, `isLLMModelCached()`.
- `Sources/dBrief/Services/RecordingManager.swift` — add `modelDownloads` state, `downloadModel(_:forceRedownload:)`, `cancelDownload(_:)`, `isModelCached(_:)`, `canDownloadModels`.
- `Sources/dBrief/UI/SettingsTranscriptionTab.swift` — Whisper + Parakeet download buttons; guide disclosure.
- `Sources/dBrief/UI/SettingsAITab.swift` — Gemma download button.

**Note on concurrency safety:** the per-engine `stateStream` is consumed by the recording pipeline (`withPluginStepAdapter`) *and* by the new settings observer. They never overlap because downloads are disabled while `recordingState` is `.recording` or `.processing` (the `canDownloadModels` guard). This keeps each `AsyncStream` single-consumer at any moment.

---

## Task 1: Download model types + pure mapping (TDD)

**Files:**
- Create: `Sources/dBrief/Models/ModelDownload.swift`
- Test: `Tests/dBriefTests/ModelDownloadTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/dBriefTests/ModelDownloadTests.swift`:

```swift
import Testing
@testable import dBrief

@Suite("Model download mapping")
struct ModelDownloadTests {

    @Test("maps a fractional download to a determinate phase")
    func mapsDownloadingProgress() {
        let phase = ModelDownloadPhase.from(pluginState: .downloading(progress: 0.42, stage: .whisperModel))
        #expect(phase == .downloading(progress: 0.42, label: "Downloading…"))
    }

    @Test("maps the loading stage to an indeterminate phase")
    func mapsLoadingStageIndeterminate() {
        let phase = ModelDownloadPhase.from(pluginState: .downloading(progress: nil, stage: .whisperModelLoading))
        #expect(phase == .downloading(progress: nil, label: "Loading…"))
    }

    @Test("ignores non-download states")
    func ignoresNonDownloadStates() {
        #expect(ModelDownloadPhase.from(pluginState: .idle) == nil)
        #expect(ModelDownloadPhase.from(pluginState: .transcribing) == nil)
        #expect(ModelDownloadPhase.from(pluginState: .analyzing) == nil)
        #expect(ModelDownloadPhase.from(pluginState: .diarizing) == nil)
    }

    @Test("engine guide lists all six engines with non-empty content")
    func engineGuideContent() {
        let entries = TranscriptionEngineGuide.entries
        #expect(entries.count == 6)
        for entry in entries {
            #expect(!entry.title.isEmpty)
            #expect(!entry.detail.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ModelDownloadTests`
Expected: FAIL — `cannot find 'ModelDownloadPhase' in scope` / `cannot find 'TranscriptionEngineGuide' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/dBrief/Models/ModelDownload.swift`:

```swift
import Foundation

/// The three local models that can be explicitly downloaded from Settings.
enum LocalModelKind: Hashable, Sendable {
    case whisper
    case parakeet
    case gemma
}

/// UI-facing download state for a single local model.
enum ModelDownloadPhase: Equatable, Sendable {
    case idle
    /// `progress == nil` means indeterminate (e.g. compiling/loading a cached model).
    case downloading(progress: Double?, label: String)
    case failed(String)

    /// Pure mapping from a service `LocalAIPluginState` to a download phase.
    /// Returns `nil` for states that are not download progress (the caller
    /// should leave the current phase unchanged).
    static func from(pluginState state: LocalAIPluginState) -> ModelDownloadPhase? {
        switch state {
        case .downloading(let progress, let stage):
            return .downloading(progress: progress, label: stage.downloadLabel)
        case .idle, .transcribing, .newSegments, .diarizing, .analyzing:
            return nil
        }
    }
}

extension DownloadStage {
    /// Short user-facing label for the inline progress row.
    var downloadLabel: String {
        switch self {
        case .whisperModel, .llmModel, .parakeetModel:
            return "Downloading…"
        case .whisperModelLoading, .parakeetModelLoading:
            return "Loading…"
        case .speakerKitModel:
            return "Downloading speakers…"
        }
    }
}

/// One row in the "Need some help?" engine comparison.
struct EngineGuideEntry: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}

/// Static guidance shown in the transcription settings disclosure.
enum TranscriptionEngineGuide {
    static let entries: [EngineGuideEntry] = [
        EngineGuideEntry(title: "Whisper Large v3 Turbo",
                         detail: "Recommended. Multilingual and fast on Apple Silicon."),
        EngineGuideEntry(title: "Whisper Tiny",
                         detail: "Low memory, runs anywhere, but less accurate."),
        EngineGuideEntry(title: "Whisper Distil",
                         detail: "English-only, fast, smaller download."),
        EngineGuideEntry(title: "Parakeet",
                         detail: "Strong on clear, low-jargon speech. No diarization or language selection."),
        EngineGuideEntry(title: "Apple Speech",
                         detail: "Built in, no download. Lower quality than Whisper."),
        EngineGuideEntry(title: "Remote",
                         detail: "Bring your own Whisper server or API endpoint."),
    ]
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ModelDownloadTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Models/ModelDownload.swift Tests/dBriefTests/ModelDownloadTests.swift
git commit -m "feat(models): add model download phase types and engine guide"
```

---

## Task 2: Service-layer download + cache-check methods

**Files:**
- Modify: `Sources/dBrief/Services/WhisperKitTranscriptionService.swift`
- Modify: `Sources/dBrief/Services/ParakeetTranscriptionService.swift`
- Modify: `Sources/dBrief/Services/MLXInsightsService.swift`
- Modify: `Sources/dBrief/Services/LocalAIPluginService.swift`

> No new unit tests — these are actor methods that hit the network/disk. Verified via `swift build`. Logic is exercised end-to-end by Tasks 5–6.

- [ ] **Step 1: WhisperKit — add `prepareModel(config:)` and `isModelDownloaded(name:)`**

In `Sources/dBrief/Services/WhisperKitTranscriptionService.swift`, replace the existing `prepareModelIfNeeded()` (currently at `:183`) with both the original and the new method:

```swift
    func prepareModelIfNeeded() async throws {
        _ = try await loadWhisperKit(config: .default)
        await unload()
    }

    /// Download + verify the given (user-selected) model, then unload so it
    /// does not stay resident in memory. Unloads on failure too.
    func prepareModel(config: WhisperRuntimeConfig) async throws {
        do {
            _ = try await loadWhisperKit(config: config)
            await unload()
        } catch {
            await unload()
            throw error
        }
    }

    /// Best-effort on-disk check for whether the named model is cached.
    func isModelDownloaded(name: String) -> Bool {
        guard let base = try? whisperDownloadBaseURL() else { return false }
        return isModelCached(name: name, downloadBase: base)
    }
```

- [ ] **Step 2: Parakeet — add `unload()`, `prepareModel(variant:)`, `isModelDownloaded()`**

In `Sources/dBrief/Services/ParakeetTranscriptionService.swift`, add these methods to the actor (e.g. right after `purgeModels()` at `:86`):

```swift
    func unload() {
        asrManager = nil
        loadedVariant = nil
    }

    /// Download + load the given variant, then unload. Emits download progress
    /// on `stateStream`. Unloads on failure too.
    func prepareModel(variant: String) async throws {
        defer { stateContinuation.yield(.idle) }
        do {
            _ = try await loadManager(for: variant)
            unload()
        } catch {
            unload()
            throw error
        }
    }

    /// Coarse on-disk check: the FluidAudio model cache directory is non-empty.
    nonisolated func isModelDownloaded() -> Bool {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }
        let modelsDir = appSupport.appendingPathComponent("FluidAudio/Models")
        guard let contents = try? fm.contentsOfDirectory(atPath: modelsDir.path) else {
            return false
        }
        return !contents.isEmpty
    }
```

- [ ] **Step 3: MLX — add `isModelDownloaded()`**

In `Sources/dBrief/Services/MLXInsightsService.swift`, add this method to the actor (e.g. right after `prepareModelIfNeeded()` at `:38`):

```swift
    /// Coarse on-disk check: the MLX model cache directory is non-empty.
    func isModelDownloaded() -> Bool {
        guard let dir = try? llmDownloadBaseURL() else { return false }
        guard let contents = try? fileManager.contentsOfDirectory(atPath: dir.path) else {
            return false
        }
        return !contents.isEmpty
    }
```

- [ ] **Step 4: LocalAIPluginService — add download + cache wrappers**

In `Sources/dBrief/Services/LocalAIPluginService.swift`, add these methods to the actor (e.g. right after `prepareModelsIfNeeded()` at `:145`):

```swift
    /// Download the user-selected WhisperKit model (under the GPU mutex).
    func downloadWhisperModel(config: WhisperRuntimeConfig) async throws {
        try await mutex.withLock {
            defer { stateContinuation.yield(.idle) }
            await insightsService.unload()
            try await whisperService.prepareModel(config: config)
        }
    }

    /// Download the local Gemma LLM (under the GPU mutex).
    func downloadLLMModel() async throws {
        try await mutex.withLock {
            defer { stateContinuation.yield(.idle) }
            await whisperService.unload()
            try await insightsService.prepareModelIfNeeded()
        }
    }

    func isWhisperModelCached(name: String) async -> Bool {
        await whisperService.isModelDownloaded(name: name)
    }

    func isLLMModelCached() async -> Bool {
        await insightsService.isModelDownloaded()
    }
```

- [ ] **Step 5: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds (no errors).

- [ ] **Step 6: Commit**

```bash
git add Sources/dBrief/Services/WhisperKitTranscriptionService.swift Sources/dBrief/Services/ParakeetTranscriptionService.swift Sources/dBrief/Services/MLXInsightsService.swift Sources/dBrief/Services/LocalAIPluginService.swift
git commit -m "feat(services): add parameterized model download + cache checks"
```

---

## Task 3: RecordingManager download orchestration

**Files:**
- Modify: `Sources/dBrief/Services/RecordingManager.swift`

> Verified via `swift build`. The pure mapping it relies on is already tested in Task 1.

- [ ] **Step 1: Add download state storage**

In `Sources/dBrief/Services/RecordingManager.swift`, add stored properties to the class (near the other `private var` declarations around `:22`):

```swift
    /// Observable per-model download state, read by the Settings download buttons.
    var modelDownloads: [LocalModelKind: ModelDownloadPhase] = [:]
    private var downloadTasks: [LocalModelKind: Task<Void, Never>] = [:]
    private var downloadObservers: [LocalModelKind: Task<Void, Never>] = [:]
```

- [ ] **Step 2: Add the orchestration methods**

Add these methods next to the purge wrappers (after `purgeLocalParakeetModel()` at `:790`):

```swift
    /// True when models may be downloaded (no active recording/processing that
    /// would contend for the GPU mutex and the shared state stream).
    var canDownloadModels: Bool {
        appState.recordingState == .idle
    }

    /// Best-effort check for whether the model selected for `kind` is cached.
    func isModelCached(_ kind: LocalModelKind) async -> Bool {
        switch kind {
        case .whisper:
            return await localAIPluginService.isWhisperModelCached(name: appSettings.whisperModelName)
        case .parakeet:
            return parakeetService.isModelDownloaded()
        case .gemma:
            return await localAIPluginService.isLLMModelCached()
        }
    }

    /// Start downloading the selected model for `kind`. When `forceRedownload`
    /// is true the engine's cache is purged first so the model is re-fetched.
    func downloadModel(_ kind: LocalModelKind, forceRedownload: Bool = false) {
        guard canDownloadModels else { return }

        downloadObservers[kind]?.cancel()
        downloadTasks[kind]?.cancel()
        modelDownloads[kind] = .downloading(progress: nil, label: "Starting…")

        let stream = (kind == .parakeet)
            ? parakeetService.stateStream
            : localAIPluginService.stateStream

        downloadObservers[kind] = Task { @MainActor [weak self] in
            for await state in stream {
                guard let self else { return }
                if Task.isCancelled { return }
                if let phase = ModelDownloadPhase.from(pluginState: state) {
                    self.modelDownloads[kind] = phase
                }
            }
        }

        downloadTasks[kind] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.downloadObservers[kind]?.cancel() }
            do {
                if forceRedownload {
                    try? await self.purgeModel(kind)
                }
                switch kind {
                case .whisper:
                    let config = WhisperRuntimeConfig(
                        modelName: self.appSettings.whisperModelName,
                        language: self.appSettings.transcriptionLanguage.isEmpty ? nil : self.appSettings.transcriptionLanguage,
                        diarizationEnabled: false
                    )
                    try await self.localAIPluginService.downloadWhisperModel(config: config)
                case .parakeet:
                    try await self.parakeetService.prepareModel(variant: self.appSettings.parakeetModelVariant)
                case .gemma:
                    try await self.localAIPluginService.downloadLLMModel()
                }
                self.modelDownloads[kind] = .idle
            } catch is CancellationError {
                self.modelDownloads[kind] = .idle
            } catch {
                self.modelDownloads[kind] = .failed(error.localizedDescription)
            }
        }
    }

    /// Cancel an in-flight download and reset its row to idle.
    func cancelDownload(_ kind: LocalModelKind) {
        downloadObservers[kind]?.cancel()
        downloadObservers[kind] = nil
        downloadTasks[kind]?.cancel()
        downloadTasks[kind] = nil
        modelDownloads[kind] = .idle
    }

    private func purgeModel(_ kind: LocalModelKind) async throws {
        switch kind {
        case .whisper: try await purgeLocalWhisperModel()
        case .parakeet: try await purgeLocalParakeetModel()
        case .gemma: try await purgeLocalQwenModel()
        }
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/dBrief/Services/RecordingManager.swift
git commit -m "feat(recording): orchestrate cancelable model downloads with progress state"
```

---

## Task 4: `ModelDownloadButton` + guide view

**Files:**
- Create: `Sources/dBrief/UI/ModelDownloadButton.swift`

> Verified via `swift build`. SwiftUI glue, not unit-tested.

- [ ] **Step 1: Write the views**

Create `Sources/dBrief/UI/ModelDownloadButton.swift`:

```swift
import SwiftUI

/// Reusable download/cancel/cached control for a single local model.
/// Reads its state from `RecordingManager.modelDownloads[kind]`.
struct ModelDownloadButton: View {
    @Environment(RecordingManager.self) private var recordingManager
    let kind: LocalModelKind

    @State private var cached = false

    private var phase: ModelDownloadPhase {
        recordingManager.modelDownloads[kind] ?? .idle
    }

    private var phaseKey: String {
        switch phase {
        case .idle: return "idle"
        case .downloading: return "downloading"
        case .failed: return "failed"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch phase {
            case .idle:
                idleRow
            case .downloading(let progress, let label):
                downloadingRow(progress: progress, label: label)
            case .failed(let message):
                failedRow(message)
            }
        }
        .task(id: phaseKey) {
            cached = await recordingManager.isModelCached(kind)
        }
    }

    @ViewBuilder
    private var idleRow: some View {
        HStack(spacing: 8) {
            if cached {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Button("Re-download") {
                    recordingManager.downloadModel(kind, forceRedownload: true)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!recordingManager.canDownloadModels)
            } else {
                Button("Download model") {
                    recordingManager.downloadModel(kind)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!recordingManager.canDownloadModels)
            }
        }
        .help(recordingManager.canDownloadModels ? "" : "Unavailable while recording or processing")
    }

    private func downloadingRow(progress: Double?, label: String) -> some View {
        HStack(spacing: 8) {
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 160)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") {
                recordingManager.cancelDownload(kind)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    private func failedRow(_ message: String) -> some View {
        HStack(spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
            Spacer()
            Button("Retry") {
                recordingManager.downloadModel(kind)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }
}

/// Collapsed-by-default per-engine guidance for the transcription settings.
struct TranscriptionEngineGuideView: View {
    var body: some View {
        DisclosureGroup("Need some help?") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(TranscriptionEngineGuide.entries) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                            .font(.caption)
                            .fontWeight(.medium)
                        Text(entry.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        }
        .font(.caption)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/UI/ModelDownloadButton.swift
git commit -m "feat(ui): add reusable model download button and engine guide views"
```

---

## Task 5: Wire into the Transcription settings tab

**Files:**
- Modify: `Sources/dBrief/UI/SettingsTranscriptionTab.swift`

- [ ] **Step 1: Add the Whisper download button**

In `Sources/dBrief/UI/SettingsTranscriptionTab.swift`, in the `.localWhisper` case, insert the download button immediately before the existing "Purge local WhisperKit model" button (currently at `:180`). The lines before `Button("Purge local WhisperKit model")` should become:

```swift
                    ModelDownloadButton(kind: .whisper)

                    Button("Purge local WhisperKit model") {
```

- [ ] **Step 2: Add the Parakeet download button**

In the same file, in `parakeetSection`, insert the download button immediately before the existing "Purge local Parakeet model" button (currently at `:232`):

```swift
            ModelDownloadButton(kind: .parakeet)

            Button("Purge local Parakeet model") {
```

- [ ] **Step 3: Add the "Need some help?" disclosure**

In the same file, in `engineSection`, add the guide view at the end of the outer `VStack` — immediately after the closing brace of the `switch settings.transcriptionEngine { … }` block and before the `VStack`'s closing brace (the `switch` ends at `:203`, the `VStack`/function closes at `:204-205`). Result:

```swift
            case .remoteEndpoint:
                Text("Use a remote Whisper API or server. Requires an endpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TranscriptionEngineGuideView()
        }
    }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/UI/SettingsTranscriptionTab.swift
git commit -m "feat(settings): add Whisper/Parakeet download buttons and engine guide"
```

---

## Task 6: Wire into the AI & Models settings tab (Gemma)

**Files:**
- Modify: `Sources/dBrief/UI/SettingsAITab.swift`

- [ ] **Step 1: Add the Gemma download button**

In `Sources/dBrief/UI/SettingsAITab.swift`, inside the `if appSettings.powerUserMode, settings.aiEngine == .qwenLocal {` block (currently at `:63`), insert the download button immediately before the existing "Purge local Gemma model" button (`:64`):

```swift
                    if appSettings.powerUserMode, settings.aiEngine == .qwenLocal {
                        ModelDownloadButton(kind: .gemma)

                        Button("Purge local Gemma model") {
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Run the full test suite**

Run: `swift test`
Expected: PASS — all existing tests plus the four new `ModelDownloadTests`.

- [ ] **Step 4: Commit**

```bash
git add Sources/dBrief/UI/SettingsAITab.swift
git commit -m "feat(settings): add Gemma download button to AI & Models tab"
```

---

## Manual Verification (after all tasks)

1. `make run` to launch the app bundle.
2. Settings → Recording → engine **Local Whisper**: a **Download model** button appears under the model picker. Click it → inline determinate progress bar + **Cancel**. Let it finish → row shows **✓ Downloaded** + **Re-download**.
3. Click **Cancel** mid-download on a fresh model → returns to **Download model** (no crash).
4. Switch the engine picker to **Parakeet** and back, or switch settings tabs, mid-download → the progress continues (state lives on `RecordingManager`).
5. Engine section shows a collapsed **Need some help?** disclosure; expanding it lists all six engines.
6. Settings → AI & Models with **Power User Mode** on and engine **Gemma 4 E4B Local**: a **Download model** button appears above **Purge local Gemma model** (indeterminate spinner, since MLX reports no fraction).
7. Start a recording → download buttons are disabled with the "Unavailable while recording or processing" tooltip.

---

## Notes / Known Trade-offs

- **Re-download purges the whole engine cache.** `purgeLocalWhisperModel()` removes the entire WhisperKit cache dir, so re-downloading model A also clears model B. Acceptable for this rare action; a per-model delete is out of scope.
- **Parakeet/Gemma cached checks are coarse** (cache directory non-empty), per the spec's "best-effort" decision. Whisper's check is exact (folder named after the model).
- **Gemma progress is indeterminate** — MLX emits `.downloading(progress: nil, .llmModel)`, so the Gemma row shows a spinner, not a percentage bar. Expected.
- **SpeakerKit (diarization) is not downloaded** by the Whisper button — only the ASR model. First diarized run still fetches SpeakerKit lazily.
