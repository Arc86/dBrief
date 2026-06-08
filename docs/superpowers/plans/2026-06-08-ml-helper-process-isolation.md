# Crash-Isolated ML Helper Process — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run all self-loaded local ML (WhisperKit, SpeakerKit, MLX/Gemma, Parakeet) in a separate `dBriefMLHost` helper process so a CoreML/WhisperKit trap can no longer crash the menu-bar app, and `concurrentWorkerCount` can be raised back up.

**Architecture:** Three SPM targets — `dBriefWire` (shared `Codable`/`Sendable` contract, no ML deps), `dBriefMLHost` (executable hosting the real ML services + a stdin/stdout request loop), and the slimmed `dBrief` app (proxies forwarding over a supervised child `Process`). Parent ↔ helper exchange length-prefixed JSON frames; audio is passed by file path. The helper is persistent, lazily spawned, auto-relaunched on crash; transcription auto-retries once in safe mode after a crash.

**Tech Stack:** Swift 6.2, Swift Package Manager (no Xcode), `Foundation.Process`/`Pipe`, `swift-testing`, WhisperKit/SpeakerKit/MLX/FluidAudio (helper only).

**Reference spec:** `docs/superpowers/specs/2026-06-08-ml-helper-process-isolation-design.md`

---

## File Structure

**`Sources/dBriefWire/` (new library target — no ML deps):**
- `Wire/Frame.swift` — length-prefixed framing codec (encode/decode + incremental reader).
- `Wire/Envelope.swift` — `RequestEnvelope`, `EventEnvelope`, `MLRequest`, `MLEvent`, `MLChannel`, `WireError`.
- `Models/TranscriptionResult.swift` — moved verbatim from `Sources/dBrief/Models/`.
- `Models/LocalInsightsResult.swift` — moved verbatim.
- `Models/DiarizedTurn.swift` — moved verbatim (add `Codable`).
- `Models/LiveTranscriptSegment.swift` — extracted from `AppState.swift` (add `Codable`).
- `Models/LocalAIPluginState.swift` — `LocalAIPluginState` + `DownloadStage` (moved from `LocalAIPluginProtocol.swift`; add `Codable`).
- `Models/WhisperComputeUnits.swift` — `WhisperComputeUnits` enum (moved from `AppSettings`).
- `Models/WhisperRuntimeConfig.swift` — `WhisperRuntimeConfig` (moved from `LocalAIPluginProtocol.swift`).
- `LocalAIPluginProtocol.swift` — the protocol only (moved).

**`Sources/dBriefMLHost/` (new executable target — all ML deps):**
- `main.swift` — entry: parse `--support-base`, install termination handler, run the loop.
- `RequestLoop.swift` — reads frames from stdin, dispatches to `MLOrchestrator`, writes event frames to stdout.
- `MLOrchestrator.swift` — the actor formerly known as `LocalAIPluginService` (GPU mutex + per-op unload), now routing to the three services and emitting `MLEvent`s. Includes Parakeet.
- `WhisperKitTranscriptionService.swift` — moved verbatim from `Sources/dBrief/Services/`.
- `MLXInsightsService.swift` — moved verbatim.
- `ParakeetTranscriptionService.swift` — moved verbatim.
- `AsyncMutex.swift` — extracted from old `LocalAIPluginService.swift`.

**`Sources/dBrief/` (main app — slimmed):**
- `Services/MLHostConnection.swift` — NEW: owns the child `Process`, framing IO, request correlation, crash detection, relaunch.
- `Services/LocalAIPluginService.swift` — REWRITTEN as a proxy over `MLHostConnection` (same public surface).
- `Services/ParakeetTranscriptionService.swift` — REWRITTEN as a proxy (same public surface).
- `App/AppSettings.swift` — `WhisperComputeUnits` becomes `typealias WhisperComputeUnits = dBriefWire.WhisperComputeUnits`.
- `App/AppState.swift` — drop the moved `LiveTranscriptSegment` definition; `import dBriefWire`.
- `Services/RecordingManager.swift`, `Services/TranscriptChatService.swift`, settings views — add `import dBriefWire`; otherwise unchanged (proxies keep the old names/signatures).

**`Package.swift`** — add `dBriefWire` + `dBriefMLHost`; move ML deps to `dBriefMLHost`; `dBrief` depends only on `dBriefWire`.

**`Makefile`** — build + bundle `dBriefMLHost` into `Contents/MacOS/`; copy `default.metallib` beside it.

---

## Phase 1 — Shared wire library (`dBriefWire`)

### Task 1: Create `dBriefWire` target and move shared model types

**Files:**
- Modify: `Package.swift`
- Move: `Sources/dBrief/Models/TranscriptionResult.swift` → `Sources/dBriefWire/Models/TranscriptionResult.swift`
- Move: `Sources/dBrief/Models/LocalInsightsResult.swift` → `Sources/dBriefWire/Models/LocalInsightsResult.swift`
- Move: `Sources/dBrief/Models/DiarizedTurn.swift` → `Sources/dBriefWire/Models/DiarizedTurn.swift`
- Create: `Sources/dBriefWire/Models/LiveTranscriptSegment.swift`
- Create: `Sources/dBriefWire/Models/WhisperComputeUnits.swift`
- Create: `Sources/dBriefWire/Models/WhisperRuntimeConfig.swift`
- Create: `Sources/dBriefWire/Models/LocalAIPluginState.swift`
- Create: `Sources/dBriefWire/LocalAIPluginProtocol.swift`
- Modify: `Sources/dBrief/App/AppState.swift` (remove `LiveTranscriptSegment`, add import)
- Modify: `Sources/dBrief/App/AppSettings.swift` (typealias `WhisperComputeUnits`)
- Delete: `Sources/dBrief/Services/LocalAIPluginProtocol.swift` (contents move to `dBriefWire`)

- [ ] **Step 1: Add the library target in `Package.swift`**

Add `dBriefWire` to `targets` and make `dBrief` depend on it:

```swift
.target(
    name: "dBriefWire"
),
.executableTarget(
    name: "dBrief",
    dependencies: [
        "dBriefWire",
        "WhisperKit",
        .product(name: "SpeakerKit", package: "WhisperKit"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        "FluidAudio",
        .product(name: "Hub", package: "swift-transformers"),
        .product(name: "Tokenizers", package: "swift-transformers"),
    ],
    exclude: ["Resources", "Images"],
    linkerSettings: [
        .linkedFramework("ScreenCaptureKit"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("EventKit"),
        .linkedFramework("Security"),
    ]
),
```

(The ML deps stay on `dBrief` for now — they are removed in Task 11 once the helper owns them.)

- [ ] **Step 2: Move the three model files unchanged**

```bash
mkdir -p Sources/dBriefWire/Models
git mv Sources/dBrief/Models/TranscriptionResult.swift Sources/dBriefWire/Models/TranscriptionResult.swift
git mv Sources/dBrief/Models/LocalInsightsResult.swift Sources/dBriefWire/Models/LocalInsightsResult.swift
git mv Sources/dBrief/Models/DiarizedTurn.swift Sources/dBriefWire/Models/DiarizedTurn.swift
```

Add `Codable` to `DiarizedTurn` (it is currently `Sendable, Equatable`):

```swift
struct DiarizedTurn: Sendable, Equatable, Codable {
    let speakerId: String   // e.g. "Speaker 1"
    let start: Double
    let end: Double
}
```

- [ ] **Step 3: Extract `LiveTranscriptSegment` into `dBriefWire`**

Create `Sources/dBriefWire/Models/LiveTranscriptSegment.swift`. Exclude `id` from `Codable` so the wire payload only carries the timing/text:

```swift
import Foundation

public struct LiveTranscriptSegment: Identifiable, Sendable, Codable {
    public let id = UUID()
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    private enum CodingKeys: String, CodingKey { case start, end, text }
}
```

Remove the `struct LiveTranscriptSegment { ... }` definition from `Sources/dBrief/App/AppState.swift` (lines 66–71) and add `import dBriefWire` at the top of that file.

- [ ] **Step 4: Move `WhisperComputeUnits` into `dBriefWire`**

Create `Sources/dBriefWire/Models/WhisperComputeUnits.swift`:

```swift
import Foundation
import CoreML

public enum WhisperComputeUnits: String, CaseIterable, Codable, Hashable, Sendable {
    case cpuAndNeuralEngine
    case cpuAndGPU
    case all

    public var displayName: String {
        switch self {
        case .cpuAndNeuralEngine: "Neural Engine"
        case .cpuAndGPU: "Metal GPU"
        case .all: "All (GPU + Neural Engine)"
        }
    }

    /// Maps to the CoreML compute units WhisperKit applies per model component.
    public var mlComputeUnits: MLComputeUnits {
        switch self {
        case .cpuAndNeuralEngine: .cpuAndNeuralEngine
        case .cpuAndGPU: .cpuAndGPU
        case .all: .all
        }
    }
}
```

