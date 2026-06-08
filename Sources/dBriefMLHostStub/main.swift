import Foundation
import dBriefWire

// Test-only helper that speaks the frame protocol with canned behavior.
// Behaviors via env: STUB_MODE = echo | crash-once | crash-always | error
let mode = ProcessInfo.processInfo.environment["STUB_MODE"] ?? "echo"
let out = FileHandle.standardOutput
func send(_ e: EventEnvelope) { if let d = try? JSONEncoder().encode(e) { out.write(FrameCodec.encode(d)) } }

let crashFlag = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stub_crashed")

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
        case "error":
            send(EventEnvelope(id: env.id, channel: .plugin,
                event: .error(WireError(kind: .insufficientMemory, message: "no ram", model: "L", requiredGB: "9.9"))))
        default: // echo: emit a state, then a result
            send(EventEnvelope(id: env.id, channel: .plugin, event: .state(.transcribing)))
            send(EventEnvelope(id: env.id, channel: .plugin,
                event: .transcriptionResult(TranscriptionResult(text: "echo"))))
            send(EventEnvelope(id: env.id, channel: .plugin, event: .finished))
        }
    }
}
