# Crash-Isolated ML Helper Process — Design

**Date:** 2026-06-08
**Status:** Approved (design); pending implementation plan

## Problem

The Local Whisper engine (WhisperKit) intermittently crashes the entire dBrief
menu-bar app. WhisperKit's CoreML text decoder occasionally returns `nil` logits
under concurrent prediction, and WhisperKit force-unwraps it
(`decoderOutput.logits!`, `TextDecoder.swift` — still force-unwrapped in current
WhisperKit). That force-unwrap is a Swift trap: it is **uncatchable** from our
code, so it takes down the whole process. The crash reproduces on both ANE and
GPU and is triggered by concurrent CoreML predictions.

The current stop-gap is `options.concurrentWorkerCount = 4` (down from
WhisperKit's default of 16) in `WhisperKitTranscriptionService.transcribe`. This
reduces crashes but trades away a large amount of transcription throughput, and
does not eliminate the risk.

## Goal

Run our crash-prone, self-loaded ML pipelines in a **separate helper process** so
that:

1. A WhisperKit/CoreML (or other ML) trap can no longer take down the menu-bar
   app — the parent detects the helper's death and surfaces a clean error.
2. `concurrentWorkerCount` can be raised back toward the default for speed, since
   a crash is no longer fatal.

## Decisions (locked)

- **Scope — all self-loaded local ML in the helper.** WhisperKit transcription,
  its inline SpeakerKit diarization, the standalone `diarize()`, MLX/Gemma
  insights & chat, and Parakeet (FluidAudio) transcription all move into the
  helper. Apple Speech (`SFSpeechRecognizer`) and Apple Intelligence
  (`FoundationModels`) stay in-process — they are OS-managed, already
  out-of-process, and low-risk.
- **Lifecycle — persistent process, lazy spawn, per-op model unload retained.**
  Spawn on first local-ML use; keep alive for the app's lifetime; auto-relaunch
  on crash. The existing aggressive per-operation model unload moves into the
  helper, so an idle helper holds no models (only a small process baseline).
- **Crash recovery — auto-retry once, then clean error.** A crash during
  transcription triggers one automatic relaunch + retry in "safe mode" (low
  `concurrentWorkerCount`, decoder off ANE). A second crash surfaces a clean
  `TranscriptionServiceError`. Normal thrown errors (insufficient memory, audio
  load failure) do **not** retry.
- **IPC — child `Process` + framed messages over stdin/stdout pipes.** Chosen
  over `NSXPCConnection`/real `.xpc` bundles because it is the lowest-friction
  fit for this SPM (no-Xcode) build and works naturally with our existing
  `Codable`/`Sendable`/`AsyncStream` types.

## Architecture

### Process topology & SPM target restructure

Two processes, three SPM targets:

- **`dBriefWire`** *(new library target, no ML deps)* — the shared contract:
  - Wire `Envelope` + framing types.
  - `LocalAIPluginProtocol`.
  - The `Sendable`/`Codable` model structs exchanged across the boundary:
    `TranscriptionResult`, `LocalInsightsResult`, `LiveTranscriptSegment`,
    `DiarizedTurn`, `WhisperRuntimeConfig`, `LocalAIPluginState`,
    `DownloadStage`, and the `AppSettings.OutputLanguage` /
    `AppSettings.WhisperComputeUnits` values (or `Codable` mirrors of them).
  - Linked by **both** executables.
- **`dBriefMLHost`** *(new executable target)* — the helper. Links `dBriefWire`
  plus WhisperKit, SpeakerKit, MLX (`MLXLLM`/`MLXLMCommon`), FluidAudio, and
  swift-transformers. Hosts the **actual** `WhisperKitTranscriptionService`,
  `MLXInsightsService`, and `ParakeetTranscriptionService` (moved here), the
  `AsyncMutex` GPU serialization, and a stdin/stdout request loop. The WhisperKit
  module/class name-collision concern is now fully contained in this target.
- **`dBrief`** *(main app executable, slimmed)* — keeps all UI, audio capture,
  recording, integrations. **Drops** the WhisperKit/SpeakerKit/MLX/FluidAudio
  dependencies. Gains a `RemoteLocalAIPluginService` proxy that exposes the same
  public surface `AppContext` currently calls on `LocalAIPluginService`, so
  `RecordingManager`, `TranscriptChatService`, settings views, and memory-pressure
  handling are unchanged.

### Transport — `MLHostConnection`

A single component whose one job is reliable framed RPC over a supervised child
process:

- Owns the `Process`, its stdin/stdout `Pipe`s, spawn/relaunch, and
  `terminationHandler`.
- **Framing:** 4-byte big-endian length prefix followed by a JSON-encoded
  `Envelope` payload. The read side must handle partial reads and a length prefix
  split across reads. stderr is inherited so the helper's `OSLog`/stderr output
  still surfaces in Console/the parent's stderr.
- **Correlation:** every request carries a `UUID id`; a pending-continuation map
  routes reply/event frames back to the awaiting caller.
- Helper binary path resolved as
  `Bundle.main.bundleURL/Contents/MacOS/dBriefMLHost`.

### Wire protocol

- **Request (parent → helper):** `{ id, op, params }` where `op` ∈
  `transcribe`, `diarize`, `analyze`, `analyzeStream`, `chat`, `prepareModels`,
  `downloadWhisper`, `downloadLLM`, `isWhisperCached`, `isLLMCached`,
  `purgeModels`, `purgeWhisper`, `purgeSpeakerKit`, `purgeQwen`,
  `memoryPressurePurge`, `forceUnload`, `cancel`. Params carry op-specific data
  (file path string, `WhisperRuntimeConfig`, transcript text, output language,
  model name, etc.).
- **Event / reply (helper → parent):** `{ id, kind }` where `kind` ∈:
  - `.state(LocalAIPluginState)` — progress; also carries `.newSegments` since
    that is already a `LocalAIPluginState` case.
  - `.token(String)` — one chunk of a streaming text response.
  - `.result(payload)` — terminal success value for a request/response op.
  - `.error(WireError)` — a thrown (non-crash) error; terminal.
  - `.finished` — terminal marker for streaming ops.
- **`WireError`** mirrors the meaningful `TranscriptionServiceError` cases —
  especially `insufficientMemory(model, requiredGB)` and `audioLoadFailed` — plus
  a generic fallback, so the proxy re-throws a faithful, UI-correct error.
- **Audio never crosses the pipe** — it is already a file on disk, passed as a
  path.
- **`AsyncStream` reconstruction:** the proxy vends the same
  `AsyncStream<LocalAIPluginState>` (`stateStream`) the app consumes today and
  feeds incoming `.state` frames into it. Streaming token APIs
  (`analyzeTranscriptStream`, `chatStream`) build an `AsyncThrowingStream` and
  forward `.token` frames until `.finished`/`.error`; the stream's
  `onTermination` sends a `cancel` frame (by request id) so the helper stops
  generating.

### Crash detection & recovery

- If the process dies while a request is in flight (no `.result`/`.error`
  received, just process termination), that request's continuation throws
  `helperCrashed`. A normal `.error` frame is **not** a crash and propagates
  immediately without retry.
- **Auto-retry once (transcription):** on `helperCrashed`, the proxy relaunches
  the helper and retries the operation **once in safe mode** — forced low
  `concurrentWorkerCount` and decoder kept off the ANE. A second crash surfaces a
  clean `TranscriptionServiceError`. Insufficient-memory and audio-load errors
  never trigger a retry.
- On any death, all pending continuations are failed; the helper relaunches
  lazily on the next request.

### Concurrency restoration

Inside the helper's **normal** transcription path, raise `concurrentWorkerCount`
back up from the current stop-gap of `4` toward WhisperKit's default (final value
chosen by benchmark), now that a trap is recoverable. The **retry / safe-mode**
path uses the low value.