In `Sources/dBrief/App/AppSettings.swift`, delete the nested `enum WhisperComputeUnits { ... }` (lines 154–175) and replace it with a typealias inside `AppSettings`, and `import dBriefWire` at the file top:

```swift
typealias WhisperComputeUnits = dBriefWire.WhisperComputeUnits
```

- [ ] **Step 5: Move `WhisperRuntimeConfig`, state types, and the protocol into `dBriefWire`**

Create `Sources/dBriefWire/Models/WhisperRuntimeConfig.swift` (note `computeUnits` now uses the top-level `WhisperComputeUnits`, and everything is `public`):

```swift
import Foundation

public struct WhisperRuntimeConfig: Sendable, Equatable, Codable {
    public let modelName: String
    public let language: String?
    public let diarizationEnabled: Bool
    public var computeUnits: WhisperComputeUnits = .all

    public init(
        modelName: String,
        language: String?,
        diarizationEnabled: Bool,
        computeUnits: WhisperComputeUnits = .all
    ) {
        self.modelName = modelName
        self.language = language
        self.diarizationEnabled = diarizationEnabled
        self.computeUnits = computeUnits
    }

    public static let `default` = WhisperRuntimeConfig(
        modelName: "openai_whisper-small",
        language: nil,
        diarizationEnabled: false
    )
}
```

Create `Sources/dBriefWire/Models/LocalAIPluginState.swift` with manual `Codable` (enum with associated values does not synthesize `Codable` cleanly here):

```swift
import Foundation

public enum DownloadStage: String, Sendable, Codable {
    case whisperModel
    case whisperModelLoading
    case llmModel
    case speakerKitModel
    case parakeetModel
    case parakeetModelLoading
}

public enum LocalAIPluginState: Sendable, Codable {
    case idle
    case downloading(progress: Double?, stage: DownloadStage)
    case transcribing
    case newSegments([LiveTranscriptSegment])
    case diarizing
    case analyzing

    private enum Kind: String, Codable {
        case idle, downloading, transcribing, newSegments, diarizing, analyzing
    }
    private enum CodingKeys: String, CodingKey { case kind, progress, stage, segments }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .idle: self = .idle
        case .transcribing: self = .transcribing
        case .diarizing: self = .diarizing
        case .analyzing: self = .analyzing
        case .downloading:
            self = .downloading(
                progress: try c.decodeIfPresent(Double.self, forKey: .progress),
                stage: try c.decode(DownloadStage.self, forKey: .stage)
            )
        case .newSegments:
            self = .newSegments(try c.decode([LiveTranscriptSegment].self, forKey: .segments))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle: try c.encode(Kind.idle, forKey: .kind)
        case .transcribing: try c.encode(Kind.transcribing, forKey: .kind)
        case .diarizing: try c.encode(Kind.diarizing, forKey: .kind)
        case .analyzing: try c.encode(Kind.analyzing, forKey: .kind)
        case let .downloading(progress, stage):
            try c.encode(Kind.downloading, forKey: .kind)
            try c.encodeIfPresent(progress, forKey: .progress)
            try c.encode(stage, forKey: .stage)
        case let .newSegments(segments):
            try c.encode(Kind.newSegments, forKey: .kind)
            try c.encode(segments, forKey: .segments)
        }
    }
}
```

Create `Sources/dBriefWire/LocalAIPluginProtocol.swift` (protocol only; mark `public`):

```swift
import Foundation

public protocol LocalAIPluginProtocol: Sendable {
    var stateStream: AsyncStream<LocalAIPluginState> { get }

    func transcribe(fileURL: URL, initialPrompt: String?, whisperConfig: WhisperRuntimeConfig) async throws -> TranscriptionResult
    func analyzeTranscriptStream(_ text: String, outputLanguage: AppSettings.OutputLanguage) async -> AsyncThrowingStream<String, Error>
    func analyzeTranscript(_ text: String, outputLanguage: AppSettings.OutputLanguage) async throws -> LocalInsightsResult
    func copyToClipboard(transcript: String, insights: LocalInsightsResult) async -> String
    func prepareModelsIfNeeded() async
    func purgeModels() async throws
}
```

Then delete the old file:

```bash
git rm Sources/dBrief/Services/LocalAIPluginProtocol.swift
```

> **Coupling note for the engineer:** the protocol references `AppSettings.OutputLanguage`, which lives in the app target and cannot move to `dBriefWire`. Resolve this by **also moving `OutputLanguage` into `dBriefWire`** as a top-level `public enum OutputLanguage` and adding `typealias OutputLanguage = dBriefWire.OutputLanguage` inside `AppSettings` (same pattern as `WhisperComputeUnits` in Step 4). Grep first to copy its exact cases: `rg -n "enum OutputLanguage" -A 30 Sources/dBrief/App/AppSettings.swift`. Use `OutputLanguage` (not `AppSettings.OutputLanguage`) in the protocol signature.

- [ ] **Step 6: Make the mark public-API edits compile and verify the build**

Mark the moved model types `public` where the app and helper need to construct them across the module boundary: add `public` to `TranscriptionResult` (struct, nested `Segment`, `Word`, their inits, stored members, and `textForLLM`), `LocalInsightsResult` (struct, inits, members), and `DiarizedTurn` (struct + members). Add `import dBriefWire` to every app file that now fails to resolve a moved type (let the compiler guide you).

Run: `swift build`
Expected: PASS (the app builds with shared types living in `dBriefWire`; ML deps still on `dBrief`).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: extract shared ML model types into dBriefWire target"
```

---

### Task 2: Define the wire envelope, request/event enums, and `WireError`

**Files:**
- Create: `Sources/dBriefWire/Wire/Envelope.swift`
- Test: `Tests/dBriefTests/WireEnvelopeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/dBriefTests/WireEnvelopeTests.swift`:

```swift
import Testing
import Foundation
@testable import dBriefWire

@Suite struct WireEnvelopeTests {
    @Test func requestRoundTrips() throws {
        let req = RequestEnvelope(
            id: UUID(),
            request: .transcribe(path: "/tmp/a.m4a", initialPrompt: "hi",
                                 config: .default, safeMode: false)
        )
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(RequestEnvelope.self, from: data)
        #expect(decoded.id == req.id)
        if case let .transcribe(path, prompt, _, safe) = decoded.request {
            #expect(path == "/tmp/a.m4a")
            #expect(prompt == "hi")
            #expect(safe == false)
        } else { Issue.record("wrong request case") }
    }

