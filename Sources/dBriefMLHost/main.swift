import FluidAudio
import Foundation
import dBriefWire

// FluidAudio's debug/info lines can contain recognized transcript text; keep only
// warnings and errors. Set before any FluidAudio logger runs.
AppLogger.minimumLevel = .warning

// Parse --support-base <path> so the helper resolves the SAME model cache as the
// app (the helper's Bundle.main.bundleIdentifier differs from the app's).
let args = CommandLine.arguments
// The evaluation role runs before support-path checks, writers, diagnostics or
// ordinary backends. It cannot take a normal helper's model lifetime/mutex.
if args.contains("--nemotron-evaluate") {
    AppLogger.mirrorsToConsole = false
    let evaluationArgs = Array(args.dropFirst())
    if evaluationArgs.count == 2, Set(evaluationArgs) == ["--nemotron-evaluate", "--help"] {
        FileHandle.standardOutput.write(Data((NemotronEvaluationRunner.usage + "\n").utf8))
        exit(0)
    }
    let options: NemotronEvaluationOptions
    do { options = try NemotronEvaluationOptions.parse(evaluationArgs) }
    catch {
        FileHandle.standardError.write(Data("Nemotron evaluation: invalid arguments\n".utf8))
        exit(2)
    }
    do {
        let report = try await NemotronEvaluationRunner.run(options)
        FileHandle.standardError.write(Data("Nemotron evaluation: \(report.status)\n".utf8))
        exit(report.status == "completed" ? 0 : 1)
    } catch {
        // SDK/file errors may contain private paths or recognized content.
        FileHandle.standardError.write(Data("Nemotron evaluation: failed\n".utf8))
        exit(1)
    }
}
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
