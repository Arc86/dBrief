import Foundation
import dBriefWire

// Test-only helper that speaks the frame protocol with canned behavior.
// Behaviors via env: STUB_MODE = echo | crash-once | crash-always | crash-second | error
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

var reader = FrameReader()
while true {
    let chunk = FileHandle.standardInput.availableData
    if chunk.isEmpty { break }
    reader.append(chunk)
    for frame in reader.drainFrames() {
        guard let env = try? JSONDecoder().decode(RequestEnvelope.self, from: frame) else { continue }
        switch mode {
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