    @Test func eventRoundTripsResultAndError() throws {
        let id = UUID()
        let result = EventEnvelope(id: id, channel: .plugin,
            event: .transcriptionResult(TranscriptionResult(text: "x")))
        let rDecoded = try JSONDecoder().decode(
            EventEnvelope.self, from: try JSONEncoder().encode(result))
        if case let .transcriptionResult(tr) = rDecoded.event {
            #expect(tr.text == "x")
        } else { Issue.record("wrong event case") }

        let err = EventEnvelope(id: id, channel: .plugin,
            event: .error(WireError(kind: .insufficientMemory,
                                    message: "need 4 GB", model: "Large", requiredGB: "4.0")))
        let eDecoded = try JSONDecoder().decode(
            EventEnvelope.self, from: try JSONEncoder().encode(err))
        if case let .error(w) = eDecoded.event {
            #expect(w.kind == .insufficientMemory)
            #expect(w.requiredGB == "4.0")
        } else { Issue.record("wrong event case") }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WireEnvelopeTests`
Expected: FAIL (compile error — `RequestEnvelope`/`EventEnvelope`/`WireError` not defined).

- [ ] **Step 3: Implement `Sources/dBriefWire/Wire/Envelope.swift`**

```swift
import Foundation

public enum MLChannel: String, Sendable, Codable {
    case plugin     // WhisperKit + SpeakerKit + MLX state stream
    case parakeet   // Parakeet state stream
}

public enum MLRequest: Sendable, Codable {
    case transcribe(path: String, initialPrompt: String?, config: WhisperRuntimeConfig, safeMode: Bool)
    case diarize(path: String)
    case analyze(text: String, outputLanguage: OutputLanguage)
    case analyzeStream(text: String, outputLanguage: OutputLanguage)
    case chatStream(systemPrompt: String, userMessage: String)
    case parakeetTranscribe(path: String, modelVariant: String)
    case prepareModels
    case downloadWhisper(config: WhisperRuntimeConfig)
    case downloadLLM
    case downloadParakeet(variant: String)
    case isWhisperCached(name: String)
    case isLLMCached
    case isParakeetCached
    case purgeModels
    case purgeWhisper
    case purgeSpeakerKit
    case purgeQwen
    case purgeParakeet
    case memoryPressurePurge
    case forceUnload
    case cancel
}

public enum MLEvent: Sendable, Codable {
    case state(LocalAIPluginState)              // progress, carried per-channel
    case token(String)                          // one chunk of a streaming response
    case transcriptionResult(TranscriptionResult)
    case diarizeResult([DiarizedTurn])
    case insightsResult(LocalInsightsResult)
    case boolResult(Bool)
    case voidResult                             // terminal success for no-value ops
    case error(WireError)                       // terminal thrown (non-crash) error
    case finished                               // terminal marker for streaming ops
}

public struct RequestEnvelope: Sendable, Codable {
    public let id: UUID
    public let request: MLRequest
    public init(id: UUID, request: MLRequest) {
        self.id = id
        self.request = request
    }
}

public struct EventEnvelope: Sendable, Codable {
    public let id: UUID
    public let channel: MLChannel
    public let event: MLEvent
    public init(id: UUID, channel: MLChannel, event: MLEvent) {
        self.id = id
        self.channel = channel
        self.event = event
    }
}

public struct WireError: Sendable, Codable, Error {
    public enum Kind: String, Sendable, Codable {
        case transcriptionTimeout
        case modelLoadTimeout
        case insufficientMemory
        case audioLoadFailed
        case diarizationFailed
        case generic
    }
    public let kind: Kind
    public let message: String
    public let model: String?
    public let requiredGB: String?

    public init(kind: Kind, message: String, model: String? = nil, requiredGB: String? = nil) {
        self.kind = kind
        self.message = message
        self.model = model
        self.requiredGB = requiredGB
    }
}
```

> `OutputLanguage` must conform to `Codable` (it already will once moved to `dBriefWire` per Task 1 Step 5; confirm it is `public ... Codable`).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WireEnvelopeTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(wire): add request/event envelope and WireError types"
```

---

### Task 3: Length-prefixed framing codec

**Files:**
- Create: `Sources/dBriefWire/Wire/Frame.swift`
- Test: `Tests/dBriefTests/FrameCodecTests.swift`

- [ ] **Step 1: Write the failing test** (covers a clean frame, two concatenated frames, and a length prefix split across reads)

Create `Tests/dBriefTests/FrameCodecTests.swift`:

```swift
import Testing
import Foundation
@testable import dBriefWire

@Suite struct FrameCodecTests {
    @Test func encodeThenDecodeSingleFrame() throws {
        let payload = Data("hello".utf8)
        let framed = FrameCodec.encode(payload)
        var reader = FrameReader()
        reader.append(framed)
        let frames = reader.drainFrames()
        #expect(frames == [payload])
    }

    @Test func decodesTwoConcatenatedFrames() throws {
        var blob = FrameCodec.encode(Data("one".utf8))
        blob.append(FrameCodec.encode(Data("two".utf8)))
        var reader = FrameReader()
        reader.append(blob)
        #expect(reader.drainFrames() == [Data("one".utf8), Data("two".utf8)])
    }

    @Test func handlesLengthPrefixSplitAcrossReads() throws {
        let framed = FrameCodec.encode(Data("split".utf8))
        var reader = FrameReader()
        reader.append(framed.prefix(2))            // partial length prefix
        #expect(reader.drainFrames().isEmpty)
        reader.append(framed.suffix(from: 2))      // remainder
        #expect(reader.drainFrames() == [Data("split".utf8)])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FrameCodecTests`
Expected: FAIL (compile error — `FrameCodec`/`FrameReader` not defined).

- [ ] **Step 3: Implement `Sources/dBriefWire/Wire/Frame.swift`**

```swift
import Foundation

public enum FrameCodec {
    /// 4-byte big-endian length prefix followed by the payload bytes.
    public static func encode(_ payload: Data) -> Data {
        var out = Data(capacity: 4 + payload.count)
        var be = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}

/// Accumulates raw bytes and yields complete frames as they arrive.
/// Handles partial reads and length prefixes split across reads.
public struct FrameReader {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: some DataProtocol) {
        buffer.append(contentsOf: data)
    }

    /// Returns every complete frame currently buffered, consuming their bytes.
    public mutating func drainFrames() -> [Data] {
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let total = 4 + Int(length)
            guard buffer.count >= total else { break }
            let payload = buffer.subdata(in: 4..<total)
            frames.append(payload)
            buffer.removeSubrange(0..<total)
        }
        return frames
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FrameCodecTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(wire): add length-prefixed frame codec"
```

---

## Phase 2 — Helper executable (`dBriefMLHost`)

### Task 4: Create the helper target and move the ML services into it

**Files:**
- Modify: `Package.swift`
- Move: `Sources/dBrief/Services/WhisperKitTranscriptionService.swift` → `Sources/dBriefMLHost/WhisperKitTranscriptionService.swift`
- Move: `Sources/dBrief/Services/MLXInsightsService.swift` → `Sources/dBriefMLHost/MLXInsightsService.swift`
- Move: `Sources/dBrief/Services/ParakeetTranscriptionService.swift` → `Sources/dBriefMLHost/ParakeetTranscriptionService.swift`
- Create: `Sources/dBriefMLHost/AsyncMutex.swift`
- Create: `Sources/dBriefMLHost/SupportPaths.swift`

- [ ] **Step 1: Add the executable target in `Package.swift`**

```swift
.executableTarget(
    name: "dBriefMLHost",
    dependencies: [
        "dBriefWire",
        "WhisperKit",
        .product(name: "SpeakerKit", package: "WhisperKit"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        "FluidAudio",
        .product(name: "Hub", package: "swift-transformers"),
        .product(name: "Tokenizers", package: "swift-transformers"),
    ]
),
```

- [ ] **Step 2: Move the three service files into the helper target**

```bash
mkdir -p Sources/dBriefMLHost
git mv Sources/dBrief/Services/WhisperKitTranscriptionService.swift Sources/dBriefMLHost/WhisperKitTranscriptionService.swift
git mv Sources/dBrief/Services/MLXInsightsService.swift Sources/dBriefMLHost/MLXInsightsService.swift
git mv Sources/dBrief/Services/ParakeetTranscriptionService.swift Sources/dBriefMLHost/ParakeetTranscriptionService.swift
```

Add `import dBriefWire` to the top of each moved file (they reference `TranscriptionResult`, `WhisperRuntimeConfig`, `LocalAIPluginState`, `DiarizedTurn`, `LocalInsightsResult`).

- [ ] **Step 3: Create `Sources/dBriefMLHost/AsyncMutex.swift`**

Move the `AsyncMutex` actor out of the old `LocalAIPluginService.swift` (lines 233–262) verbatim into this file.

- [ ] **Step 4: Add injected support-path resolution**

The services currently derive their model directory from `Bundle.main.bundleIdentifier ?? "dBrief"`. In the helper, `Bundle.main.bundleIdentifier` differs from the app's `com.dbrief.app`, so the cache path would diverge. Create `Sources/dBriefMLHost/SupportPaths.swift`:

```swift
import Foundation

/// The Application Support base the parent app passes via `--support-base`,
/// so the helper resolves the SAME model cache directory as the app.
enum SupportPaths {
    /// Set once at launch from `main.swift`. Example value:
    /// `~/Library/Application Support/com.dbrief.app/LocalAIPlugin`
    nonisolated(unsafe) static var localAIPluginBase: URL!
}
```

In each moved service, replace the directory-building helpers
(`whisperDownloadBaseURL()`, `speakerKitDownloadBaseURL()`, `llmDownloadBaseURL()`,
`isModelDownloaded()`, and the Parakeet equivalent) so they start from
`SupportPaths.localAIPluginBase.appendingPathComponent("WhisperKit")` (etc.)
instead of `appSupport/<bundleId>/LocalAIPlugin/...`. Grep each occurrence:
`rg -n "LocalAIPlugin|bundleIdentifier" Sources/dBriefMLHost`.

- [ ] **Step 5: Verify the helper target compiles in isolation**

Run: `swift build --target dBriefMLHost`
Expected: PASS (the helper has no `main.swift` yet — that comes in Task 6; an executable target with no entry point still type-checks its sources. If SPM complains about a missing entry point, proceed to Task 6 first, then return and run this).

> The `dBrief` app target will **not** build cleanly right now because it still imports the moved services. That is fixed in Phase 3 when the proxies replace them. Do not attempt `swift build` of the whole package until Task 8/9.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: move WhisperKit/MLX/Parakeet services into dBriefMLHost target"
```

---

### Task 5: Helper orchestrator + request loop

**Files:**
- Create: `Sources/dBriefMLHost/MLOrchestrator.swift`
- Create: `Sources/dBriefMLHost/RequestLoop.swift`
- Test: `Tests/dBriefMLHostTests/RequestRoutingTests.swift`
- Modify: `Package.swift` (add `dBriefMLHostTests` test target)

The orchestrator is the old `LocalAIPluginService` actor logic (GPU mutex serialization + per-op unload), but instead of vending an `AsyncStream` to the UI it calls an injected `emit: (MLChannel, MLEvent) -> Void` closure. The request loop owns stdin/stdout and the per-request cancellation map.

- [ ] **Step 1: Write the failing test for op routing**

Create `Tests/dBriefMLHostTests/RequestRoutingTests.swift`. It drives `RequestRouter` (a thin dispatcher) with a mock ML backend and asserts the emitted events:

```swift
import Testing
import Foundation
import dBriefWire
@testable import dBriefMLHost

actor MockBackend: MLBackend {
    func transcribe(path: String, initialPrompt: String?, config: WhisperRuntimeConfig, safeMode: Bool) async throws -> TranscriptionResult {
        TranscriptionResult(text: "mock:\(path):safe=\(safeMode)")
    }
    func diarize(path: String) async throws -> [DiarizedTurn] { [] }
    func analyze(text: String, outputLanguage: OutputLanguage) async throws -> LocalInsightsResult {
        LocalInsightsResult(summary: "s", actionItems: [], tags: [], sentiment: "Neutral")
    }
    func analyzeStream(text: String, outputLanguage: OutputLanguage, emitToken: @Sendable (String) -> Void) async throws { emitToken("a"); emitToken("b") }
    func chatStream(systemPrompt: String, userMessage: String, emitToken: @Sendable (String) -> Void) async throws { emitToken("hi") }
    func parakeetTranscribe(path: String, modelVariant: String) async throws -> TranscriptionResult { TranscriptionResult(text: "pk") }
    func prepareModels() async {}
    func downloadWhisper(config: WhisperRuntimeConfig) async throws {}
    func downloadLLM() async throws {}
    func downloadParakeet(variant: String) async throws {}
    func isWhisperCached(name: String) async -> Bool { true }
    func isLLMCached() async -> Bool { false }
    func isParakeetCached() async -> Bool { true }
    func purgeModels() async throws {}
    func purgeWhisper() async throws {}
    func purgeSpeakerKit() async throws {}
    func purgeQwen() async throws {}
    func purgeParakeet() async throws {}
    func memoryPressurePurge() async {}
    func forceUnload() async {}
}

@Suite struct RequestRoutingTests {
    @Test func transcribeEmitsResultThenFinished() async throws {
        let collected = EventCollector()
        let router = RequestRouter(backend: MockBackend()) { env in collected.append(env) }
        let id = UUID()
        await router.handle(RequestEnvelope(id: id,
            request: .transcribe(path: "/x.m4a", initialPrompt: nil, config: .default, safeMode: true)))
        let events = collected.events
        guard case let .transcriptionResult(tr) = events.first?.event else {
            Issue.record("expected result first"); return
        }
        #expect(tr.text == "mock:/x.m4a:safe=true")
        #expect(events.last.map { if case .finished = $0.event { true } else { false } } == true)
        #expect(events.allSatisfy { $0.id == id })
    }

    @Test func streamEmitsTokensThenFinished() async throws {
        let collected = EventCollector()
        let router = RequestRouter(backend: MockBackend()) { env in collected.append(env) }
        await router.handle(RequestEnvelope(id: UUID(),
            request: .analyzeStream(text: "t", outputLanguage: .auto)))
        let tokens = collected.events.compactMap { if case let .token(s) = $0.event { s } else { nil } }
        #expect(tokens == ["a", "b"])
        #expect(collected.events.last.map { if case .finished = $0.event { true } else { false } } == true)
    }
}

final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [EventEnvelope] = []
    func append(_ e: EventEnvelope) { lock.lock(); _events.append(e); lock.unlock() }
    var events: [EventEnvelope] { lock.lock(); defer { lock.unlock() }; return _events }
}
```

> Use `.auto` only if that is a real `OutputLanguage` case — substitute the first actual case from your `OutputLanguage` enum (check via the grep from Task 1 Step 5).

- [ ] **Step 2: Add the `dBriefMLHostTests` target to `Package.swift`**

```swift
.testTarget(
    name: "dBriefMLHostTests",
    dependencies: [
        "dBriefMLHost",
        "dBriefWire",
        .product(name: "Testing", package: "swift-testing"),
    ]
),
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter RequestRoutingTests`
Expected: FAIL (compile error — `MLBackend`/`RequestRouter` not defined).

- [ ] **Step 4: Define `MLBackend` and `RequestRouter`**

Create the `MLBackend` protocol (the seam the mock implements and `MLOrchestrator` conforms to) and `RequestRouter` in `Sources/dBriefMLHost/RequestLoop.swift`:

```swift
import Foundation
import dBriefWire

protocol MLBackend: Sendable {
    func transcribe(path: String, initialPrompt: String?, config: WhisperRuntimeConfig, safeMode: Bool) async throws -> TranscriptionResult
    func diarize(path: String) async throws -> [DiarizedTurn]
    func analyze(text: String, outputLanguage: OutputLanguage) async throws -> LocalInsightsResult
    func analyzeStream(text: String, outputLanguage: OutputLanguage, emitToken: @Sendable (String) -> Void) async throws
    func chatStream(systemPrompt: String, userMessage: String, emitToken: @Sendable (String) -> Void) async throws
    func parakeetTranscribe(path: String, modelVariant: String) async throws -> TranscriptionResult
    func prepareModels() async
    func downloadWhisper(config: WhisperRuntimeConfig) async throws
    func downloadLLM() async throws
    func downloadParakeet(variant: String) async throws
    func isWhisperCached(name: String) async -> Bool
    func isLLMCached() async -> Bool
    func isParakeetCached() async -> Bool
    func purgeModels() async throws
    func purgeWhisper() async throws
    func purgeSpeakerKit() async throws
    func purgeQwen() async throws
    func purgeParakeet() async throws
    func memoryPressurePurge() async
    func forceUnload() async
}

/// Maps one inbound request to backend calls and emits tagged events.
/// Channel selection: Parakeet ops use `.parakeet`; everything else `.plugin`.
final class RequestRouter: Sendable {
    private let backend: MLBackend
    private let emit: @Sendable (EventEnvelope) -> Void

