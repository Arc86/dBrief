# Local Whisper Settings Declutter — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the Local Whisper section of the Transcription settings tab into a clean three-zone layout (model card + diarization + Advanced disclosure) with plain-language guidance, and make the fast Sep-24 Turbo (~626 MB) model the surfaced, recommended default.

**Architecture:** Add recommendation metadata and plain-language copy to the `WhisperModelInfo` value type and a friendly label to `WhisperComputeUnits` (both in `dBriefWire`, unit-tested). Change the new-user default in `AppSettings`. Then rebuild the `.localWhisper` branch of `SettingsTranscriptionTab` to consume that metadata — a model card, a per-model descriptor, a help popover, plain labels, and a collapsed `DisclosureGroup` for advanced controls. Finally sync the docs.

**Tech Stack:** Swift 6.2, SwiftUI, swift-testing (`@Test`/`#expect`), SPM (`dBriefWire` library target + `dBrief` app target).

**Spec:** [docs/superpowers/specs/2026-06-09-whisper-settings-declutter-design.md](../specs/2026-06-09-whisper-settings-declutter-design.md)

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `Sources/dBriefWire/Models/WhisperModelInfo.swift` | Model metadata value type | Add `recommendedModelID`, `isRecommended`, `plainDescription` |
| `Sources/dBriefWire/Models/WhisperComputeUnits.swift` | Compute-unit enum | Add `friendlyName` (`.all` → "Automatic") |
| `Sources/dBrief/App/AppSettings.swift` | User preferences | New-user `whisperModelName` default → recommended ID |
| `Sources/dBrief/UI/SettingsTranscriptionTab.swift` | Transcription settings UI | Add `showModelHelp` state; replace inline `.localWhisper` block with a `whisperSection`; extend curated filter |
| `Tests/dBriefTests/WhisperModelInfoTests.swift` | Model metadata tests | Add recommendation + plainDescription tests |
| `Tests/dBriefTests/WhisperComputeUnitsTests.swift` | Compute-unit tests (new) | friendlyName mapping |
| `CLAUDE.md`, `site/docs/transcription/local-whisper.md` | Docs | Reflect new default + relabeled controls |

---

## Task 1: Recommendation metadata + plain-language copy on `WhisperModelInfo`

**Files:**
- Modify: `Sources/dBriefWire/Models/WhisperModelInfo.swift` (append an extension after the `Comparable` extension, end of file)
- Test: `Tests/dBriefTests/WhisperModelInfoTests.swift`

- [ ] **Step 1: Write the failing tests**

Append these tests inside the `struct WhisperModelInfoTests { … }` body in `Tests/dBriefTests/WhisperModelInfoTests.swift` (before the closing brace):

```swift
    @Test("Recommended model ID is present in the fallback list")
    func testRecommendedModelInFallback() {
        #expect(WhisperModelInfo.fallbackModels.contains { $0.originalName == WhisperModelInfo.recommendedModelID })
    }

    @Test("Recommended model is flagged isRecommended; others are not")
    func testRecommendedFlag() {
        let rec = WhisperModelInfo.parse(WhisperModelInfo.recommendedModelID)
        #expect(rec.isRecommended)
        let small = WhisperModelInfo.parse("openai_whisper-small")
        #expect(!small.isRecommended)
    }

    @Test("Every fallback model has a non-empty plain description")
    func testPlainDescriptionNonEmpty() {
        for model in WhisperModelInfo.fallbackModels {
            #expect(!model.plainDescription.isEmpty)
        }
    }

    @Test("Recommended model's plain description mentions privacy")
    func testRecommendedDescriptionCopy() {
        let rec = WhisperModelInfo.parse(WhisperModelInfo.recommendedModelID)
        #expect(rec.plainDescription.contains("never leaves your device"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WhisperModelInfoTests`
Expected: FAIL — compile error, `recommendedModelID` / `isRecommended` / `plainDescription` are unresolved.

- [ ] **Step 3: Implement the extension**

Append to the end of `Sources/dBriefWire/Models/WhisperModelInfo.swift` (after the closing brace of the `Comparable` extension):

