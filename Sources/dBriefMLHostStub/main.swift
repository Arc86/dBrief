import Foundation
import Darwin
import dBriefWire

// Test-only helper that speaks the frame protocol with canned behavior.
// Behaviors via env: STUB_MODE = echo | crash-once | crash-always | crash-second | error
//                              | closes-after-unload
//                              | finished-first | multi-frame
// Cross-restart flag files persist a stub's "have I crashed yet" state. Their
// paths come from env (STUB_FLAG_1 / STUB_FLAG_2) so concurrently-running tests
// each get an isolated flag and don't race over a shared file.
let env = ProcessInfo.processInfo.environment
let mode = env["STUB_MODE"] ?? "echo"
let out = FileHandle.standardOutput
func send(_ e: EventEnvelope) { if let d = try? JSONEncoder().encode(e) { out.write(FrameCodec.encode(d)) } }

func flag(_ key: String, default name: String) -> URL {
    if let path = env[key] { return URL(fileURLWithPath: path) }
    return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
}
let crashFlag = flag("STUB_FLAG_1", default: "stub_crashed")

// The retirement regression controls physical exit separately from SIGTERM
// and pipe EOF, so an obsolete wait cannot masquerade as a current receipt.
var retirementExit: URL?
if mode == "retirement-phases" {
    signal(SIGTERM,SIG_IGN)
    let counter = flag("STUB_FLAG_1",default: "stub_retirement_phase")
    let phase = (Int((try? String(contentsOf: counter,encoding: .utf8)) ?? "") ?? 0) + 1
    try? Data(String(phase).utf8).write(to: counter,options: .atomic)
    let exitFlag = URL(fileURLWithPath: flag("STUB_FLAG_2",default: "stub_retirement_exit").path + String(phase))
    retirementExit = exitFlag
    // Failed fixture control-file writes must not leave an immortal child.
    // The normal held-exit assertions finish well before this safety bound.
    let watchdog = Date().addingTimeInterval(30)
    Thread.detachNewThread {
        while !FileManager.default.fileExists(atPath: exitFlag.path), Date() < watchdog { Thread.sleep(forTimeInterval: 0.01) }
        exit(0)
    }
}

