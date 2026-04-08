import Foundation
import OSLog

enum YouTubeDownloadError: LocalizedError {
    case ytDlpNotFound
    case invalidURL
    case downloadFailed(String)
    case noAudioFileFound

    var errorDescription: String? {
        switch self {
        case .ytDlpNotFound:
            return "yt-dlp is not installed. Install it with: brew install yt-dlp"
        case .invalidURL:
            return "Please enter a valid URL."
        case .downloadFailed(let msg):
            return "Download failed: \(msg)"
        case .noAudioFileFound:
            return "No audio file was produced after download."
        }
    }
}

actor YouTubeDownloadService {
    private static let log = Logger.recording

    // MARK: - yt-dlp discovery

    /// Returns the path to the yt-dlp executable, or nil if not found.
    /// Marked nonisolated so it can be called synchronously from any context.
    nonisolated static func findYtDlp() -> String? {
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

    // MARK: - Public API

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
        let args: [String] = [
            "--no-playlist",
            "-f", "bestaudio[ext=m4a]/bestaudio/best",
            "--extract-audio",
            "--audio-format", "m4a",
            "--postprocessor-args", "ffmpeg:-ac 1 -ar 16000",
            "-o", outputTemplate,
            "--no-progress",
            trimmed,
        ]

        Self.log.info("Starting yt-dlp download: \(trimmed, privacy: .public)")

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

        Self.log.info("Download complete: \(audioFile.lastPathComponent, privacy: .public)")
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