```swift
// MARK: - Recommendation & plain-language copy

extension WhisperModelInfo {
    /// The model dBrief recommends by default: the Sep-2024 large-v3 turbo,
    /// quantized to ~626 MB. Much faster than full large-v3 with comparable accuracy.
    public static let recommendedModelID = "openai_whisper-large-v3-v20240930_626MB"

    /// Whether this model is dBrief's recommended default.
    public var isRecommended: Bool { originalName == WhisperModelInfo.recommendedModelID }

    /// One-line, jargon-free description shown under the model card so a
    /// non-technical user can choose a model without knowing model internals.
    public var plainDescription: String {
        if isRecommended {
            return "Best balance of speed and accuracy for most Macs. Audio never leaves your device."
        }
        switch family {
        case "tiny", "base":
            return "Fastest and lightest. Good for quick notes; less accurate on tricky audio."
        case "small":
            return "Light and quick, with solid everyday accuracy and a small memory footprint."
        case "medium":
            return "More accurate than Small, a little slower and heavier."
        case "large-v2", "large-v3", "large-v3-v20240930", "large":
            return isTurbo
                ? "High accuracy with good speed. Uses more memory than the smaller models."
                : "Highest accuracy. Slowest and most memory-hungry — best with other apps closed."
        case "distil-large-v3":
            return "Distilled large model: near-large accuracy, lighter and faster."
        default:
            return "On-device Whisper model. Audio never leaves your Mac."
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WhisperModelInfoTests`
Expected: PASS (all WhisperModelInfoTests including the four new ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/dBriefWire/Models/WhisperModelInfo.swift Tests/dBriefTests/WhisperModelInfoTests.swift
git commit -m "feat: add recommended model + plain-language copy to WhisperModelInfo"
```

---

## Task 2: Friendly compute-unit label

**Files:**
- Modify: `Sources/dBriefWire/Models/WhisperComputeUnits.swift`
- Test: `Tests/dBriefTests/WhisperComputeUnitsTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/dBriefTests/WhisperComputeUnitsTests.swift`:

```swift
import Testing
import dBriefWire

struct WhisperComputeUnitsTests {
    @Test("friendlyName maps .all to Automatic, keeps technical names otherwise")
    func testFriendlyName() {
        #expect(WhisperComputeUnits.all.friendlyName == "Automatic")
        #expect(WhisperComputeUnits.cpuAndNeuralEngine.friendlyName == "Neural Engine")
        #expect(WhisperComputeUnits.cpuAndGPU.friendlyName == "Metal GPU")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WhisperComputeUnitsTests`
Expected: FAIL — compile error, `friendlyName` is unresolved.

- [ ] **Step 3: Implement `friendlyName`**

In `Sources/dBriefWire/Models/WhisperComputeUnits.swift`, add this computed property immediately after the existing `displayName` property (after its closing brace at line 15):

```swift
    /// Non-technical label. ".all" reads as "Automatic" (the smart default);
    /// the others keep their technical names for users who know them.
    public var friendlyName: String {
        switch self {
        case .all: "Automatic"
        default: displayName
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WhisperComputeUnitsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBriefWire/Models/WhisperComputeUnits.swift Tests/dBriefTests/WhisperComputeUnitsTests.swift
git commit -m "feat: add friendlyName (Automatic) to WhisperComputeUnits"
```

---

## Task 3: New-user default model → recommended

**Files:**
- Modify: `Sources/dBrief/App/AppSettings.swift:643-654`

No unit test: this default is read from `UserDefaults` inside `init`, and changing it does not alter existing users' persisted choices. Verified by build + the manual check in Step 3.

- [ ] **Step 1: Change the default branch**

In `Sources/dBrief/App/AppSettings.swift`, the `whisperModelName` initializer block currently reads:

```swift
        self.whisperModelName = {
            // New key takes priority
            if let name = defaults.string(forKey: Keys.whisperModelName), !name.isEmpty {
                return name
            }
            // Migrate from old enum-based key
            switch defaults.string(forKey: "whisperModelSize") ?? "" {
            case "small":  return "openai_whisper-small"
            case "medium": return "openai_whisper-medium"
            default:       return "openai_whisper-small"
            }
        }()
```

Change ONLY the `default:` line so that users who never picked a model get the recommended one (explicit `small`/`medium` migrations are preserved):

```swift
            case "small":  return "openai_whisper-small"
            case "medium": return "openai_whisper-medium"
            default:       return WhisperModelInfo.recommendedModelID
            }
```

(`WhisperModelInfo` is already in scope — `AppSettings.swift:4` imports `dBriefWire`.)

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Builds successfully.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/App/AppSettings.swift
git commit -m "feat: default new installs to the recommended Whisper model"
```

> Known, deliberate edge case (from the spec): a returning user who never changed the model has no persisted `whisperModelName`, so they will resolve to this new default on next launch and trigger a one-time ~626 MB download. Accepted rather than adding first-run plumbing.

---

## Task 4: Add help-popover state

**Files:**
- Modify: `Sources/dBrief/UI/SettingsTranscriptionTab.swift:18` (state var block)

- [ ] **Step 1: Add the state property**

In `SettingsTranscriptionTab`, after the line:

```swift
    @State private var showAllWhisperModels = false
```

add:

```swift
    @State private var showModelHelp = false
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Builds successfully (unused warning is fine until Task 5).

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/UI/SettingsTranscriptionTab.swift
git commit -m "chore: add showModelHelp state for Whisper model help popover"
```

---

## Task 5: Rebuild the `.localWhisper` view into three zones

**Files:**
- Modify: `Sources/dBrief/UI/SettingsTranscriptionTab.swift` — replace the inline `.localWhisper` switch arm (currently lines 101-214) and add a new `whisperSection` computed view.

This is a UI rebuild; verification is by building and visually checking the settings panel (no unit test).

- [ ] **Step 1: Replace the inline `.localWhisper` block with a reference**

In `engineSection`, the switch currently contains a large inline block starting at `case .localWhisper:` and ending just before `case .remoteEndpoint:`. Replace the **entire** `.localWhisper` arm (from `case .localWhisper:` through its closing `.onAppear { fetchWhisperModels() }`) with this single line:

```swift
            case .localWhisper:
                whisperSection
```

Leave the surrounding arms (`.appleSpeech`, `.parakeetLocal`, `.remoteEndpoint`) and the trailing `TranscriptionEngineGuideView()` unchanged.

- [ ] **Step 2: Add the `whisperSection` computed view**

Add this property to `SettingsTranscriptionTab`, immediately after the `parakeetSection` property (after its closing brace, around line 270):

```swift
    @ViewBuilder
    private var whisperSection: some View {
        @Bindable var settings = appSettings
        let selectedModel = whisperModels.first(where: { $0.id == settings.whisperModelName })

        VStack(alignment: .leading, spacing: 10) {
            // — Model group header with help popover —
            HStack(spacing: 6) {
                Text("Model")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    showModelHelp.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .popover(isPresented: $showModelHelp, arrowEdge: .bottom) {
                    Text("Smaller models are faster but less accurate. Larger models are more accurate but use more memory and time. When in doubt, keep the recommended one.")
                        .font(.callout)
                        .padding()
                        .frame(width: 260)
                }
            }

            // — Model card —
            if isFetchingWhisperModels && whisperModels.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading models…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .secondarySystemFill)))
            } else {
                let modelsToShow = showAllWhisperModels ? whisperModels : whisperModels.filter { model in
                    model.isRecommended ||
                    model.family == "tiny" || model.family == "small" || model.family == "medium" ||
                    (model.family == "large-v3" && !model.isTurbo && !model.isEnglishOnly && model.quantizedSizeMB == nil) ||
                    (model.family == "large-v3" && model.isTurbo && !model.isEnglishOnly && model.quantizedSizeMB == nil) ||
                    (model.family == "distil-large-v3" && !model.isTurbo && !model.isEnglishOnly && model.quantizedSizeMB == nil) ||
                    (model.family == "distil-large-v3" && model.isTurbo && !model.isEnglishOnly && model.quantizedSizeMB == nil)
                }

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(selectedModel?.displayName ?? settings.whisperModelName)
                                .font(.body).fontWeight(.semibold)
                            if selectedModel?.isRecommended == true {
                                Text("Recommended")
                                    .font(.caption2).fontWeight(.semibold)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.18))
                                    .foregroundStyle(Color.accentColor)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                        }
                        if let selectedModel {
                            Text("~\(formatMemory(selectedModel.estimatedMemoryMB)) memory")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Picker("", selection: $settings.whisperModelName) {
                        if modelsToShow.isEmpty {
                            Text("openai_whisper-small").tag("openai_whisper-small")
                        } else {
                            ForEach(modelsToShow, id: \.id) { model in
                                Text(model.isRecommended ? "\(model.displayName)  ·  Recommended" : model.displayName)
                                    .tag(model.id)
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .secondarySystemFill)))

                // — Per-model descriptor —
                if let selectedModel {
                    Text(selectedModel.plainDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // — Large-model safety warning —
                if let selectedModel, selectedModel.estimatedMemoryMB > 4_096 {
                    Label("Large models run best with other apps closed", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                // — Download status / action (wired) —
                ModelDownloadButton(kind: .whisper)
            }

            // — Diarization (plain label, jargon in caption) —
            Toggle(isOn: $settings.diarizationEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Identify different speakers")
                    Text("Diarization — labels who said what. Slower, uses ~500 MB more memory.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // — Advanced (collapsed) —
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Where it runs")
                            Text("Compute units. Leave on Automatic unless transcription fails on large models.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $settings.whisperComputeUnits) {
                            ForEach(AppSettings.WhisperComputeUnits.allCases, id: \.self) { unit in
                                Text(unit.friendlyName).tag(unit)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 200)
                    }

                    Toggle(isOn: $showAllWhisperModels) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show all models")
                            Text("Adds experimental, English-only, and quantized variants to the list.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Button {
                            fetchWhisperModels()
                        } label: {
                            Label("Refresh model list", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Refresh model list from HuggingFace")
                        Spacer()
                    }
                    if let error = whisperModelFetchError {
                        Label(error, systemImage: "wifi.slash")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Button("Purge local WhisperKit model") {
                        Task {
                            do {
                                try await recordingManager.purgeLocalWhisperModel()
                                purgeMessage = "Local WhisperKit model cache removed."
                            } catch {
                                purgeMessage = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    if let purgeMessage {
                        Text(purgeMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            }
            .font(.subheadline)
        }
        .onAppear { fetchWhisperModels() }
    }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: Builds successfully with no errors. (If the compiler reports the `.localWhisper` arm still contains stale code, the old inline block was not fully removed in Step 1 — remove it entirely.)

- [ ] **Step 4: Manual verification**

Run: `make app && open dBrief.app`
Then open **Settings → AI & Models → Transcription**, engine = Local Whisper, and confirm:
- The model appears as a **card** with name + (when recommended) a **Recommended** badge + `~… memory`.
- The **ⓘ** next to "Model" opens the help popover.
- A one-line **descriptor** sits under the card and changes when you switch models.
- **`openai_whisper-large-v3-v20240930` (Sep24, 626 MB)** appears in the picker with **Show all models OFF**, marked Recommended.
- "Identify different speakers" shows the diarization caption.
- **Advanced** starts **collapsed**; expanding it reveals Where it runs (default reads **Automatic**), Show all models, Refresh, and Purge.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/UI/SettingsTranscriptionTab.swift
git commit -m "feat: rebuild Local Whisper settings into model card + Advanced disclosure"
```

---

## Task 6: Sync documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `site/docs/transcription/local-whisper.md`

Per repo convention ([memory: keep docs & CLAUDE.md in sync]), update both. No new doc page is added, so `site/docs.js` NAV needs no change.

- [ ] **Step 1: Update `CLAUDE.md`**

In the WhisperKit row of the transcription-engines table (the `Local Whisper` row describing the dynamic model picker), append a sentence noting the recommended default. Find the sentence ending:

```
… Dynamic model picker fetches available models from HuggingFace at runtime with memory estimates; falls back to curated offline list. Optional SpeakerKit diarization. |
```

and change it to:

```
… Dynamic model picker fetches available models from HuggingFace at runtime with memory estimates; falls back to curated offline list. Recommended default is the Sep-2024 large-v3 turbo (~626 MB, `WhisperModelInfo.recommendedModelID`). Optional SpeakerKit diarization. |
```

Then, in the `SettingsTranscriptionTab` bullet under **UI Structure → SettingsView → AI & Models**, replace its description with one reflecting the new layout. Find:

```
**Transcription** (`SettingsTranscriptionTab`: engine, Whisper/Parakeet model picker + `ModelDownloadButton`, diarization, language, custom vocabulary, endpoints, chunking)
```

and change to:

```
**Transcription** (`SettingsTranscriptionTab`: engine; for Local Whisper a model **card** with Recommended badge + per-model plain-language descriptor + `ModelDownloadButton`, a help popover, diarization, and an **Advanced** disclosure holding compute units, "Show all models", refresh, and purge; plus language, custom vocabulary, endpoints, chunking)
```

- [ ] **Step 2: Update `site/docs/transcription/local-whisper.md`**

Replace the default-model sentence (line ~11):

```
The first time you use Local Whisper, dBrief downloads a model. The default model is **Whisper Small** (~2 GB). Models are stored at:
```

with:

```
The first time you use Local Whisper, dBrief downloads a model. The recommended default is **Whisper Large V3 Sep24 Turbo** (~626 MB) — fast, accurate, and light enough for most Macs. Models are stored at:
```

Then update the "Choosing a model" paragraph (line ~21) to describe the new card + Advanced layout. Replace:

```
In **Settings → AI & Models → Transcription**, the model picker lists available Whisper models with their approximate memory use. Smaller models (Tiny, Small) are faster and lighter; larger models (Medium, Large v3, Distil Large v3) are more accurate but need more memory and disk space. Enable **Show all models** (Power User Mode) to see the full list fetched from Hugging Face.
```

with:

```
In **Settings → AI & Models → Transcription**, the selected model appears as a card showing its name, approximate memory use, and a **Recommended** badge on the suggested model. A one-line description under the card explains the trade-off, and the **ⓘ** button next to *Model* gives a plain-language overview. Smaller models (Tiny, Small) are faster and lighter; larger models are more accurate but need more memory. Open **Advanced** to switch where the model runs (compute units), enable **Show all models** to see every variant fetched from Hugging Face, refresh the list, or purge the cached model.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md site/docs/transcription/local-whisper.md
git commit -m "docs: document Local Whisper settings redesign + recommended model"
```

---

## Task 7: Full verification

- [ ] **Step 1: Run the full test suite**

Run: `swift test`
Expected: All tests pass, including the new `WhisperModelInfoTests` and `WhisperComputeUnitsTests`.

- [ ] **Step 2: Release build sanity check**

Run: `swift build -c release`
Expected: Builds successfully.

- [ ] **Step 3: Final manual smoke test**

Run: `make app && open dBrief.app` and re-confirm the Task 5 Step 4 checklist in the live app.

---

## Self-Review Notes

- **Spec coverage:** Zone 1 (Task 5), Zone 2 guidance — ⓘ popover/descriptor/plain labels/Automatic (Tasks 1, 2, 5), Zone 3 recommended model + curated filter + default + copy fix (Tasks 1, 3, 5, 6), migration decision (Task 3 note), docs (Task 6). All covered.
- **Type consistency:** `recommendedModelID`, `isRecommended`, `plainDescription` (Task 1) and `friendlyName` (Task 2) are defined before they are consumed in Task 5. `formatMemory`, `fetchWhisperModels`, `whisperModelFetchError`, `purgeMessage`, `showAllWhisperModels` are pre-existing members of `SettingsTranscriptionTab`. `AppSettings.WhisperComputeUnits` is the existing typealias (`AppSettings.swift:172`).
- **Deviation from mockup (intentional):** the wired `ModelDownloadButton` provides the live "✓ Downloaded / Re-download / Download" status directly beneath the card rather than synthesizing a "Ready to use" line inside the card — this avoids re-implementing the button's cache-detection logic while keeping download state visible.
