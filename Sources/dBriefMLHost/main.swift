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
let orchestrator = MLOrchestrator { channel, state in
    writer.send(EventEnvelope(id: stateEventID, channel: channel, event: .state(state)))
}

// Free Metal/GPU buffers before exit on SIGTERM (parent quitting).
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler {
    Task { await orchestrator.forceUnload(); exit(0) }
}
sigterm.resume()
signal(SIGTERM, SIG_IGN)

let loop = RequestLoop(backend: orchestrator, writer: writer)
await loop.run(input: .standardInput)
// stdin EOF => parent gone; release resources and exit.
await orchestrator.forceUnload()
