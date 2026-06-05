# Model Settings UX — Design

**Date:** 2026-06-05
**Status:** Approved (design phase)

## Goal

Two related improvements to the local-model settings experience:

1. **Explicit "Download model" button** in Settings, so a model can be fetched
   (and verified cached) *before* the first transcription/analysis. Today every
   local model downloads lazily on first use, which makes the first recording
   confusingly slow with no opt-in moment.
2. **A subtle "Need some help?" disclosure** in the transcription settings that
   reveals per-engine model guidance, so users can choose an engine/model
   without external docs.

Scope covers all three downloadable local models: **WhisperKit** (ASR),
**Parakeet** (ASR), and **Gemma 4 E4B** (LLM, via MLX).

## Background / Current State

- Download is lazy. WhisperKit downloads inside
  `WhisperKitTranscriptionService.loadWhisperKit(config:)`
  (`Sources/dBrief/Services/WhisperKitTranscriptionService.swift:212`); Parakeet
  inside `ParakeetTranscriptionService.loadManager(for:)`
  (`:90`); Gemma inside `MLXInsightsService`.
- A prepare path exists but is unsuitable for the button:
  `LocalAIPluginService.prepareModelsIfNeeded()`
  (`Sources/dBrief/Services/LocalAIPluginService.swift:135`) calls
  `whisperService.prepareModelIfNeeded()`, which loads
  `WhisperRuntimeConfig.default` — a **hardcoded** `openai_whisper-small`
  (`Sources/dBrief/Services/LocalAIPluginProtocol.swift:28`), **not** the
  user-selected model. The button must download the *selected* model.
- Download progress already flows as `LocalAIPluginState.downloading(progress,
  stage)` on each service's `stateStream`, but is only consumed inside the
  recording pipeline (`RecordingManager.applyPluginState` / `applyParakeetState`,
  `Sources/dBrief/Services/RecordingManager.swift:1099` / `:1072`).
- The real runtime config is built from `appSettings.whisperModelName` at
  `RecordingManager.swift:1241`.
- `RecordingManager` already owns the service references, the symmetric
  `purgeLocal{Whisper,Parakeet,Qwen}Model()` wrappers, consumes both
  `stateStream`s, and is already injected via `.environment()`.
- Settings UI: `SettingsTranscriptionTab.swift` has per-engine sections (Whisper,
  Parakeet) each with a model picker, memory estimate, and a Purge button.
  Gemma's section lives in `SettingsAITab.swift:63`, gated behind
  `powerUserMode && aiEngine == .qwenLocal`.

## Chosen Approach

**Download state is owned by `RecordingManager`** (Approach A of three
considered). Rationale: it already owns the service references, the purge-wrapper
precedent, and the `stateStream` consumers, and it is already in the
environment — so download state placed there **survives settings tab switches**
(SwiftUI tears down an inactive tab's `@State`, which would otherwise cancel an
in-flight download). The alternatives were rejected: per-tab `@State` loses the
download on tab switch and duplicates streaming/cancel logic across three large
view files; a new environment `ModelDownloadCoordinator` adds wiring and a second
consumer of streams `RecordingManager` already reads, for a feature that fits
`RecordingManager` naturally.

## Components

### 1. Parameterized download in the service layer

- **WhisperKitTranscriptionService** — add
  `func prepareModel(config: WhisperRuntimeConfig) async throws` that downloads
  the given (selected) model via the existing `loadWhisperKit(config:)` path,
  then `unload()`. The existing `prepareModelIfNeeded()` (default config) stays
  for its current caller.
- **ParakeetTranscriptionService** — add `func prepareModel(variant:) async
  throws` that calls `loadManager(for:)` then unloads. Download progress already
  emits on its `stateStream`. (Add a Parakeet `unload()` if one is not present.)
- **MLXInsightsService** — already has `prepareModelIfNeeded()` (the Gemma model
  id is fixed); ensure it unloads after download so the button doesn't leave the
  model resident.
- **LocalAIPluginService** — add `downloadWhisperModel(config:) async throws` and
  `downloadLLMModel() async throws`, each run under the existing `AsyncMutex`.

### 2. `RecordingManager` download state (Approach A)

```swift
enum LocalModelKind { case whisper, parakeet, gemma }

enum ModelDownloadPhase: Equatable {
    case idle
    case downloading(progress: Double?, label: String)  // nil progress = indeterminate (loading)
    case failed(String)
}
```

- `var modelDownloads: [LocalModelKind: ModelDownloadPhase]` — observable; missing
  key == `.idle`.
