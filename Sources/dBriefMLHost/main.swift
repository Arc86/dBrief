import Foundation
import dBriefWire

// Parse --support-base <path> so the helper resolves the SAME model cache as the
// app (the helper's Bundle.main.bundleIdentifier differs from the app's).
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--support-base"), i + 1 < args.count {
    SupportPaths.localAIPluginBase = URL(fileURLWithPath: args[i + 1])
} else {
    FileHandle.standardError.write(Data("dBriefMLHost: missing --support-base\n".utf8))
    exit(2)
}

// One writer shared by request replies and broadcast state events, so frames
// never interleave on the output pipe.
let writer = StdoutWriter(.standardOutput)

// RequestRouter supplies request-correlated progress sinks during backend work.
// The sentinel is only for out-of-request lifecycle state (for example shutdown);
// processing consumers never attach these broadcasts to a recording.
let stateEventID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
let diagnostics = MLLifecycleDiagnostics(url: SupportPaths.localAIPluginBase
    .deletingLastPathComponent().appendingPathComponent("Diagnostics/ml-helper-events.jsonl"))
let orchestrator = MLOrchestrator(diagnostics: diagnostics) { channel, state in
    writer.send(EventEnvelope(id: stateEventID, channel: channel, event: .state(state)))
}

let loop = RequestLoop(backend: orchestrator, writer: writer, diagnostics: diagnostics)

// Cancel and drain work before releasing models on SIGTERM.
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler {
    Task { await loop.stop().value; exit(0) }
}
sigterm.resume()
signal(SIGTERM, SIG_IGN)

await loop.run(input: .standardInput)
// run() drains and releases models on stdin EOF.
