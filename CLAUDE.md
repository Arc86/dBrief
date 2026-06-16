# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

dBrief is a macOS menu bar app (SwiftUI `MenuBarExtra`) for recording microphone and system audio, then automatically transcribing and analyzing recordings with AI. It generates summaries, action items, tags, and sentiment, and can export results to Markdown notes, Obsidian vaults, and eight integration destinations. Built as a Swift Package Manager executable (not an Xcode project).

## Build Commands

- **Build**: `swift build` (debug) or `swift build -c release`
- **Build app bundle**: `make app` (builds release `--arch arm64`, assembles `dBrief.app/` with Info.plist, icons, Metal shaders, and a bundled static `ffmpeg` in `Contents/MacOS/`, then signs it with a stable self-signed cert)
- **Run**: `swift run` or `make run` (builds and launches the app bundle)
- **Sign**: `make sign` (`codesign --deep` with a stable self-signed identity `dBrief Self-Signed`, auto-created/reused by `scripts/ensure-signing-cert.sh` so macOS TCC permissions — Screen Recording, etc. — survive app updates instead of resetting each release; falls back to ad-hoc `-` if the cert can't be created. Override `CODESIGN_IDENTITY=-` for pure ad-hoc, or with a Developer ID if you enroll)
- **Build DMG**: `make dmg` (builds the app, then a compressed `dBrief-<version>.dmg` with a drag-to-Applications symlink, for GitHub Releases)
- **Notarize** (optional, requires Apple Developer Program): `make notarize CODESIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=<profile>` — hardened-signs with `packaging/dBrief.entitlements`, notarizes + staples the app and DMG (removes the Gatekeeper prompt). Dormant unless a Developer ID identity is passed; see [RELEASING.md](RELEASING.md)
- **Clean**: `make clean` or `swift package clean`
- **Run tests**: `swift test`

The app version is the single source of truth in `Sources/dBrief/Resources/Info.plist` (`CFBundleShortVersionString`); the Makefile, About screen, and `UpdateService` all read it. Cutting a public release (version bump → DMG → GitHub tag → Homebrew tap) is documented in [RELEASING.md](RELEASING.md). dBrief is distributed self-signed (stable cert, for TCC permission persistence) but un-notarized, Apple Silicon only.

## Tests

Tests live in `Tests/dBriefTests/` and use the `swift-testing` framework (v0.6.0+):

- **ProfileBehaviorTests.swift** — Meeting profile overrides, import/export, default profile protection
- **WhisperPipelineTests.swift** — Recording finalization, title normalization, segment merging, file discovery
- **RichTranscriptBuilderTests.swift** — Word timestamp propagation, speaker ID propagation, filler word defaults
- **WhisperModelInfoTests.swift** — Model name parsing, memory estimation, turbo/quantized variants, sort ordering
- **AppleSpeechResultMapperTests.swift** — `SpeechAnalyzer` chunk→`TranscriptionResult` mapping: word-level timestamps, empty-run/chunk dropping, language normalization

## Architecture

### App Lifecycle & Dependency Wiring

`DBriefApp` (`Sources/dBrief/App/DBriefApp.swift`) is the `@main` entry point. It creates a single `AppContext` instance that owns all shared state and services. Dependencies are passed to SwiftUI views via `.environment()`. The app runs as `LSUIElement` (no dock icon by default), presenting a `MenuBarExtra` window and a separate settings `WindowGroup`.

### Core Object Graph

- **AppContext** — root object, creates and wires everything at launch; owns all services below
- **AppState** (`@Observable`) — recording state machine (`idle → recording → paused → processing`), processing step progress, current recording data, call detection state
- **AppSettings** (`@Observable`) — all user preferences persisted via `UserDefaults` with `didSet` observers; folder URLs use security-scoped bookmarks; integration tokens stored in Keychain via `KeychainHelper`. Split across extension files: `AppSettings+EffectiveSettings.swift` (profile-resolved computed properties), `AppSettings+Profiles.swift` (profile CRUD, import/export, factories), `AppSettings+Persistence.swift` (bookmark/endpoint/integration/profile persistence helpers)
- **RecordingManager** — orchestrates the full record → finalize → transcribe → AI → markdown → integration dispatch pipeline

### Source Layout

```
Sources/dBrief/
├── App/            # Entry point, AppContext, AppState, AppSettings (+ extension files)
├── Audio/          # Audio capture, mixing, file writing
├── Models/         # Data types: Endpoint, Recording, MeetingProfile, Integrations, etc.
├── Services/       # Business logic: transcription, AI, recording, integrations
├── UI/             # All SwiftUI views (menu bar, settings tabs, onboarding, overlays)
├── Utilities/      # Extensions, helpers (Keychain, multipart form, Obsidian formatting)
├── Resources/      # Info.plist, icons, fonts, third-party integration icons
└── Images/         # (excluded from target)
```

### Audio Capture (`Audio/`)

`AudioCaptureManager` handles two recording modes:
- **Mixed mode** (system audio + mic): uses `ScreenCaptureKit` for system audio via `SystemAudioCapture`, mic via `AVAudioEngine` through `MicrophoneCapture`. The two sources are captured to **separate per-track CAF/LPCM files** (`*.system.caf`, `*.mic.caf`) and mixed at finalization, not in real time.
- **Mic-only mode**: falls back to plain `AVAudioEngine` input tap when screen recording permission is denied (no system CAF is written).

**Important concurrency note**: Audio tap handlers must be created with `nonisolated static` methods to avoid inheriting `@MainActor` isolation, which would crash on the real-time audio thread. See `makeTapHandler()` and `makeMicTapHandler()` in `AudioCaptureManager`.

**Live input-device hot-swap + auto-follow**: mid-recording device/route changes are handled by one shared reconfigure path in `AudioCaptureManager` (`applyReconfigure(_:)`): stop/pause engine → remove tap → `AudioInputDeviceManager.applyInputDevice` → (toggle VPIO) → re-install tap (converting via `MicFormatConverter` when the new device format differs from `AudioTrackWriter.establishedFormat`) → restart (only if not user-paused, keyed off `pauseStartTime` not `engine.isRunning`, since a config-change may have already stopped the engine). The single in-progress mic CAF stays open throughout. Two callers feed it:
- **Manual**: `switchMicrophoneDevice(to:)` (the mic menu in `RecordingControlsView` via `RecordingManager.switchInputDevice(to:)`); the chosen device is treated as present so an enumeration race can't trigger the gone→default fallback.
- **Automatic**: two observers — `AVAudioEngineConfigurationChangeNotification` (object = the mic engine; input/device changes) and a `DefaultOutputDeviceMonitor` CoreAudio listener on `kAudioHardwarePropertyDefaultOutputDevice` (output-route changes) — funnel into one debounced (`reconfigureDebounceTask`, 400 ms), idempotent `scheduleReconfigure()`. The desired state is computed by the pure, unit-tested `MicReconfigurePlanner.decide(...)` (`MicReconfigurePlannerTests`): a pinned device stays while present, a **gone** pinned device (AirPods die) falls back to system default so capture never goes silent, "System Default" follows the new default, and VPIO is recomputed (`aecSetting && outputHasEchoPath && micOnly`). On an automatic switch, `AudioCaptureManager.statusNoteHandler` → `RecordingManager` sets a transient `AppState.recordingStatusNote` ("Switched to <device>") shown in `FloatingMiniPlayer`, auto-cleared after ~4 s. Observers install at mic-pipeline start, are removed in `stopRecording` (before the engine is nilled), gated off while paused, and reconciled once in `resumeRecording`.

The recording mode is chosen automatically by permission (mixed when Screen Recording is granted, mic-only otherwise) — there is no user-facing source toggle. Capture is per-track CAF/LPCM; the finalized master is **M4A/AAC (~96 kbps, 48 kHz stereo)**. The audio source toggle (mic vs. mixed) is not exposed in Settings; the **Settings → Recording** tab exposes input device, an acoustic echo cancellation toggle (`acousticEchoCancellation`), and a read-only Audio Quality summary (Power User Mode).

### Recording Finalization (`Services/RecordingFinalizer.swift`)

`finalize(tracks:…)` takes the separate captured CAF tracks (`CapturedTracks`) and, after recording stops:
1. Normalizes meeting title (sanitizes special chars)
2. Creates dated folder structure (`Recordings/YYYY/MM`)
3. Merges + transcodes the per-track CAFs to an M4A/AAC master via ffmpeg, applying DSP per track (mic: 80 Hz HPF, sidechain duck vs. system, -16 LUFS loudnorm; system: 40 Hz HPF, 12 kHz LPF; mix: `amix` normalize). Acoustic echo cancellation (`echoSuppressionEnabled`) ducks mic against the system reference.

**Echo-cancellation route gating**: echo cancellation (real-time Voice Processing in mic-only mode, offline sidechain duck in mixed mode) only helps when speaker output bleeds into the mic. On headphones/earphones (incl. AirPods) or any non-built-in output there's no echo path, and Voice Processing needlessly ducks output + applies AGC — the audible "volume gets much lower on earphones" symptom. `AudioOutputRoute.echoPathExists(transportType:dataSource:)` (pure, unit-tested in `AudioOutputRouteTests`) returns `true` only for built-in speakers (`kAudioDeviceTransportTypeBuiltIn`, and not the `'hdpn'` headphone data source); `AudioOutputRoute.currentOutputHasEchoPath()` wraps the CoreAudio query (default output device → transport type + data source), defaulting to `true` when undeterminable. **Two consumers with different lifetimes:** (1) the **live VPIO** path — `RecordingManager` passes the *raw* `acousticEchoCancellation` setting into capture, and `AudioCaptureManager` re-gates dynamically on the output route (the `DefaultOutputDeviceMonitor` → `scheduleReconfigure` path toggles `setVoiceProcessingEnabled` mid-recording when you move between speakers and headphones; toggling requires `engine.stop()` and shifts the node format, so the converting tap engages automatically). (2) the **offline mixed-mode sidechain duck** — `RecordingManager.startRecording` still computes `echoCancellationActive = setting && currentOutputHasEchoPath()` once and freezes it on the session-only `Recording.echoSuppressionApplied`, because that ffmpeg filter is all-or-nothing over the whole mic track.
4. Auto-segments files >30 minutes into 30-minute chunks (`_partNN.m4a`)
5. Writes JSON metadata sidecar with duration, warnings, and segment file names
6. If ffmpeg is unavailable (or merge fails), falls back to promoting a raw CAF track to the master path (no AAC encode); segmentation is then skipped

Final file naming: `YYYY-MM-DD_HHMM_[meeting-title].m4a`

### Transcription Engines (`Services/`)

Four transcription backends selected via `AppSettings.transcriptionEngine`:

| Engine | Class | Backend |
|--------|-------|---------|
| Apple Speech | `AppleSpeechAnalyzerService` (macOS 26+) / `LocalTranscriptionService` (older) | Auto-selects per machine — one "Apple Speech" engine, no extra picker entry. macOS 26+ uses the modern `SpeechAnalyzer`/`SpeechTranscriber` (native `AVAudioFile` loading, word-level timestamps from the `audioTimeRange` run attribute, on-demand language-asset download via `AssetInventory` surfaced as a "Preparing language…" step); macOS 14–25, or a locale `SpeechTranscriber` doesn't support, falls back to the legacy `SFSpeechRecognizer`. Both share `OggOpusConverter` for `.ogg`/`.opus`→WAV via ffmpeg. The result→`TranscriptionResult` mapping is the pure, unit-tested `AppleSpeechResultMapper` in `dBriefWire`. |
| Local Whisper | `WhisperKitTranscriptionService` (via `LocalAIPluginService`) | On-device CoreML Whisper via the `WhisperKit` product of the `argmax-oss-swift` SDK (1.0.0). Loads audio natively (FLAC/WAV/M4A via AVFoundation — no ffmpeg needed). Uses WhisperKit's per-component compute defaults (mel→GPU, encoder→ANE, decoder→ANE). VAD chunking enabled. Downloads models to `AppSupport/dBrief/LocalAIPlugin/WhisperKit/`. Supports progressive segment streaming via `segmentDiscoveryCallback`. Dynamic model picker fetches available models from HuggingFace at runtime with memory estimates; falls back to curated offline list. Recommended default is the Sep-2024 large-v3 turbo (~632 MB, `WhisperModelInfo.recommendedModelID`). Optional SpeakerKit diarization. **Prompt-suppression guard**: the service still accepts an `initialPrompt` (fed to Whisper as `promptTokens`), but the **app no longer sends the custom vocabulary there** — an out-of-domain prompt makes Whisper emit *blank* text for most windows (segments keep time ranges but lose text — silent ~90% loss; vocabulary spelling now happens post-transcription, see Custom vocabulary). As defense-in-depth for any caller that does pass a prompt, `transcribe()` detects collapse (>50% of ≥4 segments empty after a prompted pass) and re-transcribes once **without** the prompt, keeping whichever pass has more non-empty text. |
| Parakeet TDT (Local) | `ParakeetTranscriptionService` (via `FluidAudio` framework) | On-device CoreML nvidia/parakeet-tdt-0.6b (v2 or v3). Downloads models from `argmaxinc/parakeetkit-coreml`. Handles long files natively (no segmentation). Loads audio to 16 kHz mono `[Float]` via FluidAudio's `AudioConverter` and **appends ~1 s of trailing silence before ASR** so sentence-final punctuation isn't dropped at the sequence boundary (falls back to the file-based path for very long audio to preserve the disk-backed memory route). Emits **word-level segments** built from FluidAudio's `ASRResult.tokenTimings` (grouped on the `▁`/space SentencePiece boundary, split into segments on >1 s pauses; falls back to a single full-file segment when timings are absent). Does **not** support language selection. **Supports speaker diarization** via the shared SpeakerKit path (see Speaker Diarization). Reports download/load progress via the same `AsyncStream<LocalAIPluginState>` pattern as `LocalAIPluginService`. |
| Remote Endpoint | `TranscriptionService` | OpenAI-compatible `/v1/audio/transcriptions` (incl. **Groq Whisper** as a preset) and `whisper-asr-webservice` `/asr` (auto-detected via `Endpoint.isWhisperASR`); chunked upload for large files via `AudioChunker`. Also native **Deepgram** (`/v1/listen`, `Token` auth, word timestamps + `diarize`) and **ElevenLabs Scribe** (`/v1/speech-to-text`, `xi-api-key`) adapters selected by `Endpoint.provider`; their responses map to `TranscriptionResult` via the pure, unit-tested `CloudASRMappers`, and they bypass `AudioChunker` (long audio handled server-side). Providers are added via the curated `ProviderPresets` picker in Settings → Transcription. |

After transcription, **all** engines' results pass through the engine-agnostic `TranscriptCleanup` (in `dBriefWire`, called once in `RecordingManager.transcribeRecordingAudio`): it strips hallucination/markup noise (XML-ish tags, `[…]`/`{…}`/`*…*` non-speech annotations, leading/trailing dash runs) and normalizes whitespace always; removes filler words (um, uh, …) only when `AppSettings.removeFillerWords` is on (default off); and drops **ignored segments** — whole segments whose cleaned text exactly matches a known filler phrase — when `AppSettings.removeIgnoredSegments` is on (default **on**). The ignore set is `TranscriptCleanup.defaultIgnoredSegments` (curated Whisper/YouTube silence-hallucinations like "Thank you for watching", "Subscribe to the channel", "♪" — meeting-safe, excludes ambiguous bare words) unioned with `AppSettings.customIgnoredSegments` (user-added; "Reset to Defaults" clears them). Matching is whole-segment and case/punctuation-insensitive via `normalizeForIgnoreMatch`, so real speech merely *containing* a phrase is kept; when a segment is dropped the flat `text` is rebuilt from survivors. Resolved via `AppSettings.effectiveIgnoredSegments`. All configured in **Settings → Transcription → Cleanup**.

### AI Processing (`Services/`)

Four AI backends selected via `AppSettings.aiEngine`:

| Engine | Class | Backend |
|--------|-------|---------|
| Apple Intelligence | `LocalAIService` | On-device via `FoundationModels` framework. Guarded by `#if canImport(FoundationModels)` and `@available(macOS 26, *)`. Only available on Apple Silicon with macOS 26+. Uses **guided generation** (`@Generable`/`@Guide`) to produce one structured `LocalInsightsResult` in a single call (summary, action items, tags, sentiment, inline title) — like the Gemma/Local-CLI unified path, sharing `UnifiedInsightsPrompt.systemPromptForGuidedGeneration`. Tight ~12K-char transcript budget for the ~4K-token window; `GenerationOptions(temperature: 0.3)`; specific availability messaging via `SystemLanguageModel.availability`. |
| Gemma 4 E4B Local | `MLXInsightsService` (via `LocalAIPluginService`) | On-device `mlx-community/gemma-4-e4b-4bit` via `mlx-swift-lm` 3.x. Downloads models to `AppSupport/dBrief/LocalAIPlugin/MLX/`. Supports streaming output. Uses KV cache quantization (`kvBits: 8`). Strips `<think>…</think>` blocks before JSON parsing (model uses thinking mode). **Note**: the enum case is historically named `AIEngine.qwenLocal` (UI display name "Gemma 4 E4B Local") — it now loads Gemma, not Qwen. |
| Remote Endpoint | `AIService` | OpenAI-compatible `/v1/chat/completions` (OpenAI, **Groq**, **Gemini** via Google's OpenAI-compatible endpoint, Ollama — all presets) plus native **Anthropic** `/v1/messages` (`x-api-key` + `anthropic-version`, `content[0].text` / `content_block_delta` streaming) selected by `Endpoint.provider`. Endpoints are added via the curated `ProviderPresets` picker in Settings → AI Analysis. Three separate calls (summary, action items, tags+sentiment), each sent the **full, untruncated** transcript (unlike the local unified path's ~12K-char budget) — so a long meeting can exceed a small-context server's window. **Reasoning & error handling**: for recognized reasoning models, `ReasoningConfig` merges chain-of-thought-suppressing params (`reasoning_effort`, `reasoning_format: hidden`, `chat_template_kwargs.enable_thinking`) into the OpenAI-compatible body; every request also sends `max_tokens: AIService.maxResponseTokens` (4096 — enough for the short outputs + a `<think>` block, modest enough to avoid `prompt + max_tokens` overflow on strict servers like vLLM). Responses pass through pure, unit-tested helpers — `cleanContent` strips any inline `<think>…</think>` block left in `content`, `parseTags` extracts JSON via the shared `LocalInsightsDecoder.extractFirstJSONObject` (tolerates think blocks + Markdown code fences), `parseActionItems` accepts `-`/`*`/`•`/numbered markers, and `parseAnthropicText` concatenates Anthropic `content[].text`. Error mapping: a context-overflow server body (`isContextOverflow`, matches llama.cpp/vLLM/OpenAI phrasings) → `AIServiceError.contextWindowExceeded` with an "increase your server's context size" hint; a null/empty `content` with `finish_reason: "length"` or a `reasoning_content` field → `AIServiceError.truncatedResponse`; otherwise `serverError(code, body)`. |
| Local CLI | `LocalCLIService` | Shells out to a user-configured command (e.g. `claude -p "$DBRIEF_FULL_PROMPT"`, `ollama run …`, `llm …`) via a login shell (`/bin/zsh -l -c`) so PATH tools resolve. One unified call per recording returning the same JSON contract as Gemma. Prompts are exported as `DBRIEF_SYSTEM_PROMPT` / `DBRIEF_USER_PROMPT` / `DBRIEF_FULL_PROMPT` env vars and piped to stdin; output parsed via `LocalInsightsDecoder.decodeAndNormalize` (in `dBriefWire`). Config (`LocalCLIConfig`: command + timeout) is global, persisted as JSON in UserDefaults. |

AI tasks run sequentially after transcription: summary → action items → tags/sentiment → title generation → markdown export. All AI steps can be skipped via `AppSettings.aiProcessingEnabled = false`.

**Custom vocabulary** (`AppSettings.effectiveWhisperPrompt`) is used in three places, but **not** as a Whisper/ASR decoder prompt — that path was removed because an out-of-domain (or even on-domain) prompt makes Whisper emit blank output for most windows, silently dropping the bulk of the transcript (OpenAI's own guidance recommends post-processing over prompt injection). The three uses are:
1. **Transcript spell-correction** (`TranscriptSpellingService`, run in `RecordingManager.transcribeRecordingAudio` after `TranscriptCleanup`): the active AI engine is asked for a bounded `[{from,to}]` correction list, which the pure, unit-tested `VocabularyCorrection.apply(_:vocabulary:to:)` (in `dBriefWire`) applies as validated whole-word, case-insensitive replacements — `to` must be one of the vocabulary terms, so the model can never drop or reformat transcript content. No-op when vocabulary is empty or no AI engine resolves. Local CLI routes to `chatFallbackEngine`; Apple Intelligence truncates the transcript for its ~4K window.
2. **AI analysis**: injected as a "spell these exactly" `### DOMAIN-SPECIFIC TERMS` block into every analysis path — `UnifiedInsightsPrompt.vocabularyBlock` / the `customVocabulary` params on `systemPrompt(…)` and `systemPromptForGuidedGeneration(…)` for the unified engines (threaded to the Gemma helper via `MLRequest.analyze`/`.analyzeStream`), and appended to the remote per-task system prompts in `RecordingManager.withVocabulary`.
Custom vocabulary is **not** sent as an ASR prompt to remote transcription endpoints either: the only remote consumers of `initialPrompt` are Whisper-family servers (OpenAI-compatible `prompt`, whisper-asr `initial_prompt`), which share the same fragility; Deepgram/ElevenLabs ignore it. So `RecordingManager` passes `initialPrompt: ""` for `.remoteEndpoint`, and the spell-correction post-step (use #1) covers remote transcripts too. The `initialPrompt` parameter remains on `TranscriptionService.transcribe` / `WhisperKitTranscriptionService.transcribe` as a dormant capability (defaults to empty / `nil`).

**Unified-result engines** (Apple Intelligence, Gemma local, and Local CLI) each produce a `LocalInsightsResult` in a single call (with an inline `title_concept`, so they all skip the separate title-generation step). Apple Intelligence does this via **guided generation** (`@Generable` schema, `FoundationModels`) using `UnifiedInsightsPrompt.systemPromptForGuidedGeneration`; Gemma local and Local CLI use a shared JSON prompt/schema via `UnifiedInsightsPrompt` (system + user prompt + transcript truncation, in `dBriefWire` so both the app and the helper can use it), with output parsed via `LocalInsightsDecoder.decodeAndNormalize`. **Local CLI cannot stream**, so the transcript chat window falls back to `AppSettings.chatFallbackEngine` (never `.localCLI`) when the active engine is Local CLI. The default fallback is `AIEngine.defaultOnDeviceFallback` — Apple Intelligence if available, otherwise local Gemma — so chat works without configuring a remote endpoint.

### Local AI Plugin System — Crash-Isolated Helper Process

All self-loaded local ML (WhisperKit transcription, SpeakerKit diarization, MLX/Gemma insights & chat, and Parakeet/FluidAudio transcription) runs in a **separate helper process**, so a CoreML/WhisperKit trap (e.g. WhisperKit's `decoderOutput.logits!` force-unwrap) kills only the helper, not the menu-bar app. Apple Speech and Apple Intelligence stay in-process (OS-managed).

**Three SPM targets:**
- **`dBriefWire`** (library, no ML deps) — the shared contract linked by both executables: the wire `Envelope`/`MLRequest`/`MLEvent`/`WireError` types, the `FrameCodec`/`FrameReader`, `LocalAIPluginProtocol`, the `Codable`/`Sendable` model structs (`TranscriptionResult`, `LocalInsightsResult`, `DiarizedTurn`, `LiveTranscriptSegment`, `LocalAIPluginState`, `WhisperRuntimeConfig`, `WhisperComputeUnits`, `OutputLanguage`), and shared utilities (`Logger` extensions, `WhisperModelInfo`, `ParakeetModelInfo`, `SystemMemory`, `LocalInsightsDecoder`).
- **`dBriefMLHost`** (executable) — links the heavy ML packages and hosts the real `WhisperKitTranscriptionService`, `MLXInsightsService`, `ParakeetTranscriptionService`, `TTSService` (TTSKit/Qwen3-TTS scaffold — see below), the `AsyncMutex` GPU serialization, `MLOrchestrator` (the in-helper backend, formerly the in-process `LocalAIPluginService`), and a stdin/stdout `RequestLoop`. `main.swift` parses `--support-base` so the helper resolves the **same** model-cache dir as the app (its own `Bundle.main.bundleIdentifier` differs), and frees Metal buffers on SIGTERM/EOF.
- **`dBrief`** (app) — depends only on `dBriefWire`; the proxies `LocalAIPluginService` and `ParakeetTranscriptionService` forward every call over a shared `MLHostConnection`.

**Transport — `MLHostConnection` (`Services/MLHostConnection.swift`):** owns the child `Process` and its pipes, frames messages (4-byte big-endian length prefix + JSON `Envelope`), correlates replies by request `id`, demuxes `.state` events to per-`MLChannel` (`.plugin` / `.parakeet`) `AsyncStream<LocalAIPluginState>`, forwards `.token` frames to streaming `AsyncThrowingStream`s, and detects crashes via `terminationHandler` (a request in flight when the process dies throws `MLHostError.helperCrashed`). The helper is persistent, lazily spawned, and auto-relaunched on the next call after a crash. Audio is passed by file path (never over the pipe).

**Frame ordering invariant (both sides):** a request's terminal `.finished` must never overtake its result frame on the wire — if it does, `call()` resolves nothing, drops the pending entry, and leaks its continuation (permanent hang). So **neither side may dispatch frame writes/reads in per-event `Task`s**: the helper's `StdoutWriter` drains an ordered `AsyncStream` from a single task (`send` is synchronous), and `MLHostConnection` feeds stdout chunks through a single serial `AsyncStream` consumer into `ingest` (never one `Task` per chunk). This matters most for multi-frame replies (e.g. Parakeet transcription that also diarizes: result + several `.diarizing`/download `.state` events + `.finished`).

**Crash recovery:** `LocalAIPluginService.transcribeWithRetry` retries **once in safe mode** (`concurrentWorkerCount = 1`, decoder off the ANE via `.cpuAndGPU`) when the helper crashes; a second crash surfaces a clean `TranscriptionServiceError`. A normal `.error` frame (insufficient memory, audio load) propagates without retry. Because crashes are recoverable, the normal-path `concurrentWorkerCount` (8) can be raised toward WhisperKit's default of 16 with benchmarking.

The orchestrator keeps the prior behavior: **AsyncMutex** serializes GPU access; **per-op model unload** keeps an idle helper model-free; the **state stream** drives UI feedback (`idle`, `downloading(progress, stage)`, `transcribing`, `newSegments(...)`, `diarizing`, `analyzing`).

**Build/packaging:** `make app` builds all executables and copies `dBriefMLHost` into `Contents/MacOS/` beside the MLX `default.metallib`. A test-only `dBriefMLHostStub` target (env `STUB_MODE=echo|crash-once|crash-always|error`) drives the connection/retry tests deterministically without real models.

### Text-to-Speech Scaffold (`Sources/dBriefMLHost/TTSService.swift`)

The `argmax-oss-swift` 1.0 SDK bundles `TTSKit` (Qwen3-TTS). dBrief wires a **minimal, no-UI scaffold** so a future read-aloud feature has a foundation:
- `TTSService` (in the helper) wraps `TTSKit`, loads the model lazily, writes synthesized mono PCM to a WAV file via `AVAudioFile` (audio passed by path, never over the pipe), and unloads on memory-pressure / force-unload. Models download to `AppSupport/dBrief/LocalAIPlugin/TTS/`.
- Wire path: `MLRequest.synthesizeSpeech(text:outputPath:voice:language:)` → `RequestRouter` → `MLOrchestrator.synthesizeSpeech` (serialized via the same `AsyncMutex`) → `MLEvent.speechResult(SpeechSynthesisResult)`. The app proxy is `LocalAIPluginService.synthesizeSpeech(...)`.
- **Not surfaced in any view** — no settings, no model-download button, no read-aloud action yet. `DownloadStage` gained `.ttsModel` / `.ttsModelLoading` for progress.

### Endpoint Model (`Models/Endpoint.swift`)

`Endpoint` represents both transcription and AI server configs (`id`, `name`, `baseURL`, `modelName`, `apiKey`, `provider`). `provider` (`Endpoint.Provider`: `openAICompatible`/`anthropic`/`deepgram`/`elevenLabs`) selects the request/response adapter; it defaults to `openAICompatible` and is decoded with a custom `init(from:)` (`decodeIfPresent ?? .openAICompatible`) so endpoints persisted before the field existed still load. The `isWhisperASR` computed property auto-detects whisper-asr-webservice endpoints by URL pattern (contains `/asr`, port 8080 or 9000) for `openAICompatible` only. Provider-specific URLs are computed (`transcriptionURL`, `chatCompletionsURL`, `messagesURL`). `ProviderPresets` (`Models/ProviderPresets.swift`) is the curated catalog that prefills the endpoint editor; API keys remain in the struct/UserDefaults (Keychain migration is a separate task).

### Meeting Profiles (`Models/MeetingProfile.swift`)

Profile system for per-meeting configuration overrides:
- **Presets**: `default`, `teamMeeting`, `salesMeeting`, `custom` — each with pre-configured prompts
- **Overrides**: nullable fields for transcription engine, AI engine, endpoints, prompts, output folders
- **Resolution order**: profile override → active profile setting → global app default
- **Export/import**: versioned `ProfilesExportEnvelope` with conflict renaming on import
- Effective settings accessed via `AppSettings.effectiveTranscriptionEngine`, `effectiveAIEngine`, etc.

### Call Detection (`Services/CallDetectionService.swift`)

`CallDetectionService` monitors for known meeting apps (`knownCallApps`: Zoom, Teams classic/new, Slack, Webex, FaceTime, Google Meet) via `NSWorkspace` notifications and microphone activity via CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`. Can auto-start recording (`autoRecordCalls`) or show a popup prompt (`CallDetectedOverlayController`). The prompt can **auto-dismiss** after `AppSettings.autoDismissCallPromptSeconds` (0 = never; the timer is scheduled in `CallDetectedOverlayController.show()` and cancelled in `hide()`, so any user interaction cancels it). Per-app enable/disable via `AppSettings.disabledCallApps`. Configured in **Settings → General → Call Detection**.

### Calendar Integration (`Services/CalendarService.swift`, `OutlookCalendarService.swift`)

On recording **stop**, `RecordingManager.lookupCalendarCandidates(for:)` looks up the matching calendar event(s) to pre-fill the meeting title, participants (used as diarization speaker names), and agenda context for AI prompts. The lookup happens at stop (not start) because only then is the true recording span `[date, date+duration]` known, which the span-aware matcher needs; it runs detached so the post-recording sheet appears immediately and the ranked candidates + best match populate reactively via `@Observable`. Two sources behind `AppSettings.calendarSource` (`CalendarSource`: `.disabled`/`.iCal`/`.outlook`):
- **iCal** — `CalendarService.findCandidates(recordingStart:recordingEnd:)` via EventKit (`EKEventStore`), needs Calendar permission
- **Outlook** — `OutlookCalendarService.findCandidates(recordingStart:recordingEnd:)` via Microsoft Graph; auth through `MicrosoftAuthService` (OAuth2, Keychain-stored). The Outlook option only appears when `MicrosoftAuthService.isConfigured` (a real Azure client ID is compiled in, not the placeholder).

Both search a ±2h window and rank candidates via the pure, unit-tested `CalendarMatcher.rankedMatches(...)`: each candidate is scored by intersection-over-union of its window vs. the recording span, `+0.10` if it was active at recording start, `+0.15` if it has attendees, and `×0.10` to sink all-day blocks — so a day-long personal block never wins over the short meeting it overlaps. `selectBestMatch(...)` returns the top. `Recording.calendarCandidates` holds the ranked list; `PostRecordingSheet` shows a **"Meeting" override picker** (with a "None" option) so the user can correct or clear the auto-pick (guarded auto-fill via `applyCalendarEvent` never clobbers typed input; an explicit pick via `selectCalendarEvent` overwrites title + participants). `AppSettings.effectiveCalendarSource` coerces `.outlook` → `.disabled` when Outlook isn't configured, so a stale selection never renders sign-in UI. Configured in **Settings → General → Calendar**.

### Integration Dispatch (`Services/IntegrationDispatchService.swift`)

Routes post-recording content to eight implemented destinations, each with configurable field selection (audio, transcript, summary, tags, sentiment, action items, markdown). **`IntegrationDestination.available` is the source of truth for which are exposed** — currently only Obsidian, Apple Notes, Apple Reminders, and Webhook. The others (Notion, Evernote, Google Keep, OneNote) are implemented but hidden from the Settings UI and skipped by dispatch until verified.

| Destination | Method |
|-------------|--------|
| Apple Notes | AppleScript |
| Apple Reminders | EventKit API (`EKEventStore`) — creates reminder per action item |
| Notion | REST API (v2022-06-28) |
| Evernote | REST API |
| Google Keep | REST API |
| Microsoft OneNote | Microsoft Graph API (v1.0) |
| Obsidian | Local filesystem (Markdown files in vault folder) |
| Webhook | Custom HTTP POST with optional multipart audio upload |

Integration tokens are stored securely via `KeychainHelper`.

### Markdown Output (`Services/MarkdownGenerator.swift`)

Produces Markdown files with YAML frontmatter (title, date, tags, duration, audio link, model info, speaker count) and sections for transcription (with timestamps and speaker labels), summary, action items, and tags/sentiment. Speaker labels resolved through `RichTranscript.speakerLabels` — displays custom display names when available, falls back to raw speaker IDs. Outputs to either the transcription folder or an Obsidian vault folder.

### Speaker Diarization (`Services/WhisperKitTranscriptionService.swift`)

Optional SpeakerKit integration (Pyannote v4 models) for identifying who said what:

- Enabled via `AppSettings.diarizationEnabled` toggle in Settings → Recording
- Runs sequentially after WhisperKit transcription (not parallel — both compete for GPU/ANE)
- `SpeakerKit(PyannoteConfig)` initialized on-demand, models downloaded to `AppSupport/dBrief/LocalAIPlugin/SpeakerKit/`
- Speakers are overlaid **additively**: the full WhisperKit transcript is mapped to `dBriefWire.TranscriptionResult` (every segment kept), `diarResult.segments` is converted to `[DiarizedTurn]`, and `SpeakerMerge.mergePreservingSegments(_:turns:)` attaches speakers by time overlap. This replaced `SpeakerKit.addSpeakerInfo(strategy: .subsegment)`, which **silently dropped any segment lacking word timestamps** — a custom-vocabulary `initialPrompt` routinely makes WhisperKit omit word timings, so diarization + a vocabulary prompt used to lose most of the transcript. `mergePreservingSegments` never rebuilds segment text from words (unlike `SpeakerMerge.merge`), so partial/sparse word timing can't truncate text; the trade-off is one speaker per segment (plus per-word labels) instead of within-segment splitting.
- Speaker IDs ("Speaker 1", "Speaker 2") stored in `TranscriptionResult.Segment.speaker` and `Word.speaker`
- **Participant mapping**: Users enter comma-separated names in `PostRecordingSheet`; `RichTranscriptBuilder.build(from:participants:)` maps names to speakers by ordinal (first speaker = first name)
- **Post-hoc rename**: Clicking a speaker badge in `TranscriptSegmentRow` opens a rename popover that updates `SpeakerLabel.displayName` in the `RichTranscript`, persisted via `TranscriptStore`
- Display names resolved through `RichTranscript.speakerLabels` in both transcript viewer badges and markdown output

**Parakeet diarization** (same `diarizationEnabled` toggle): Parakeet has no built-in speaker support, so `MLOrchestrator.parakeetTranscribe(…, diarize:)` runs the engine-agnostic standalone pass `WhisperKitTranscriptionService.diarize(fileURL:) -> [DiarizedTurn]` (SpeakerKit, reused, after unloading the Parakeet model to free memory), then merges speakers onto Parakeet's word-level segments via the pure `SpeakerMerge.merge(_:turns:)` helper in `dBriefWire` — assigning each word its best-overlapping turn and regrouping consecutive same-speaker words into segments. The diarization flag rides on `MLRequest.parakeetTranscribe(path:modelVariant:diarize:)`. This makes Parakeet diarization full-pipeline (rich transcript, participant mapping, markdown, integrations), unlike the app-side post-hoc `SpeakerAssigner` re-diarize in the transcript window. `SpeakerMerge` is the wire-type analogue of `SpeakerAssigner` (which still operates on `RichTranscript`).

**Important**: WhisperKit's `TranscriptionResult` class conflicts with dBrief's `TranscriptionResult` struct (same name, different modules). The `WhisperKit` module name also collides with the `WhisperKit` class. As a result, diarization code that uses both types must be inlined within `transcribe()` where `wkResults` type is inferred — it cannot be extracted into separate functions with explicit type annotations. Use `dBrief.TranscriptionResult` to qualify our type.

### Live Transcript

`AppState.liveTranscriptSegments` (+ `liveVolatileMic`/`liveVolatileSystem`/`liveStatusMessage`) drives a real-time transcript view that's filled in two phases — while recording (optional Apple Speech preview) and while WhisperKit transcribes the finished file. Both render inside `TranscriptDetailView`'s **live mode** (there is no standalone live window); the in-progress recording is pinned at the top of `TranscriptBrowserView`'s sidebar ("In Progress"), and the **"Live Transcript"** button in `TranscriptionProgressView` opens the transcript window (`id: "transcript"`) with it selected.

**Real-time, during recording — `LiveTranscriptionService` (`Services/LiveTranscriptionService.swift`)**: optional (`AppSettings.liveTranscriptionEnabled`, default off; **Settings → AI & Models → Transcription → Live Transcription**), separate from the authoritative transcript still produced by the chosen engine at stop. An `actor` running two concurrent in-process Apple Speech channels — mic ("You") and system audio ("Participant"); macOS 26+ uses the streaming `SpeechAnalyzer`/`SpeechTranscriber` (volatile + finalized, input converter rebuilt on source-format change), macOS 14–25 falls back to `SFSpeechAudioBufferRecognitionRequest`. On-device only. Each channel transcribes a **single locale** (`AppSettings.effectiveTranscriptionLanguage`, or the system locale when empty) — Apple's streaming recognizer has no language auto-detect or code-switching, so mixed-language meetings get an accurate result only from a multilingual *post-recording* engine (Parakeet v3 / Whisper), not the live preview.
- **Live audio feed**: `AudioCaptureManager.makeLiveAudioStreams()` (called *before* `startRecording` so the tap handlers capture the sinks) returns mic + system `AsyncStream<LiveAudioBuffer>`. Tap handlers deep-copy each buffer into a `LiveAudioBuffer` (an `@unchecked Sendable` wrapper, so the stream crosses the main-actor → transcription-actor boundary without `sending` gymnastics) in addition to writing the CAF tracks; the converting hot-swap handler feeds the live sink too, so live transcription survives a mid-recording mic device switch. Streams use `.bufferingNewest` (bounded — a lossy preview, not unbounded RAM) and are finished by `stopRecording`.
- **Orchestration**: `RecordingManager.startLiveTranscription(streams:)` starts the service (gating each channel on its permission); finalized segments → `liveTranscriptSegments` (ordered by the pure, end-anchored `LiveSegmentMerge.insert`), volatile text → `liveVolatile*`, status → `liveStatusMessage` ("Preparing language…" during a first-run language-asset download). `stopLiveTranscription` cancels it on stop/reset.
- Pure, OS-independent, unit-tested helpers in `dBriefWire`: `AppleSpeechResultMapper.liveSegments` (chunk → speaker-tagged `LiveTranscriptSegment`) and `LiveSegmentMerge` (`LiveTranscriptMappingTests`).

**Progressive, during WhisperKit transcription**: WhisperKit's `segmentDiscoveryCallback` fires each time a ~30-second audio chunk is decoded; segments convert to `LiveTranscriptSegment` and are pushed via `LocalAIPluginState.newSegments(...)`, which `RecordingManager` appends to the same `liveTranscriptSegments` (cleared on each new transcription).

### YouTube / Video URL Transcription (`Services/YouTubeDownloadService.swift`)

`YouTubeDownloadService` lets any yt-dlp-supported URL be transcribed without recording:

- Locates the `yt-dlp` binary (PATH or Homebrew prefix), fetches the video title, and downloads best-quality audio as 16 kHz mono m4a via ffmpeg post-processor
- `RecordingManager.loadYouTubeAudio()` sets `finalizedAudioURL` directly (skips `RecordingFinalizer`) and opens `PostRecordingSheet`
- `YouTubeURLInputView` is an inline SwiftUI panel in the menu bar with URL field, progress indicator, error display, and a yt-dlp install hint
- Requires `yt-dlp` (`brew install yt-dlp`)

### Watched Folders (`Services/WatchedFolderService.swift`, `Services/WatchedFolderScanner.swift`)

A drop-in transcription queue: audio files dropped into a watched folder are auto-transcribed/analyzed/exported via the normal pipeline, no recording needed. Off by default (`AppSettings.watchedFoldersEnabled`).

- **`WatchedFolderScanner`** (pure, unit-tested) — `audioFiles(in:)` enumerates a folder non-recursively for `audioExtensions`; `newlyStableFiles(current:previous:processed:)` returns files that are **size-stable across two consecutive scans** (so a file still being copied isn't grabbed) and not already processed. No state, fully testable without disk.
- **`WatchedFolderService`** (`@MainActor @Observable`) — a lightweight ~4 s polling loop (not FSEvents) that re-reads live settings each cycle, so toggling folders/the master switch needs no restart. Resolves each `WatchedFolder` bookmark and enumerates off-main via `Task.detached`. **Seed-on-first-encounter**: a folder's pre-existing files are recorded as already-processed the first time it's seen, so adding a folder only processes files dropped in *afterwards* (never an existing library at once). Processed paths + known folders persist in `UserDefaults` (bounded to 5000). Serial, and defers to any active recording/processing via `RecordingManager.isIdle`. Started from `AppContext.ensureReady()`; self-gates when disabled/empty.
- **`WatchedFolder`** (`Models/WatchedFolder.swift`) — `Codable`/`Sendable` struct holding a security-scoped bookmark, display path, and `isEnabled`; persisted as JSON in `AppSettings.watchedFolders`.
- **`RecordingManager.processWatchedFile(_:)`** — headless entry: copies the source to a temp file and sets `importSourceURL` so the finalizer relocates the **copy** into the recordings folder (original left untouched, result lands in History), then runs `processRecording` with the global `autoTranscribe/autoSummary/autoActionItems/autoTags` prefs.
- Configured in **Settings → Watched Folders** (`SettingsWatchedFoldersTab`): master toggle, folder list (add via `NSOpenPanel`, per-folder enable, remove), and a "Notify when a new file is detected" option (completion notifications fire regardless via the normal pipeline).

### Transcript Chat (`Services/TranscriptChatService.swift`)

`TranscriptChatService` (`@MainActor @Observable`) provides conversational Q&A over a recording:

- Holds a `[ChatMessage]` array and an `isStreaming` flag
- Routes to Apple Intelligence, MLX (streaming), or remote endpoint based on `AppSettings.aiEngine`
- Builds the system prompt from a **`transcriptProvider: @MainActor () -> String` closure** (not a fixed string) read at each `send()`, plus speaker labels — so the chat can run against a *live, growing* transcript during recording (the provider reads `AppState.liveTranscriptSegments` + volatile lines). A `transcriptText:` convenience init covers the fixed finished-recording case.
- `rebindTranscript(text:speakerLabels:)` re-points an existing session at a new transcript while keeping its messages — used when a live recording finishes so the in-progress Q&A **carries over** to the authoritative transcript (an empty live chat is dropped instead).
- **Persistence**: `TranscriptChatStore` caches one live session per recording for the app run (keyed by audio file URL); on top of that, chat is **persisted to disk** as a `<base>.chat.json` sidecar. `ChatStore` (actor, mirrors `InsightsStore`) loads/saves a `Codable` `ChatHistory` (`version`, `[ChatMessage]`, optional `engine`). A finished recording's session calls `enablePersistence(store:url:)` + `loadPersisted()` when the chat panel opens (so history survives an app restart), and `send()` triggers a debounced (~500 ms) `scheduleSave()`. `clearMessages()` deletes the sidecar. When a live recording finishes, the carried-over chat gains persistence and flushes via `persistNow()` (`recording.chatSidecarURL` only resolves once the audio is finalized). The `.chat.json` sidecar is included in `RetentionCleanup`'s transcript sweep and in both delete paths (`TranscriptWindowView.deleteRecording`, `RecordingHistoryView.deleteItem`).
- `TranscriptChatView` renders the conversation with a command-palette layout and glass styling. In the finished-recording viewer it's a full-pane mode swap; during **live mode** it opens as a right-hand side panel (`TranscriptDetailView.liveChatPanel`) so the growing transcript stays visible.

### Rich Transcript Viewer

Glass-styled transcript window with word-level timestamps and audio sync:

- **`TranscriptWindowView`** — root window; hosts `TranscriptSidePanel` (segment list) and `TranscriptChatView`
- **`TranscriptPlayerBar`** — frosted-glass audio controls with seek and playback sync
- **`SpeakerTurnCard`** — card per speaker turn, merges consecutive same-speaker segments
- **`SpeakerPillView`** — colored speaker badge, tap to rename
- **`TranscriptDesignTokens`** — shared color/spacing constants for the glass UI system
- **`TranscriptAnalysisView`** — "AI Analysis" toolbar toggle (mutually exclusive with chat) showing Summary / Action Items / Tags+Sentiment in three editable glass cards, mirroring `ResultsView`. Read-only by default; an Edit button enables editing, Save persists. Sentiment is display-only. Recordings processed before this feature (no sidecar) show an empty state.
- Persisted via `TranscriptStore` which writes `.richtranscript.json` sidecar files alongside Markdown output
- Opened from `ResultsView` and `RecordingHistoryView`; hosted in a separate `WindowGroup(id: "transcript")` scene

### AI Analysis Sidecar (`Models/RecordingInsights.swift`, `Services/InsightsStore.swift`)

AI output (summary, action items, tags, sentiment) is persisted to a `<base>.insights.json` sidecar next to the audio, in addition to the Markdown file:

- `RecordingInsights` — `Codable`/`Sendable` model (summary, actionItems, tags, sentiment, `markdownPath`, version) with `plainTextForCopy()` for the panel's Copy button. `Recording.insightsSidecarURL` locates it.
- `InsightsStore` — actor mirroring `TranscriptStore` (atomic load/save; `load` returns `nil` when absent).
- Written by `RecordingManager.writeInsightsSidecar(for:markdownURL:)` right after Markdown generation during processing (both the initial and retry-AI paths). No-op when there is no summary.
- `TranscriptAnalysisView` loads it on open and, on Save, rewrites the sidecar **and** surgically updates the existing Markdown via `MarkdownInsightsUpdater.update(markdown:with:)` — replacing only the `## 📝 Summary` / `## ✅ Action Items` / `## 🏷️ Tags` sections and the frontmatter `tags:` list, leaving the transcript and other content untouched. Integrations are **not** re-dispatched (avoids duplicate notes/reminders).

### Other Services

- **Whisper prewarm** — to hide WhisperKit's model load+prewarm cost (otherwise re-paid every recording, since `MLOrchestrator.analyze` unloads Whisper to free memory for the local LLM), the model is warmed ahead of transcription via `MLRequest.prewarmWhisper(config:refresh:)` → `WhisperKitTranscriptionService.prewarm` (load-and-keep, no trailing unload). `RecordingManager.startRecording` fires it for local Whisper so the load hides behind the recording. `WhisperPrewarmCoordinator` adds opt-in launch (~3 s) + wake (`NSWorkspace.didWakeNotification`, `refresh: true`) prewarm behind the default-off `AppSettings.prewarmWhisperOnLaunch` (Settings → AI & Models → Transcription → Advanced). The prewarm config comes from the single `AppSettings.whisperRuntimeConfig` builder shared with the transcribe path, so the helper's `loadedConfig == config` cache is reused. Best-effort throughout; never evicts an in-use LLM.
- **GlobalHotkeyService** — registers a user-configurable global hotkey (default ⌃⌥⌘R) for record/stop toggle via Carbon Event Manager. The hotkey is stored as a `RecordHotkey` (`Models/RecordHotkey.swift`) and edited with `ShortcutRecorderView` in **Settings → General → Shortcuts**; `update()` re-registers on change
- **AudioPlayer** — playback control for past recordings
- **WebhookPayloadBuilder** — builds multipart/form-data payloads for webhook delivery
- **AudioChunker** — segments large audio files for chunked remote transcription
- **RetentionCleanup** (`Services/RetentionCleanup.swift`) — stateless, age-based auto-delete for the output folders. `cleanup(category:olderThanDays:in:)` enumerates the given folders and removes files older than the cutoff (judged by each file's own creation date). Two independent policies driven by `AppSettings.autoDeleteRecordings*`/`autoDeleteTranscripts*`: **recordings** sweeps audio (`m4a/wav/flac/mp3/aac`) + their non-transcript `.json`/`.queue.json` sidecars from the recordings folder; **transcripts** sweeps `.md` + `.transcript.json`/`.richtranscript.json`/`.insights.json`/`.chat.json` from the recordings and transcription folders. Runs on launch via `AppContext.runRetentionCleanupIfNeeded()` (off-main) and on demand from the Settings → General "Run Cleanup Now" buttons.

### UI Structure (`UI/`)

- **MenuBarView** (in `DBriefApp.swift`) — main menu bar popover with header, recording controls, history, YouTube URL input, and settings access
- **RecordingControlsView** — record/pause/resume/stop buttons
- **PostRecordingSheet** — post-recording options (transcribe, summary/AI toggles; title edit; participants input for diarization); AI options hidden when `aiProcessingEnabled` is false
- **TranscriptionProgressView** — step-by-step progress display during processing with download progress bar and a "Live Transcript" button that opens the transcript window (`id: "transcript"`) on the in-progress recording (see [Live Transcript](#live-transcript))
- **RecordingHistoryView** — list of past recordings with action chips; opens transcript viewer
- **OnboardingView** — initial setup wizard (permissions, engine selection, folder setup)
- **FloatingMiniPlayer** — floating window showing real-time peak levels during recording
- **CallDetectedPopup** / **CallDetectedOverlayController** — call detection prompt overlay
- **YouTubeURLInputView** — inline panel in the menu bar for YouTube/video URL input
- **SettingsView** — sidebar-based settings window with tabs:
  - **General** — appearance/power-user toggle, record shortcut (`ShortcutRecorderView`), output folders, a **Privacy** section (independent auto-delete of recordings and transcripts after a chosen age, each with a "Run Cleanup Now" button), call detection, calendar source (iCal/Outlook), and permissions (mic, screen recording, calendar)
  - **General** — start-at-login toggle (`LoginItemManager`/`SMAppService`), appearance/power-user toggle, record shortcut (`ShortcutRecorderView`), output folders, call detection, calendar source (iCal/Outlook), and a Reset Onboarding button (flips `hasCompletedOnboarding` to re-show the setup guide)
  - **Permissions** (`SettingsPermissionsTab`) — top-level page consolidating all permission status/requests (microphone, screen recording, speech recognition, calendar) with "Open System Settings" deep links; moved here out of General. Pinned to the **bottom** of the sidebar (last `SettingsTab` case).
  - **Recording** (`SettingsRecordingTab`) — audio input device, acoustic echo cancellation, and a read-only Audio Quality summary (Power User Mode)
  - **AI & Models** (`SettingsAIModelsTab`) — two sub-tabs: **Transcription** (`SettingsTranscriptionTab`: engine; for Local Whisper a model **card** with Recommended badge + per-model plain-language descriptor + `ModelDownloadButton`, a help popover, diarization, and an **Advanced** disclosure holding compute units, "Show all models", refresh, and purge; plus language, a **Live Transcription** toggle (`liveTranscriptionEnabled`, real-time Apple Speech preview during recording — see [Live Transcript](#live-transcript)), cleanup, custom vocabulary, endpoints, chunking) and **AI Analysis** (`SettingsAITab`: AI engine, Gemma model download, prompts, AI processing toggle, output language, endpoints)
  - **Watched Folders** (`SettingsWatchedFoldersTab`) — master toggle, monitored-folder list (add/enable/remove), and notify-on-detect option (see [Watched Folders](#watched-folders-servicewatchedfolderserviceswift-serviceswatchedfolderscannerswift))
  - **Integrations** (`SettingsIntegrationsTab`) — only `IntegrationDestination.available` destinations
  - **Profiles** (`SettingsProfilesTab`) — hidden unless `powerUserMode` is enabled
  - **Benchmark** (`SettingsBenchmarkTab`) — hidden unless `powerUserMode` is enabled; hosts `ModelPerformanceView` (the global per-model timing aggregate from `ModelPerformanceStore`). Each transcription card's **headline** number is the pure model **inference** realtime ratio (`TranscriptionResult.inferenceTime`, reported by the WhisperKit helper); the **end-to-end** ratio (full transcription step — model load/prewarm, IPC, audio decode, diarization) plus the load/overhead delta move to the caption (cards lacking inference data fall back to end-to-end as the headline). The header shows a lifetime **"… transcribed by dBrief"** odometer (`AppSettings.lifetimeTranscribedSeconds`, incremented per transcription in `RecordingManager`) and a **Clear Stats** trash button (`ModelPerformanceStore.clear()`, with confirmation) that wipes the per-model history but **keeps** the odometer. Lives here because the data is overall, not tied to a single transcript — it is **not** in the transcript window toolbar. Reads the store via `@Environment(AppContext.self)` and `AppSettings` via `@Environment` (the settings window injects both).

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| [argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift) (Argmax OSS SDK) | 1.0.0+ | CoreML on-device speech AI (products: `WhisperKit` transcription, `SpeakerKit` diarization, `TTSKit` Qwen3-TTS text-to-speech). Formerly the `argmaxinc/WhisperKit` package (≤0.18); renamed and unified at v1.0. Vendors its own copy of `Hub`/`Tokenizers`, so it coexists with the separate `swift-transformers` dependency below. |
| [FluidAudio](https://github.com/argmaxinc/FluidAudio) | — | CoreML-based Parakeet TDT transcription (`AsrManager`) |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | 3.x | On-device Gemma 4 E4B LLM via MLX (Apple Silicon) |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | — | Tokenizer support for MLX (explicit dependency since mlx-swift-lm 3.x) |
| [swift-testing](https://github.com/apple/swift-testing) | 0.6.0+ | Testing framework |

### Linked System Frameworks

`ScreenCaptureKit`, `AVFoundation`, `EventKit`, `Security` — linked via SPM `linkerSettings` (not Xcode build settings).

## Key Patterns

- All UI and state classes are `@MainActor @Observable`. Services that do async work are `actor`-isolated (`TranscriptionService`, `AIService`, `LocalAIPluginService`, `MLXInsightsService`, `WhisperKitTranscriptionService`, `IntegrationDispatchService`, `RecordingFinalizer`).
- Logging uses centralized `Logger` extensions defined in `Logger+Extensions.swift` (e.g. `Logger.audio`, `Logger.recording`, `Logger.ai`). New files should use these static loggers rather than creating ad-hoc `Logger(subsystem:category:)` instances.
- Models are `Sendable` structs/enums for safe cross-isolation passing.
- Settings persistence uses `UserDefaults` with `didSet` observers on each property. Folder URLs use security-scoped bookmarks. Sensitive tokens use `KeychainHelper`.
- The app links system frameworks via SPM linker settings (not Xcode build settings).
- Audio tap handlers use `nonisolated static` factory methods to avoid `@MainActor` isolation on the real-time audio thread.
- WhisperKit, SpeakerKit, and MLX models are downloaded on-demand to `~/Library/Application Support/dBrief/LocalAIPlugin/` and can be purged from settings.
- **WhisperKit type collision**: The `WhisperKit` module and `WhisperKit` class share the same name, making `WhisperKit.TranscriptionResult` ambiguous. Use `dBrief.TranscriptionResult` to refer to our type; keep WhisperKit result types inferred (never name them explicitly in function signatures). Import with `@preconcurrency import WhisperKit` for Sendable suppression.
- Metal GPU support is auto-detected; the `make app` target copies `.metallib` files from the build or downloads prebuilt ones from the MLX releases.

## Platform Requirements

- macOS 14+ (Swift 6.2, swift-tools-version: 6.2)
- Apple Intelligence features require macOS 26+ on Apple Silicon
- MLX/Gemma 4 features require Apple Silicon (Metal GPU)
- YouTube transcription requires `yt-dlp` (`brew install yt-dlp`)
- Bundle identifier: `com.dbrief.app`