- A stored cancel `Task` per kind.
- `downloadModel(_ kind:)` — builds the engine config from `appSettings` (Whisper
  config reusing the same construction as `RecordingManager.swift:1241`; Parakeet
  uses `appSettings.parakeetModelVariant`), spawns a task that consumes the
  engine's `stateStream`, maps `.downloading(progress, stage)` →
  `modelDownloads[kind]` via a pure helper, calls the matching
  `LocalAIPluginService` / `ParakeetTranscriptionService` download method, then
  resets to `.idle` (or `.failed(message)`).
- `cancelDownload(_ kind:)` — cancels the task, calls the service `unload()`,
  resets to `.idle`.
- `isModelCached(_ kind:) async -> Bool` — best-effort on-disk check (exposes
  WhisperKit's existing `isModelCached`; directory-exists for Parakeet/Gemma) to
  drive the "✓ Downloaded" state.
- **Guard:** downloads are disabled while a recording is processing (mutex / GPU
  contention); the button shows a tooltip explaining why.

### 3. Settings UI — `ModelDownloadButton`

A reusable view rendering from `recordingManager.modelDownloads[kind]`:

| State | Renders |
|-------|---------|
| not cached, idle | **Download model** button |
| cached, idle | "✓ Downloaded" (subtle) + **Re-download** link (purge-then-download) |
| downloading | determinate `ProgressView(value:)` + phase label + **Cancel** |
| failed | error text + **Retry** |

Placement: next to the existing Purge buttons —
- Whisper section and Parakeet section in `SettingsTranscriptionTab.swift`.
- Gemma section in `SettingsAITab.swift:63`, under the same
  `powerUserMode && aiEngine == .qwenLocal` gate as its purge button.

### 4. "Need some help?" disclosure

A `DisclosureGroup("Need some help?")` in the Engine section of the Transcription
tab (collapsed by default), expanding to a compact static comparison rendered in
subtle caption styling:

- **Whisper Large v3 Turbo** — recommended; multilingual; fast on Apple Silicon
- **Whisper Tiny** — low memory; less accurate
- **Whisper Distil** — English-only; fast
- **Parakeet** — strong on low-jargon speech; no diarization or language select
- **Apple Speech** — built-in; no download; lower quality
- **Remote** — bring-your-own server/API

Implemented as a small static view (e.g. `TranscriptionEngineGuide`).

## Data Flow

```
Click Download (Whisper)
  → RecordingManager.downloadModel(.whisper)
  → build WhisperRuntimeConfig from appSettings
  → LocalAIPluginService.downloadWhisperModel(config:)   [AsyncMutex]
  → WhisperKit.download(progressCallback:)
  → stateStream.yield(.downloading(progress, .whisperModel))
  → RecordingManager maps → modelDownloads[.whisper] = .downloading(progress, "Downloading…")
  → ProgressView(value:) updates
  → finish → unload() → modelDownloads[.whisper] = .idle
  → cached check flips row to "✓ Downloaded"

Cancel → task.cancel() + service unload() → modelDownloads[kind] = .idle
```

## Error Handling

- Download/network errors → `.failed(message)` shown inline with a **Retry**
  action.
- Cancel → silent reset to `.idle`.
- Active recording/processing → Download button disabled with an explanatory
  tooltip.

## Testing (swift-testing)

- Extract a **pure mapping** — `ModelDownloadPhase.from(pluginState:)` (and the
  stage→label text) — and unit-test it in a new `ModelDownloadTests.swift`
  covering: `.downloading` with a fractional progress, the indeterminate
  loading stage (nil progress), and idle/terminal transitions.
- The streaming/UI glue stays thin and is not unit-tested directly.
- A simple shape test asserts the engine-guide content is present/non-empty.

## Out of Scope (YAGNI)

- The **SpeakerKit diarization** model is not fetched by this button — only the
  ASR model. First diarized run still lazily downloads SpeakerKit.
- No background/queued downloads, no auto-download on engine/model change.
- No changes to the remote-endpoint flow (it has no local model to download).

## Touched Files

- `Sources/dBrief/Services/WhisperKitTranscriptionService.swift`
- `Sources/dBrief/Services/ParakeetTranscriptionService.swift`
- `Sources/dBrief/Services/MLXInsightsService.swift`
- `Sources/dBrief/Services/LocalAIPluginService.swift` (+ protocol)
- `Sources/dBrief/Services/RecordingManager.swift`
- `Sources/dBrief/UI/SettingsTranscriptionTab.swift`
- `Sources/dBrief/UI/SettingsAITab.swift`
- New: `ModelDownloadButton` view, `TranscriptionEngineGuide` view
- New: `Tests/dBriefTests/ModelDownloadTests.swift`
