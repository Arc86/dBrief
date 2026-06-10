import Foundation
import OSLog

enum YouTubeDownloadError: LocalizedError {
    case ytDlpNotFound
    case invalidURL
    case downloadFailed(String)
    case noAudioFileFound
    case ytDlpBinaryDownloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .ytDlpNotFound:
            return "yt-dlp not found. Use the \"Download yt-dlp\" button below."
        case .invalidURL:
            return "Please enter a valid URL."
        case .downloadFailed(let msg):
            return "Download failed: \(msg)"
        case .noAudioFileFound:
            return "No audio file was produced after download."
        case .ytDlpBinaryDownloadFailed(let msg):
            return "Could not download yt-dlp: \(msg)"
        }
    }
}

actor YouTubeDownloadService {
    private static let log = Logger.recording

    // MARK: - yt-dlp discovery

    /// Path where the app stores a self-downloaded yt-dlp binary.
    nonisolated static func appSupportYtDlpURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("com.dbrief.app/LocalAIPlugin/ytdlp/yt-dlp")
    }

    /// Returns the path to a usable yt-dlp executable, or nil if not found.
    /// Checks the in-app AppSupport location first, then standard Homebrew / system paths.
    /// Marked nonisolated so it can be called synchronously from any context.
    nonisolated static func findYtDlp() -> String? {
        // Prefer a previously downloaded copy in app support
        let appSupportPath = appSupportYtDlpURL().path
        if FileManager.default.isExecutableFile(atPath: appSupportPath) {
            return appSupportPath
        }

        let candidates = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fallback: ask the shell
        if let path = runBlocking("/usr/bin/which", args: ["yt-dlp"]), !path.isEmpty {
            return path
        }
        return nil
    }

    // MARK: - yt-dlp binary auto-download

    /// Downloads the yt-dlp universal macOS binary from GitHub releases into the
    /// app's Application Support directory and makes it executable.
    ///
    /// Yields progress values (0.0 – 1.0) as it downloads, then finishes.
    /// Call `findYtDlp()` afterwards to get the installed path.
    nonisolated static func downloadYtDlp() -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let destURL = appSupportYtDlpURL()
                    let destDir = destURL.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

                    // Universal macOS binary from yt-dlp's GitHub releases
                    // (GitHub redirects /latest/download/ to the actual versioned asset)
                    let downloadURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
                    Logger.recording.info("Downloading yt-dlp binary from GitHub…")

                    let (asyncBytes, response) = try await URLSession.shared.bytes(from: downloadURL)
                    let totalBytes = (response as? HTTPURLResponse)?.expectedContentLength ?? -1

                    // Stream bytes to a temp file in 64 KB chunks to avoid
                    // holding the whole binary in memory.
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("yt-dlp-\(UUID().uuidString)")
                    FileManager.default.createFile(atPath: tempURL.path, contents: nil)
                    let fileHandle = try FileHandle(forWritingTo: tempURL)

                    var receivedBytes: Int64 = 0
                    var chunk = Data()
                    chunk.reserveCapacity(65_536)

                    for try await byte in asyncBytes {
                        chunk.append(byte)
                        receivedBytes += 1
                        if chunk.count >= 65_536 {
                            try fileHandle.write(contentsOf: chunk)
                            chunk.removeAll(keepingCapacity: true)
                            if totalBytes > 0 {
                                continuation.yield(Double(receivedBytes) / Double(totalBytes))
                            }
                        }
                    }
                    if !chunk.isEmpty {
                        try fileHandle.write(contentsOf: chunk)
                    }
                    try fileHandle.close()

                    // Replace any existing copy and move into place
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        try FileManager.default.removeItem(at: destURL)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destURL)

                    // Make executable (rwxr-xr-x)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o755],
                        ofItemAtPath: destURL.path
                    )

                    // Remove quarantine flag so macOS doesn't block execution.
                    // yt-dlp's macOS builds are signed; this is a precaution only.
                    let xattr = Process()
                    xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                    xattr.arguments = ["-d", "com.apple.quarantine", destURL.path]
                    xattr.standardOutput = Pipe()
                    xattr.standardError = Pipe()
                    try? xattr.run()
                    xattr.waitUntilExit()

                    Logger.recording.info("yt-dlp installed at \(destURL.path, privacy: .public)")
                    continuation.yield(1.0)
                    continuation.finish()
                } catch {
                    Logger.recording.error("yt-dlp binary download error: \(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: YouTubeDownloadError.ytDlpBinaryDownloadFailed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - YouTube audio download

    /// Download the best-quality audio track from the given URL.
    /// Returns the local file URL and the video title extracted by yt-dlp.
    /// Blocks the actor thread for the duration of the download (mirrors the
    /// existing pattern used by RecordingFinalizer / LocalTranscriptionService).
    func downloadAudio(from urlString: String) throws -> (audioURL: URL, title: String) {
        guard let ytdlp = Self.findYtDlp() else {
            throw YouTubeDownloadError.ytDlpNotFound
        }

        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else {
            throw YouTubeDownloadError.invalidURL
        }

        // Scratch directory for this download
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dBrief_YT_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Fetch title first (quick)
        let title = Self.runBlocking(ytdlp, args: ["--get-title", "--no-playlist", trimmed])
            .flatMap { $0.isEmpty ? nil : $0 } ?? "youtube-video"

        // Download best audio and re-encode to m4a 16 kHz mono via ffmpeg post-processor
        let outputTemplate = tempDir.appendingPathComponent("audio.%(ext)s").path
        var args: [String] = [
            "--no-playlist",
            "-f", "bestaudio[ext=m4a]/bestaudio/best",
            "--extract-audio",
            "--audio-format", "m4a",
            "--postprocessor-args", "ffmpeg:-ac 1 -ar 16000",
            "-o", outputTemplate,
            "--no-progress",
        ]

        // Point yt-dlp at the bundled (or system) ffmpeg so post-processing works on
        // machines without Homebrew. Skip the `/usr/bin/env` sentinel — yt-dlp wants a
        // directory or binary path, not the env shim.
        if let ffmpeg = FFmpegLocator.resolve(), ffmpeg != "/usr/bin/env" {
            args.append(contentsOf: ["--ffmpeg-location", ffmpeg])
        }

        args.append(trimmed)

        Self.log.info("Starting yt-dlp audio download: \(trimmed, privacy: .public)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlp)
        process.arguments = args
        process.currentDirectoryURL = tempDir

        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw YouTubeDownloadError.downloadFailed(error.localizedDescription)
        }

        if process.terminationStatus != 0 {
            let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(process.terminationStatus)"
            Self.log.error("yt-dlp failed: \(msg, privacy: .public)")
            throw YouTubeDownloadError.downloadFailed(msg)
        }

        let audioExtensions: Set<String> = ["m4a", "mp3", "ogg", "opus", "flac", "webm", "aac", "wav"]
        let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        guard let audioFile = files.first(where: { audioExtensions.contains($0.pathExtension.lowercased()) }) else {
            throw YouTubeDownloadError.noAudioFileFound
        }

        Self.log.info("Audio download complete: \(audioFile.lastPathComponent, privacy: .public)")
        return (audioFile, title)
    }

    // MARK: - Private helpers

    nonisolated private static func runBlocking(_ executable: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