    init(backend: MLBackend, emit: @escaping @Sendable (EventEnvelope) -> Void) {
        self.backend = backend
        self.emit = emit
    }

    func handle(_ envelope: RequestEnvelope) async {
        let id = envelope.id
        let channel: MLChannel = {
            switch envelope.request {
            case .parakeetTranscribe, .downloadParakeet, .isParakeetCached, .purgeParakeet: .parakeet
            default: .plugin
            }
        }()
        func send(_ event: MLEvent) { emit(EventEnvelope(id: id, channel: channel, event: event)) }

        do {
            switch envelope.request {
            case let .transcribe(path, prompt, config, safeMode):
                let r = try await backend.transcribe(path: path, initialPrompt: prompt, config: config, safeMode: safeMode)
                send(.transcriptionResult(r)); send(.finished)
            case let .diarize(path):
                send(.diarizeResult(try await backend.diarize(path: path))); send(.finished)
            case let .analyze(text, lang):
                send(.insightsResult(try await backend.analyze(text: text, outputLanguage: lang))); send(.finished)
            case let .analyzeStream(text, lang):
                try await backend.analyzeStream(text: text, outputLanguage: lang) { send(.token($0)) }
                send(.finished)
            case let .chatStream(system, user):
                try await backend.chatStream(systemPrompt: system, userMessage: user) { send(.token($0)) }
                send(.finished)
            case let .parakeetTranscribe(path, variant):
                send(.transcriptionResult(try await backend.parakeetTranscribe(path: path, modelVariant: variant))); send(.finished)
            case .prepareModels:
                await backend.prepareModels(); send(.voidResult); send(.finished)
            case let .downloadWhisper(config):
                try await backend.downloadWhisper(config: config); send(.voidResult); send(.finished)
            case .downloadLLM:
                try await backend.downloadLLM(); send(.voidResult); send(.finished)
            case let .downloadParakeet(variant):
                try await backend.downloadParakeet(variant: variant); send(.voidResult); send(.finished)
            case let .isWhisperCached(name):
                send(.boolResult(await backend.isWhisperCached(name: name))); send(.finished)
            case .isLLMCached:
                send(.boolResult(await backend.isLLMCached())); send(.finished)
            case .isParakeetCached:
                send(.boolResult(await backend.isParakeetCached())); send(.finished)
            case .purgeModels: try await backend.purgeModels(); send(.voidResult); send(.finished)
            case .purgeWhisper: try await backend.purgeWhisper(); send(.voidResult); send(.finished)
            case .purgeSpeakerKit: try await backend.purgeSpeakerKit(); send(.voidResult); send(.finished)
            case .purgeQwen: try await backend.purgeQwen(); send(.voidResult); send(.finished)
            case .purgeParakeet: try await backend.purgeParakeet(); send(.voidResult); send(.finished)
            case .memoryPressurePurge: await backend.memoryPressurePurge(); send(.voidResult); send(.finished)
            case .forceUnload: await backend.forceUnload(); send(.voidResult); send(.finished)
            case .cancel: break // handled by RequestLoop task cancellation, not the router
            }
        } catch let w as WireError {
            send(.error(w))
        } catch {
            send(.error(WireError(kind: .generic, message: error.localizedDescription)))
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter RequestRoutingTests`
Expected: PASS.

- [ ] **Step 6: Implement `MLOrchestrator` conforming to `MLBackend`**

Create `Sources/dBriefMLHost/MLOrchestrator.swift`. Port the body of the old `LocalAIPluginService` actor: hold `WhisperKitTranscriptionService`, `MLXInsightsService`, `ParakeetTranscriptionService`; keep the `AsyncMutex` serialization and per-op `unload()` calls; thread the moved services' `stateHandler` closures into `emit(.state(...))` on the correct channel. The `transcribe(..., safeMode:)` parameter selects `concurrentWorkerCount` (see Task 13). Map `TranscriptionServiceError` → `WireError`:

```swift
func wireError(from error: Error) -> WireError {
    switch error {
    case TranscriptionServiceError.insufficientMemory(let model, let gb):
        WireError(kind: .insufficientMemory, message: error.localizedDescription, model: model, requiredGB: gb)
    case TranscriptionServiceError.audioLoadFailed(let m):
        WireError(kind: .audioLoadFailed, message: m)
    case TranscriptionServiceError.transcriptionTimeout:
        WireError(kind: .transcriptionTimeout, message: error.localizedDescription)
    case TranscriptionServiceError.modelLoadTimeout:
        WireError(kind: .modelLoadTimeout, message: error.localizedDescription)
    case TranscriptionServiceError.diarizationFailed(let m):
        WireError(kind: .diarizationFailed, message: m)
    default:
        WireError(kind: .generic, message: error.localizedDescription)
    }
}
```

Throw `WireError` from the orchestrator's backend methods (so the router's `catch let w as WireError` produces faithful errors). Move `TranscriptionServiceError` itself into the helper target if it is not already there (it lives in `WhisperKitTranscriptionService.swift`, which moved in Task 4 — so it is already here).

Run: `swift build --target dBriefMLHost`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(mlhost): add request router and MLOrchestrator backend"
```

---

### Task 6: Helper entry point, stdin/stdout loop, cancellation, crash hook

**Files:**
- Create: `Sources/dBriefMLHost/main.swift`
- Modify: `Sources/dBriefMLHost/RequestLoop.swift` (add `RequestLoop`)

- [ ] **Step 1: Add `RequestLoop` to `RequestLoop.swift`**

`RequestLoop` reads frames from a `FileHandle` (stdin), decodes `RequestEnvelope`, spawns a `Task` per request (tracked by id for `.cancel`), and writes event frames to stdout (serialized through an actor to avoid interleaving):

```swift
actor StdoutWriter {
    private let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func send(_ envelope: EventEnvelope) {
        guard let payload = try? JSONEncoder().encode(envelope) else { return }
        handle.write(FrameCodec.encode(payload))
    }
}

final class RequestLoop: @unchecked Sendable {
    private let router: RequestRouter
    private let writer: StdoutWriter
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let lock = NSLock()

    init(backend: MLBackend, output: FileHandle) {
        let writer = StdoutWriter(output)
        self.writer = writer
        self.router = RequestRouter(backend: backend) { env in
            Task { await writer.send(env) }
        }
    }

    /// Blocks reading stdin until EOF (parent closed the pipe / is quitting).
    func run(input: FileHandle) async {
        var reader = FrameReader()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }   // EOF
            reader.append(chunk)
            for frame in reader.drainFrames() {
                guard let env = try? JSONDecoder().decode(RequestEnvelope.self, from: frame) else { continue }
                if case .cancel = env.request { cancel(env.id); continue }
                let task = Task { await self.router.handle(env) }
                store(task, for: env.id)
            }
        }
    }

    private func store(_ task: Task<Void, Never>, for id: UUID) {
        lock.lock(); tasks[id] = task; lock.unlock()
    }
    private func cancel(_ id: UUID) {
        lock.lock(); let t = tasks.removeValue(forKey: id); lock.unlock(); t?.cancel()
    }
}
```

- [ ] **Step 2: Implement `Sources/dBriefMLHost/main.swift`**

```swift
import Foundation
import dBriefWire

// Parse --support-base <path> so the helper resolves the SAME model cache as the app.
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--support-base"), i + 1 < args.count {
    SupportPaths.localAIPluginBase = URL(fileURLWithPath: args[i + 1])
} else {
    FileHandle.standardError.write(Data("dBriefMLHost: missing --support-base\n".utf8))
    exit(2)
}

let orchestrator = MLOrchestrator()

// Free Metal/GPU buffers before exit on SIGTERM (parent quitting).
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler {
    Task { await orchestrator.forceUnload(); exit(0) }
}
sigterm.resume()
signal(SIGTERM, SIG_IGN)

let loop = RequestLoop(backend: orchestrator, output: .standardOutput)
await loop.run(input: .standardInput)
// stdin EOF => parent gone; release resources and exit.
await orchestrator.forceUnload()
```

- [ ] **Step 3: Verify the helper builds and links**

Run: `swift build --target dBriefMLHost`
Expected: PASS — produces `.build/debug/dBriefMLHost`.

- [ ] **Step 4: Smoke-test the helper manually**

Run (sends a single `isWhisperCached` request and expects a framed reply on stdout):

```bash
swift run dBriefMLHost --support-base "$HOME/Library/Application Support/com.dbrief.app/LocalAIPlugin" </dev/null
```
Expected: exits cleanly on EOF (no crash, no missing-base error). Full round-trip is covered by the integration test in Task 7.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(mlhost): add stdin/stdout request loop and entry point"
```

---

## Phase 3 — Main-app proxy + transport

### Task 7: `MLHostConnection` — supervised child process + framed RPC

**Files:**
- Create: `Sources/dBrief/Services/MLHostConnection.swift`
- Test: `Tests/dBriefTests/MLHostConnectionTests.swift`
- Create (test fixture): `Sources/dBriefMLHostStub/main.swift` + `Package.swift` target

The connection: launches the helper, exposes `call(_:) async throws -> MLEvent` (awaits the terminal `.transcriptionResult`/`.insightsResult`/`.boolResult`/`.voidResult`/`.diarizeResult`, or throws on `.error`/crash), and `stream(_:) -> AsyncThrowingStream<String,Error>` (forwards `.token`s). It demultiplexes `.state` events to two `AsyncStream<LocalAIPluginState>` continuations keyed by `MLChannel`.

- [ ] **Step 1: Build a stub helper executable for deterministic tests**

Add a tiny stub target that speaks the same frame protocol with canned behavior, switchable by env var. Add to `Package.swift`:

```swift
.executableTarget(
    name: "dBriefMLHostStub",
    dependencies: ["dBriefWire"]
),
```

Create `Sources/dBriefMLHostStub/main.swift`:

```swift
import Foundation
import dBriefWire

// Behaviors via env: STUB_MODE = echo | crash-once | error
let mode = ProcessInfo.processInfo.environment["STUB_MODE"] ?? "echo"
let out = FileHandle.standardOutput
func send(_ e: EventEnvelope) { if let d = try? JSONEncoder().encode(e) { out.write(FrameCodec.encode(d)) } }

var reader = FrameReader()
while true {
    let chunk = FileHandle.standardInput.availableData
    if chunk.isEmpty { break }
    reader.append(chunk)
    for frame in reader.drainFrames() {
        guard let env = try? JSONDecoder().decode(RequestEnvelope.self, from: frame) else { continue }
        switch mode {
        case "crash-once":
            // Crash on the first transcribe, then behave on a relaunch (separate process => fresh env file flag).
            let flag = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stub_crashed")
            if case .transcribe = env.request, !FileManager.default.fileExists(atPath: flag.path) {
                try? Data().write(to: flag)
                exit(SIGKILL)   // simulate uncatchable trap
            }
            send(EventEnvelope(id: env.id, channel: .plugin,
                event: .transcriptionResult(TranscriptionResult(text: "recovered"))))
            send(EventEnvelope(id: env.id, channel: .plugin, event: .finished))
        case "error":
            send(EventEnvelope(id: env.id, channel: .plugin,
                event: .error(WireError(kind: .insufficientMemory, message: "no ram", model: "L", requiredGB: "9.9"))))
        default: // echo: state, then a result
            send(EventEnvelope(id: env.id, channel: .plugin, event: .state(.transcribing)))
            send(EventEnvelope(id: env.id, channel: .plugin,
                event: .transcriptionResult(TranscriptionResult(text: "echo"))))
            send(EventEnvelope(id: env.id, channel: .plugin, event: .finished))
        }
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/dBriefTests/MLHostConnectionTests.swift`. The connection takes an explicit binary URL so tests point it at the stub:

```swift
import Testing
import Foundation
import dBriefWire
@testable import dBrief

private func stubURL() -> URL {
    // .build/debug/dBriefMLHostStub relative to the package root
    URL(fileURLWithPath: ".build/debug/dBriefMLHostStub")
}

@Suite struct MLHostConnectionTests {
    @Test func callReturnsResult() async throws {
        let conn = MLHostConnection(binaryURL: stubURL(),
                                    supportBase: URL(fileURLWithPath: "/tmp"),
                                    environment: ["STUB_MODE": "echo"])
        let event = try await conn.call(.transcribe(path: "/a.m4a", initialPrompt: nil, config: .default, safeMode: false))
        guard case let .transcriptionResult(tr) = event else { Issue.record("no result"); return }
        #expect(tr.text == "echo")
        await conn.shutdown()
    }

    @Test func errorEventThrowsWireError() async {
        let conn = MLHostConnection(binaryURL: stubURL(),
                                    supportBase: URL(fileURLWithPath: "/tmp"),
                                    environment: ["STUB_MODE": "error"])
        await #expect(throws: WireError.self) {
            _ = try await conn.call(.transcribe(path: "/a.m4a", initialPrompt: nil, config: .default, safeMode: false))
        }
        await conn.shutdown()
    }

    @Test func crashSurfacesHelperCrashedError() async {
        // Clear the stub's crash flag first.
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stub_crashed"))
        let conn = MLHostConnection(binaryURL: stubURL(),
                                    supportBase: URL(fileURLWithPath: "/tmp"),
                                    environment: ["STUB_MODE": "crash-once"])
        await #expect(throws: MLHostError.helperCrashed) {
            _ = try await conn.call(.transcribe(path: "/a.m4a", initialPrompt: nil, config: .default, safeMode: false))
        }
        await conn.shutdown()
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift build --target dBriefMLHostStub && swift test --filter MLHostConnectionTests`
Expected: FAIL (compile error — `MLHostConnection`/`MLHostError` not defined).

- [ ] **Step 4: Implement `Sources/dBrief/Services/MLHostConnection.swift`**

```swift
import Foundation
import dBriefWire

enum MLHostError: Error, Equatable {
    case helperCrashed
    case helperUnavailable
}

/// Owns the child helper process, frames IO over its pipes, correlates replies
/// by request id, demultiplexes per-channel state, and relaunches on crash.
actor MLHostConnection {
    private let binaryURL: URL
    private let supportBase: URL
    private let extraEnvironment: [String: String]

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var reader = FrameReader()

    // Per-request inboxes. A terminal event (result/error/finished) completes the call.
    private struct Pending {
        var onEvent: (MLEvent) -> Void
        var onCrash: () -> Void
    }
    private var pending: [UUID: Pending] = [:]

    // Per-channel state stream continuations (vended to the proxies).
    private var stateContinuations: [MLChannel: AsyncStream<LocalAIPluginState>.Continuation] = [:]

    init(binaryURL: URL, supportBase: URL, environment: [String: String] = [:]) {
        self.binaryURL = binaryURL
        self.supportBase = supportBase
        self.extraEnvironment = environment
    }

    // MARK: state streams

    func stateStream(for channel: MLChannel) -> AsyncStream<LocalAIPluginState> {
        AsyncStream { continuation in
            stateContinuations[channel] = continuation
        }
    }

    // MARK: request/response

    /// Send a request and await its terminal event (`.error` throws the `WireError`,
    /// a process death throws `MLHostError.helperCrashed`).
    func call(_ request: MLRequest) async throws -> MLEvent {
        try ensureRunning()
        let id = UUID()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<MLEvent, Error>) in
            var resolved = false
            pending[id] = Pending(
                onEvent: { event in
                    if resolved { return }
                    switch event {
                    case .state, .token: return        // non-terminal for call()
                    case .finished: return             // terminal handled below after a value
                    case .error(let w): resolved = true; cont.resume(throwing: w)
                    default: resolved = true; cont.resume(returning: event)
                    }
                },
                onCrash: { if !resolved { resolved = true; cont.resume(throwing: MLHostError.helperCrashed) } }
            )
            write(RequestEnvelope(id: id, request: request))
        }
    }

    /// Stream tokens for `analyzeStream`/`chatStream`.
    func stream(_ request: MLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            do { try ensureRunning() } catch {
                continuation.finish(throwing: error); return
            }
            pending[id] = Pending(
                onEvent: { event in
                    switch event {
                    case .token(let s): continuation.yield(s)
                    case .finished: continuation.finish()
                    case .error(let w): continuation.finish(throwing: w)
                    default: break
                    }
                },
                onCrash: { continuation.finish(throwing: MLHostError.helperCrashed) }
            )
            continuation.onTermination = { @Sendable _ in
                Task { await self.write(RequestEnvelope(id: id, request: .cancel)) }
            }
            write(RequestEnvelope(id: id, request: request))
        }
    }

    func shutdown() {
        process?.terminate()
        process = nil
        stdinHandle = nil
    }

    // MARK: process lifecycle

    private func ensureRunning() throws {
        if process?.isRunning == true { return }
        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["--support-base", supportBase.path]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnvironment { env[k] = v }
        proc.environment = env

        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        // stderr inherited so the helper's OSLog/stderr surfaces.

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.ingest(data) }
        }
        proc.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination() }
        }
        try proc.run()
        self.process = proc
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.reader = FrameReader()
    }

    private func ingest(_ data: Data) {
        reader.append(data)
        for frame in reader.drainFrames() {
            guard let env = try? JSONDecoder().decode(EventEnvelope.self, from: frame) else { continue }
            if case let .state(state) = env.event {
                stateContinuations[env.channel]?.yield(state)
            }
            if let p = pending[env.id] {
                p.onEvent(env.event)
                if case .finished = env.event { pending[env.id] = nil }
                if case .error = env.event { pending[env.id] = nil }
            }
        }
    }

    private func handleTermination() {
        let dead = pending
        pending.removeAll()
        process = nil
        stdinHandle = nil
        for (_, p) in dead { p.onCrash() }
    }

    private func write(_ envelope: RequestEnvelope) {
        guard let stdinHandle, let payload = try? JSONEncoder().encode(envelope) else { return }
        stdinHandle.write(FrameCodec.encode(payload))
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift build --target dBriefMLHostStub && swift test --filter MLHostConnectionTests`
Expected: PASS (echo returns result; error throws `WireError`; crash throws `MLHostError.helperCrashed`).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add MLHostConnection supervised child-process RPC transport"
```

---

### Task 8: Rewrite `LocalAIPluginService` as a proxy

**Files:**
- Create: `Sources/dBrief/Services/LocalAIPluginService.swift` (replaces the old actor)
- Test: `Tests/dBriefTests/LocalAIPluginProxyTests.swift`

The proxy keeps the exact public surface `RecordingManager`/`TranscriptChatService` call today, but every method forwards through a shared `MLHostConnection`. The shared connection is created once and injected (so Parakeet's proxy reuses it in Task 9).

- [ ] **Step 1: Add a helper-binary locator + shared connection factory**

In the new `LocalAIPluginService.swift`, add a small resolver:

```swift
import Foundation
import dBriefWire

enum MLHostLocator {
    /// `Contents/MacOS/dBriefMLHost` next to the running app; falls back to the
    /// SwiftPM build dir when running unbundled (e.g. `swift run`).
    static func binaryURL() -> URL {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/dBriefMLHost")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return Bundle.main.bundleURL.appendingPathComponent("dBriefMLHost")
    }

    static func supportBase() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("com.dbrief.app", isDirectory: true)
            .appendingPathComponent("LocalAIPlugin", isDirectory: true)
    }
}
```

> Use the literal `com.dbrief.app` (the app's real bundle id) rather than `Bundle.main.bundleIdentifier`, so the path is stable whether bundled or run via `swift run`.

- [ ] **Step 2: Implement the proxy**

```swift
final class LocalAIPluginService: LocalAIPluginProtocol, Sendable {
    let connection: MLHostConnection
    nonisolated let stateStream: AsyncStream<LocalAIPluginState>

    init(connection: MLHostConnection) {
        self.connection = connection
        // Capture the .plugin channel state stream synchronously at init.
        let box = UnsafeStreamBox()
        let sem = DispatchSemaphore(value: 0)
        Task { box.stream = await connection.stateStream(for: .plugin); sem.signal() }
        sem.wait()
        self.stateStream = box.stream!
    }

    convenience init() {
        self.init(connection: MLHostConnection(
            binaryURL: MLHostLocator.binaryURL(),
            supportBase: MLHostLocator.supportBase()))
    }

    func transcribe(fileURL: URL, initialPrompt: String?, whisperConfig: WhisperRuntimeConfig) async throws -> TranscriptionResult {
        try await transcribeWithRetry(path: fileURL.path, prompt: initialPrompt, config: whisperConfig)
    }

    func diarize(fileURL: URL) async throws -> [DiarizedTurn] {
        guard case let .diarizeResult(turns) = try await connection.call(.diarize(path: fileURL.path)) else { return [] }
        return turns
    }

    func analyzeTranscript(_ text: String, outputLanguage: OutputLanguage) async throws -> LocalInsightsResult {
        guard case let .insightsResult(r) = try await connection.call(.analyze(text: text, outputLanguage: outputLanguage)) else {
            throw WireError(kind: .generic, message: "no insights")
        }
        return r
    }

    func analyzeTranscriptStream(_ text: String, outputLanguage: OutputLanguage) async -> AsyncThrowingStream<String, Error> {
        await connection.stream(.analyzeStream(text: text, outputLanguage: outputLanguage))
    }

    func chatStream(systemPrompt: String, userMessage: String) async -> AsyncThrowingStream<String, Error> {
        await connection.stream(.chatStream(systemPrompt: systemPrompt, userMessage: userMessage))
    }

    func copyToClipboard(transcript: String, insights: LocalInsightsResult) async -> String {
        // Formatting is pure + needs AppKit pasteboard — keep it in-process (unchanged).
        let markdown = ObsidianFormatter.format(transcript: transcript, insights: insights)
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
        }
        return markdown
    }

    func prepareModelsIfNeeded() async { _ = try? await connection.call(.prepareModels) }
    func downloadWhisperModel(config: WhisperRuntimeConfig) async throws { _ = try await connection.call(.downloadWhisper(config: config)) }
    func downloadLLMModel() async throws { _ = try await connection.call(.downloadLLM) }
    func isWhisperModelCached(name: String) async -> Bool { (try? await connection.call(.isWhisperCached(name: name))).flatMap(Self.bool) ?? false }
    func isLLMModelCached() async -> Bool { (try? await connection.call(.isLLMCached)).flatMap(Self.bool) ?? false }
    func purgeModels() async throws { _ = try await connection.call(.purgeModels) }
    func purgeWhisperModel() async throws { _ = try await connection.call(.purgeWhisper) }
    func purgeSpeakerKitModel() async throws { _ = try await connection.call(.purgeSpeakerKit) }
    func purgeQwenModel() async throws { _ = try await connection.call(.purgeQwen) }
    func purgeModelsOnMemoryPressure() async { _ = try? await connection.call(.memoryPressurePurge) }
    func forceUnload() async { _ = try? await connection.call(.forceUnload) }

    private static func bool(_ e: MLEvent) -> Bool? { if case let .boolResult(b) = e { b } else { nil } }
}

import AppKit

final class UnsafeStreamBox: @unchecked Sendable { var stream: AsyncStream<LocalAIPluginState>? }
```

> The synchronous stream capture (`UnsafeStreamBox` + semaphore) keeps `stateStream` a stored `let` matching the protocol. If the team prefers, refactor the protocol's `stateStream` to be obtained via an `async` factory — but that touches `RecordingManager`; the box keeps blast radius minimal.

- [ ] **Step 3: Add the retry-aware transcribe (stub for now; real logic in Task 10)**

```swift
extension LocalAIPluginService {
    func transcribeWithRetry(path: String, prompt: String?, config: WhisperRuntimeConfig) async throws -> TranscriptionResult {
        guard case let .transcriptionResult(r) = try await connection.call(
            .transcribe(path: path, initialPrompt: prompt, config: config, safeMode: false)
        ) else { throw WireError(kind: .generic, message: "no transcription") }
        return r
    }
}
```

- [ ] **Step 4: Write a proxy test against the stub**

Create `Tests/dBriefTests/LocalAIPluginProxyTests.swift`:

```swift
import Testing
import Foundation
import dBriefWire
@testable import dBrief

@Suite struct LocalAIPluginProxyTests {
    @Test func transcribeForwardsAndReturns() async throws {
        let conn = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
                                    supportBase: URL(fileURLWithPath: "/tmp"),
                                    environment: ["STUB_MODE": "echo"])
        let svc = LocalAIPluginService(connection: conn)
        let result = try await svc.transcribe(fileURL: URL(fileURLWithPath: "/a.m4a"),
                                               initialPrompt: nil, whisperConfig: .default)
        #expect(result.text == "echo")
        await conn.shutdown()
    }
}
```

- [ ] **Step 5: Run the test**

Run: `swift build --target dBriefMLHostStub && swift test --filter LocalAIPluginProxyTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: rewrite LocalAIPluginService as IPC proxy over MLHostConnection"
```

---

### Task 9: Rewrite `ParakeetTranscriptionService` as a proxy (shared connection)

**Files:**
- Create: `Sources/dBrief/Services/ParakeetTranscriptionService.swift` (replaces old)
- Modify: `Sources/dBrief/Services/RecordingManager.swift` (share one connection)

- [ ] **Step 1: Implement the Parakeet proxy**

Match the old public surface used by `RecordingManager` (`transcribe(fileURL:initialPrompt:modelVariant:)`, `purgeModels()`, `prepareModel(variant:)`, `isModelDownloaded()`, `stateStream`). It uses the `.parakeet` channel:

```swift
import Foundation
import dBriefWire

final class ParakeetTranscriptionService: Sendable {
    private let connection: MLHostConnection
    nonisolated let stateStream: AsyncStream<LocalAIPluginState>

    init(connection: MLHostConnection) {
        self.connection = connection
        let box = UnsafeStreamBox()
        let sem = DispatchSemaphore(value: 0)
        Task { box.stream = await connection.stateStream(for: .parakeet); sem.signal() }
        sem.wait()
        self.stateStream = box.stream!
    }

    func transcribe(fileURL: URL, initialPrompt: String?, modelVariant: String) async throws -> TranscriptionResult {
        guard case let .transcriptionResult(r) = try await connection.call(
            .parakeetTranscribe(path: fileURL.path, modelVariant: modelVariant)
        ) else { throw WireError(kind: .generic, message: "no transcription") }
        return r
    }

    func prepareModel(variant: String) async throws { _ = try await connection.call(.downloadParakeet(variant: variant)) }
    func purgeModels() async throws { _ = try await connection.call(.purgeParakeet) }
    func isModelDownloaded() -> Bool { false } // see note
}
```

> The old `isModelDownloaded()` was synchronous (`nonisolated func`). Crossing a process makes it async. Check its call sites: `rg -n "parakeetService.isModelDownloaded" Sources/dBrief`. If the single call site (`RecordingManager` ~line 835) is already in an `async` context, change the proxy method to `func isModelDownloaded() async -> Bool { (try? await connection.call(.isParakeetCached)).flatMap { if case let .boolResult(b) = $0 { b } else { nil } } ?? false }` and `await` it at the call site. Confirm the exact signature change compiles.

- [ ] **Step 2: Wire one shared connection in `RecordingManager`**

Replace the two independent service instances (lines 17–20) with a shared connection:

```swift
private let mlHost = MLHostConnection(
    binaryURL: MLHostLocator.binaryURL(),
    supportBase: MLHostLocator.supportBase())
private lazy var localAIPluginService = LocalAIPluginService(connection: mlHost)
private lazy var parakeetService = ParakeetTranscriptionService(connection: mlHost)

var localPlugin: LocalAIPluginService { localAIPluginService }
```

Add `import dBriefWire` to `RecordingManager.swift`.

- [ ] **Step 3: Verify the whole package builds**

Run: `swift build`
Expected: PASS — the app target no longer references the moved services directly; everything goes through proxies. Fix any remaining `import dBriefWire` omissions the compiler flags.

- [ ] **Step 4: Run the full test suite**

Run: `swift build --target dBriefMLHostStub && swift test`
Expected: PASS (existing `WhisperPipelineTests`, `ProfileBehaviorTests`, `RichTranscriptBuilderTests`, `WhisperModelInfoTests` plus the new wire/connection/proxy tests).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: rewrite Parakeet service as IPC proxy; share one helper connection"
```

---

### Task 10: Auto-retry-once + safe mode on transcription crash

**Files:**
- Modify: `Sources/dBrief/Services/LocalAIPluginService.swift` (`transcribeWithRetry`)
- Test: `Tests/dBriefTests/TranscribeRetryTests.swift`

- [ ] **Step 1: Write the failing test (crash-once stub → retry succeeds)**

Create `Tests/dBriefTests/TranscribeRetryTests.swift`:

```swift
import Testing
import Foundation
import dBriefWire
@testable import dBrief

@Suite struct TranscribeRetryTests {
    @Test func retriesOnceAfterCrashThenSucceeds() async throws {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stub_crashed"))
        let conn = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
                                    supportBase: URL(fileURLWithPath: "/tmp"),
                                    environment: ["STUB_MODE": "crash-once"])
        let svc = LocalAIPluginService(connection: conn)
        let result = try await svc.transcribe(fileURL: URL(fileURLWithPath: "/a.m4a"),
                                               initialPrompt: nil, whisperConfig: .default)
        #expect(result.text == "recovered")   // first call crashed, retry returned this
        await conn.shutdown()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift build --target dBriefMLHostStub && swift test --filter TranscribeRetryTests`
Expected: FAIL — current `transcribeWithRetry` does not retry, so it throws `MLHostError.helperCrashed`.

- [ ] **Step 3: Implement retry + safe mode**

Replace the `transcribeWithRetry` extension from Task 8 Step 3:

```swift
extension LocalAIPluginService {
    func transcribeWithRetry(path: String, prompt: String?, config: WhisperRuntimeConfig) async throws -> TranscriptionResult {
        do {
            return try await runTranscribe(path: path, prompt: prompt, config: config, safeMode: false)
        } catch MLHostError.helperCrashed {
            // The helper trapped (e.g. WhisperKit nil-logits). It auto-relaunches on the
            // next call; retry ONCE in safe mode (low worker count, decoder off ANE).
            var safe = config
            safe.computeUnits = .cpuAndGPU
            return try await runTranscribe(path: path, prompt: prompt, config: safe, safeMode: true)
        }
        // A WireError (insufficient memory, audio load) propagates without retry.
    }

    private func runTranscribe(path: String, prompt: String?, config: WhisperRuntimeConfig, safeMode: Bool) async throws -> TranscriptionResult {
        guard case let .transcriptionResult(r) = try await connection.call(
            .transcribe(path: path, initialPrompt: prompt, config: config, safeMode: safeMode)
        ) else { throw WireError(kind: .generic, message: "no transcription") }
        return r
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TranscribeRetryTests`
Expected: PASS.

- [ ] **Step 5: Add the second-crash test (retry also crashes → clean error)**

Append to `TranscribeRetryTests.swift` a stub mode `crash-always` (add to the stub's switch: `case "crash-always": if case .transcribe = env.request { exit(SIGKILL) }`) and assert `transcribe` throws `MLHostError.helperCrashed` after the retry. Rebuild the stub and run:

Run: `swift build --target dBriefMLHostStub && swift test --filter TranscribeRetryTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: auto-retry transcription once in safe mode after helper crash"
```

---

## Phase 4 — Slim the app, package the helper, restore concurrency

### Task 11: Remove ML dependencies from the `dBrief` app target

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Drop the ML packages from the `dBrief` target's dependencies**

Edit the `dBrief` executable target so `dependencies` is only:

```swift
dependencies: [ "dBriefWire" ],
```

(WhisperKit/SpeakerKit/MLX/FluidAudio/Hub/Tokenizers remain on `dBriefMLHost`. Leave the top-level package `dependencies` array intact — the helper target still needs them.)

- [ ] **Step 2: Verify the app builds with no ML deps**

Run: `swift build --target dBrief`
Expected: PASS. If the compiler reports an unresolved `WhisperKit`/`MLX`/`FluidAudio` symbol in the app target, that file still references an ML type directly and must be routed through a proxy or moved to the helper — fix and rebuild.

- [ ] **Step 3: Full build + tests**

Run: `swift build && swift build --target dBriefMLHostStub && swift test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: remove ML package deps from the dBrief app target"
```

---

### Task 12: Package the helper into the app bundle (`make app`)

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Add helper-binary + metallib copy to the `app` target**

In `Makefile`, after the line copying the main executable
(`cp $(BUILD_DIR)/$(EXECUTABLE_NAME) $(MACOS)/$(EXECUTABLE_NAME)`), add:

```make
	cp $(BUILD_DIR)/dBriefMLHost $(MACOS)/dBriefMLHost
```

The `swift build -c release` in the `build` target already builds all executable targets, so `dBriefMLHost` exists in `$(BUILD_DIR)`. The existing metallib copy block already writes `default.metallib`/`mlx.metallib` into `$(MACOS)` (lines copying to `$(MACOS)/default.metallib` etc.), which sits beside `dBriefMLHost` — so MLX in the helper finds its metallib. No extra metallib step needed; confirm those `$(MACOS)/*.metallib` copies remain.

- [ ] **Step 2: Build the bundle and confirm both binaries are present**

Run: `make app && ls -la dBrief.app/Contents/MacOS/`
Expected: lists both `dBrief` and `dBriefMLHost`, plus `default.metallib`/`mlx.metallib`.

- [ ] **Step 3: Launch and smoke-test end to end**

Run: `make run`
Then in the app: record (or load a short audio file) with the Local Whisper engine and confirm transcription completes. In Console.app, filter for `dBriefMLHost` to confirm the helper process is running as a child.
Expected: transcription succeeds; `dBriefMLHost` appears as a separate process; killing it via Activity Monitor mid-transcription surfaces a clean error in the app (not an app crash) and the helper relaunches on the next attempt.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "build: bundle dBriefMLHost helper into the app and place metallib beside it"
```

---

### Task 13: Restore `concurrentWorkerCount` in the normal path (the payoff)

**Files:**
- Modify: `Sources/dBriefMLHost/WhisperKitTranscriptionService.swift`

- [ ] **Step 1: Thread `safeMode` into the worker-count choice**

`MLOrchestrator.transcribe(..., safeMode:)` already receives the flag (Task 5/6). Pass it into the WhisperKit service's transcribe and use it where `options.concurrentWorkerCount` is set (currently the hardcoded `4` at `WhisperKitTranscriptionService.swift:68`):

```swift
// Crash is now recoverable (process-isolated), so the normal path uses WhisperKit's
// default concurrency for speed. The safe-mode retry serializes to survive a
// deterministic nil-logits trap.
options.concurrentWorkerCount = safeMode ? 1 : 16
```

Update the `transcribe` signature on the service to accept `safeMode: Bool` and forward it from `MLOrchestrator`. (The helper-only signature change has no IPC impact — `safeMode` already crosses the wire in `MLRequest.transcribe`.)

- [ ] **Step 2: Build the helper**

Run: `swift build --target dBriefMLHost`
Expected: PASS.

- [ ] **Step 3: Benchmark and pick the final normal-path value**

Run `make run`, transcribe a representative ~10-minute recording with the user's usual model, and note the wall-clock time and whether any crash/retry occurs (Console filter `dBriefMLHost`). If crashes recur even when isolated (they should now only cost a retry, not the app), step the normal-path value down (16 → 8 → 4) until retries are rare. Record the chosen value in a code comment.
Expected: normal-path transcription is materially faster than the old `concurrentWorkerCount = 4`, and any residual crash is absorbed by the retry without taking down the app.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "perf: restore WhisperKit concurrency in the normal path now that crashes are isolated"
```

---

### Task 14: Final verification & cleanup

- [ ] **Step 1: Confirm the design's success criteria**

- Kill `dBriefMLHost` mid-transcription → app stays alive, surfaces a clean error, helper relaunches. ✅
- Local Whisper, Parakeet, MLX analysis, and transcript chat all work through the helper. ✅
- App target links no ML packages (`swift build --target dBrief` with deps = `["dBriefWire"]`). ✅
- Model cache is shared (helper uses `--support-base`; no re-download after the switch). Verify by transcribing without a re-download in Console. ✅

- [ ] **Step 2: Update `CLAUDE.md`**

Add a short subsection under "Local AI Plugin System" documenting the helper-process architecture (`dBriefMLHost`, `MLHostConnection`, the three-target split, the `--support-base` contract, and the auto-retry-once behavior). Use the `claude-md-management:revise-claude-md` skill if available.

- [ ] **Step 3: Update the memory note**

Mark `project_whisperkit_helper_process_isolation` as done (or delete it) since the planned work is implemented.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "docs: document the ML helper-process architecture in CLAUDE.md"
```

---

## Self-Review Notes

- **Spec coverage:** target split (Tasks 1, 4, 11) · transport/framing (Tasks 2, 3, 7) · all-ML-in-helper incl. Parakeet (Tasks 4, 5, 9) · persistent lazy-spawn + relaunch (Task 7) · per-op unload & GPU mutex moved into helper (Tasks 4, 5) · `.state`/`.token` stream reconstruction (Tasks 7, 8, 9) · `WireError` fidelity (Tasks 2, 5) · model-path injection via `--support-base` (Tasks 4, 6, 8) · auto-retry-once safe mode (Task 10) · concurrency restoration (Task 13) · packaging (Task 12) · tests (Tasks 2, 3, 5, 7, 8, 10). All spec sections are covered.
- **Type consistency:** `MLRequest`/`MLEvent`/`EventEnvelope`/`MLChannel`/`WireError`/`MLHostError`/`FrameCodec`/`FrameReader`/`MLBackend`/`RequestRouter`/`RequestLoop`/`MLHostConnection`/`MLHostLocator`/`SupportPaths` are used with identical names across all tasks. `transcribe(..., safeMode:)` is consistent from `MLRequest` → router → orchestrator → WhisperKit service.
- **Known async-signature shift:** `ParakeetTranscriptionService.isModelDownloaded()` becomes `async` (Task 9 Step 1 note) — the one call site must add `await`. Flagged explicitly rather than hidden.
- **Watch item for the implementer:** the synchronous `stateStream` capture via `UnsafeStreamBox`+semaphore (Tasks 8/9) is a pragmatic shim to satisfy the stored-`let` protocol requirement without touching `RecordingManager`; an `async` factory is the cleaner alternative if the team accepts wider churn.
