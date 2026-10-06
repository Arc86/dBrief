import FluidAudio
import Foundation
import dBriefWire

// FluidAudio's debug/info lines can contain recognized transcript text; keep only
// warnings and errors. Set before any FluidAudio logger runs.
AppLogger.minimumLevel = .warning

// Parse --support-base <path> so the helper resolves the SAME model cache as the
// app (the helper's Bundle.main.bundleIdentifier differs from the app's).
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--support-base"), i + 1 < args.count {
    SupportPaths.localAIPluginBase = URL(fileURLWithPath: args[i + 1])
} else {
    FileHandle.standardError.write(Data("dBriefMLHost: missing --support-base\n".utf8))
    exit(2)
}

// Reserve the real stdout for protocol frames (or the eval report) and send anything
// else written to fd 1 to stderr. Libraries (e.g. mlx-swift-lm's TurboQuant warning)
// print() to stdout; stray bytes there would corrupt the length-prefixed frame pipe
// and hang the app. Must happen before any model or library use.
let protocolFD = dup(STDOUT_FILENO)
if protocolFD == -1 || dup2(STDERR_FILENO, STDOUT_FILENO) == -1 {
    FileHandle.standardError.write(Data("dBriefMLHost: cannot reserve stdout for protocol\n".utf8))
    exit(2)
}
let protocolOutput = FileHandle(fileDescriptor: protocolFD, closeOnDealloc: false)

if args.contains("--eval-insights") {
    exit(await GemmaEval.run(arguments: args, output: protocolOutput))
}

// One writer shared by request replies and broadcast state events, so frames
// never interleave on the output pipe.
let writer = StdoutWriter(protocolOutput)

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
