import Foundation

/// Resolves the path to an `ffmpeg` executable, preferring the copy bundled inside
/// `dBrief.app` so DMG users get full audio processing without installing Homebrew.
///
/// Search order:
/// 1. The bundled binary at `Contents/MacOS/ffmpeg` (present in release `.app`
///    bundles; absent during `swift run`/dev, where we fall through to the system).
/// 2. Standard Homebrew / system install paths.
/// 3. `/usr/bin/env ffmpeg` (PATH lookup) — returned as the `/usr/bin/env` sentinel.
/// 4. `/usr/bin/which ffmpeg`.
///
/// The `/usr/bin/env` sentinel is part of the contract: callers that get it back must
/// invoke it as `env` with `["ffmpeg"] + args` (see `RecordingFinalizer.runFFmpeg`).
enum FFmpegLocator {
    /// Returns a usable ffmpeg executable path (or the `/usr/bin/env` sentinel), or
    /// `nil` if ffmpeg cannot be found anywhere.
    ///
    /// `nonisolated static` so it can be called synchronously from any isolation
    /// context (actors, the audio pipeline, UI).
    nonisolated static func resolve() -> String? {
        let fileManager = FileManager.default

        // 1. Bundled binary, beside the app's own executable (Contents/MacOS/ffmpeg).
        if let bundled = bundledFFmpegURL(), fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }

        // 2. Homebrew / system install paths.
        let knownPaths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        for path in knownPaths where fileManager.isExecutableFile(atPath: path) {
            return path
        }

        // 3. PATH lookup via env.
        if runProbe(executable: "/usr/bin/env", arguments: ["ffmpeg", "-version"]) {
            return "/usr/bin/env"
        }

        // 4. `which ffmpeg`.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ffmpeg"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let trimmed = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, fileManager.isExecutableFile(atPath: trimmed) else { return nil }
        return trimmed
    }

    /// The expected location of the bundled binary, beside the running executable.
    /// Returns `nil` when there is no main-bundle executable (should not happen for the app).
    nonisolated static func bundledFFmpegURL() -> URL? {
        Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("ffmpeg")
    }

    /// Runs a process purely to check it succeeds (exit status 0), discarding output.
    nonisolated private static func runProbe(executable: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