### Lifecycle & memory

- Lazy spawn on first local-ML use; persistent thereafter; auto-relaunch on
  crash.
- The `AsyncMutex` GPU serialization and the per-operation model unload both move
  into the helper. An idle helper holds no models.
- App quit / memory pressure: the parent forwards `forceUnload` /
  `memoryPressurePurge`. Under extreme pressure, killing the helper process is
  itself the ultimate reclaim. The helper frees Metal buffers in a termination
  handler before exit.
- **Model-path consistency:** the helper must resolve the **same** Application
  Support model directory as the app. Today's code derives it from
  `Bundle.main.bundleIdentifier`, which differs in the helper process (and would
  silently diverge). The parent therefore passes the resolved Application Support
  base path to the helper via a launch argument or environment variable, and the
  ML services use that injected base instead of `Bundle.main.bundleIdentifier`.

### Build & packaging

- `Package.swift`: add the `dBriefWire` library target and the `dBriefMLHost`
  executable target; move the ML service files into `dBriefMLHost` and the shared
  model/protocol/wire types into `dBriefWire`; remove the ML package
  dependencies from the `dBrief` target (they remain on `dBriefMLHost`).
- `make app`: build both executables, copy `dBriefMLHost` into
  `Contents/MacOS/`, and ensure the MLX `default.metallib` is locatable beside
  the helper (MLX now runs in the helper). Both binaries live in the same bundle
  with ad-hoc signing; launching a sibling binary needs no special entitlement.

## Testing

- **Unit:**
  - Framing codec round-trip, including partial reads and a length prefix split
    across multiple reads.
  - Request-router op → service-call mapping using a mock ML service.
  - `WireError` ↔ `TranscriptionServiceError` fidelity (notably the
    `insufficientMemory` case, which the UI depends on).
- **Integration:**
  - A test-only helper crash mode (e.g. `DBRIEF_MLHOST_FAKE_CRASH=transcribe`)
    to deterministically exercise: crash → retry → success, and crash → retry →
    second crash → clean surfaced error.
  - A happy-path stream of `.state` / `.token` / `.result` frames, asserting the
    proxy reconstructs the result, the progress `stateStream`, and the token
    stream correctly.
- **Unaffected:** existing `WhisperPipelineTests`, `ProfileBehaviorTests`,
  `RichTranscriptBuilderTests`, `WhisperModelInfoTests` — finalize/merge/profile
  logic stays in the main app.

## Out of scope

- Moving Apple Speech or Apple Intelligence out of process.
- Changing the transcription/AI engine selection model, UI, or settings surface.
- Any change to recording, finalization, or integration dispatch.