// closes-after-unload: like the real helper, `.forceUnload` drains and closes
// admission, but the process stays alive and rejects every later request.
var admissionClosed = false
var interleavedProgressRequests: [RequestEnvelope] = []
var previousProgressRequest: UUID?
var dispatchBatch: [RequestEnvelope] = []
var reader = FrameReader()
var liveStub = LiveHelperStub(mode: mode)
while true {
    let chunk = FileHandle.standardInput.availableData
    if chunk.isEmpty {
        if let retirementExit {
            while !FileManager.default.fileExists(atPath: retirementExit.path) { Thread.sleep(forTimeInterval: 0.01) }
        }
        break
    }
    reader.append(chunk)
    for frame in reader.drainFrames() {
        guard let env = try? JSONDecoder().decode(RequestEnvelope.self, from: frame) else { continue }
        if CommandLine.arguments.contains("--nemotron-live") || { if case .live = env.request { true } else { false } }() {
            liveStub.handle(env,send: send); continue
        }
        if mode == "closes-after-unload" {
            if admissionClosed {
                send(EventEnvelope(id: env.id, channel: .plugin,
                    event: .error(WireError(kind: .generic, message: "ML helper is shutting down"))))
                continue
            }
            if case .forceUnload = env.request {
                admissionClosed = true
                send(EventEnvelope(id: env.id, channel: .plugin, event: .voidResult))
                send(EventEnvelope(id: env.id, channel: .plugin, event: .finished))
                continue
            }
        }
        switch mode {
        case "dispatch-batch":
            if case .cancel = env.request { continue }
            let released = flag("STUB_FLAG_1",default: "stub_batch_released")
            if !FileManager.default.fileExists(atPath: released.path) {
                dispatchBatch.append(env)
                guard dispatchBatch.count == 128 else { continue }
                try? Data().write(to: flag("STUB_FLAG_2",default: "stub_batch_waiting"))
                let deadline = Date().addingTimeInterval(15)
                while !FileManager.default.fileExists(atPath: released.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                for request in dispatchBatch {
                    send(.init(id: request.id,channel: .plugin,event: .voidResult))
                    send(.init(id: request.id,channel: .plugin,event: .finished))
                }
                dispatchBatch.removeAll()
            } else {
                send(.init(id: env.id,channel: .plugin,event: .voidResult))
                send(.init(id: env.id,channel: .plugin,event: .finished))
            }
        case "interleaved-progress":
            if case .cancel = env.request { continue }
            interleavedProgressRequests.append(env)
            guard interleavedProgressRequests.count == 2 else { continue }
            for request in interleavedProgressRequests.reversed() {
                guard case .transcribe(let path, _, _, _, _) = request.request else { continue }
                send(.init(id: request.id, channel: .plugin,
                    event: .state(.newSegments([.init(start: 0, end: 1, text: path)]))))
            }
            for request in interleavedProgressRequests {
                send(.init(id: request.id, channel: .plugin, event: .transcriptionResult(.init(text: "synthetic"))))
                send(.init(id: request.id, channel: .plugin, event: .finished))
            }
            interleavedProgressRequests.removeAll()
        case "scoped-progress":
            if case .cancel = env.request { continue }
            if let previousProgressRequest {
                send(.init(id: previousProgressRequest, channel: .plugin,
                    event: .state(.newSegments([.init(start: 0, end: 1, text: "old")]))))
            }
            send(.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, channel: .plugin,
                event: .state(.newSegments([.init(start: 0, end: 1, text: "unattributed")]))))
            send(.init(id: env.id, channel: .plugin,
                event: .state(.newSegments([.init(start: 0, end: 1, text: "current")]))))
            if case .analyzeStream = env.request {
                send(.init(id: env.id, channel: .plugin, event: .token("synthetic token")))
            } else {
                send(.init(id: env.id, channel: .plugin, event: .transcriptionResult(.init(text: "synthetic result"))))
            }
            send(.init(id: env.id, channel: .plugin, event: .finished))
            send(.init(id: env.id, channel: .plugin,
                event: .state(.newSegments([.init(start: 0, end: 1, text: "after finish")]))))
            previousProgressRequest = env.id
        case "speech":
            if case let .synthesizeSpeech(_, outputPath, _, _, _, _, _) = env.request {
                send(EventEnvelope(id: env.id, channel: .plugin,
                    event: .speechResult(.init(outputPath: outputPath, durationSeconds: 1, sampleRate: 24000))))
            } else {
                send(EventEnvelope(id: env.id, channel: .plugin, event: .voidResult))
            }
            send(EventEnvelope(id: env.id, channel: .plugin, event: .finished))
        case "privacy-malformed":
            send(EventEnvelope(id: env.id, channel: .parakeet, event: .privacy(.supported(version: 1))))
            let broken = "{\"id\":\"\(env.id.uuidString)\",\"channel\":\"parakeet\",\"event\":{\"unknownPrivacyStage\":{}}}"
            out.write(FrameCodec.encode(Data(broken.utf8)))
            send(EventEnvelope(id: env.id, channel: .parakeet, event: .transcriptionResult(TranscriptionResult(text: "partial transcript"))))
            send(EventEnvelope(id: env.id, channel: .parakeet, event: .finished))
        case "privacy-failure":
            let attempt = UUID()
            send(EventEnvelope(id: env.id, channel: .parakeet, event: .privacy(.supported(version: 1))))
            send(EventEnvelope(id: env.id, channel: .parakeet, event: .privacy(.started(id: attempt, operation: .speakerDiarization))))
            send(EventEnvelope(id: env.id, channel: .parakeet, event: .privacy(.finished(id: attempt, outcome: .failed))))
            send(EventEnvelope(id: env.id, channel: .parakeet, event: .transcriptionResult(TranscriptionResult(text: "partial transcript"))))
            send(EventEnvelope(id: env.id, channel: .parakeet, event: .finished))
        case "crash-once":
            // Crash on the first transcribe; a relaunched process sees the flag and behaves.
            if case .transcribe = env.request, !FileManager.default.fileExists(atPath: crashFlag.path) {
                try? Data().write(to: crashFlag)
                exit(SIGKILL)   // simulate an uncatchable trap
            }
            send(EventEnvelope(id: env.id, channel: .plugin,
                event: .transcriptionResult(TranscriptionResult(text: "recovered"))))
            send(EventEnvelope(id: env.id, channel: .plugin, event: .finished))
        case "crash-always":
            if case .transcribe = env.request { exit(SIGKILL) }
            send(EventEnvelope(id: env.id, channel: .plugin, event: .voidResult))
            send(EventEnvelope(id: env.id, channel: .plugin, event: .finished))
        case "crash-second":
            // Reproduces the field scenario: the first transcribe succeeds, the
            // SECOND crashes once mid-stream, then recovers on the relaunched
            // process. A live-segment state frame is interleaved before each
            // result, mirroring WhisperKit's segmentDiscoveryCallback streaming.
            let firstDone = flag("STUB_FLAG_1", default: "stub_first_done")
            let crashed2 = flag("STUB_FLAG_2", default: "stub_crashed2")
            if case .transcribe = env.request {
                func emitSegments() {
                    send(EventEnvelope(id: env.id, channel: .plugin,
                        event: .state(.newSegments([LiveTranscriptSegment(start: 0, end: 1, text: "live")]))))
                }
                if !FileManager.default.fileExists(atPath: firstDone.path) {
                    try? Data().write(to: firstDone)            // op #1 — succeed
                    emitSegments()
                    send(EventEnvelope(id: env.id, channel: .plugin,
                        event: .transcriptionResult(TranscriptionResult(text: "echo"))))
                    send(EventEnvelope(id: env.id, channel: .plugin, event: .finished))
                } else if !FileManager.default.fileExists(atPath: crashed2.path) {
                    try? Data().write(to: crashed2)             // op #2 first attempt — crash mid-stream
                    emitSegments()
                    exit(SIGKILL)
                } else {                                         // op #2 retry — recover
                    emitSegments()
                    send(EventEnvelope(id: env.id, channel: .plugin,
                        event: .transcriptionResult(TranscriptionResult(text: "recovered"))))
                    send(EventEnvelope(id: env.id, channel: .plugin, event: .finished))
                }
            } else {
                send(EventEnvelope(id: env.id, channel: .plugin, event: .voidResult))
                send(EventEnvelope(id: env.id, channel: .plugin, event: .finished))
            }
        case "chat-across-live-stop":
            guard case .chatStream = env.request else {
                send(.init(id: env.id,channel: .plugin,event: .voidResult))
                send(.init(id: env.id,channel: .plugin,event: .finished))
                continue
            }
            send(.init(id: env.id,channel: .plugin,event: .token("Fixture started")))
            let completionFlag = flag("STUB_FLAG_1",default: "stub_chat_completion")
            let deadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: completionFlag.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            send(.init(id: env.id,channel: .plugin,event: .token("Fixture completed")))
            send(.init(id: env.id,channel: .plugin,event: .finished))
        case "error":
            send(EventEnvelope(id: env.id, channel: .plugin,
                event: .error(WireError(kind: .insufficientMemory, message: "no ram", model: "L", requiredGB: "9.9"))))
        case "finished-first":
            // Violates the ordering invariant: the terminal `.finished` overtakes
            // the result frame. The parent must fail loud, not hang.
            send(EventEnvelope(id: env.id, channel: .plugin, event: .finished))
            send(EventEnvelope(id: env.id, channel: .plugin,
                event: .transcriptionResult(TranscriptionResult(text: "too late"))))
        case "multi-frame":
            // Worst real reply shape (Parakeet + diarization): state frames
            // interleaved around the result, then the terminal `.finished`.
            send(EventEnvelope(id: env.id, channel: .plugin, event: .state(.transcribing)))
            send(EventEnvelope(id: env.id, channel: .plugin,
                event: .transcriptionResult(TranscriptionResult(text: "multi"))))
            send(EventEnvelope(id: env.id, channel: .plugin, event: .state(.diarizing)))
            send(EventEnvelope(id: env.id, channel: .plugin, event: .state(.diarizing)))
            send(EventEnvelope(id: env.id, channel: .plugin, event: .finished))
        default: // echo: emit a state, then a result
            send(EventEnvelope(id: env.id, channel: .plugin, event: .state(.transcribing)))
            send(EventEnvelope(id: env.id, channel: .plugin,
                event: .transcriptionResult(TranscriptionResult(text: "echo"))))
            send(EventEnvelope(id: env.id, channel: .plugin, event: .finished))
        }
    }
}
