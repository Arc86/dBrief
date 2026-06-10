import Foundation

/// Converts `.ogg`/`.opus` audio to 16 kHz mono WAV via ffmpeg so Apple's speech
/// engines (which can't read Ogg/Opus) can transcribe it. Other formats pass through
/// unchanged. Shared by `LocalTranscriptionService` (SFSpeechRecognizer) and
/// `AppleSpeechAnalyzerService` (SpeechAnalyzer).
enum OggOpusConverter {
    /// Returns a URL suitable for Apple speech transcription. For `.ogg`/`.opus`
    /// inputs this is a freshly written temp WAV; for everything else it's `fileURL`.
    static func preparedURL(for fileURL: URL) throws -> URL {
        let ext = fileURL.pathExtension.lowercased()
        guard ext == "ogg" || ext == "opus" else {
            return fileURL
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("debrief-transcription-\(UUID().uuidString).wav")

        // Prefer the bundled binary (Contents/MacOS/ffmpeg), then Homebrew/system paths.
        let resolvedPath = FFmpegLocator.resolve()
        let process = Process()
        let conversionArgs = [
            "-y",
            "-i", fileURL.path,
            "-ac", "1",
            "-ar", "16000",
            "-f", "wav",
            outputURL.path,
        ]
        if let resolvedPath, resolvedPath != "/usr/bin/env" {
            process.executableURL = URL(fileURLWithPath: resolvedPath)
            process.arguments = conversionArgs
        } else {
            // Not found directly, or resolver returned the env sentinel: invoke via env
            // with an explicit PATH so PATH-installed ffmpeg still resolves.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["ffmpeg"] + conversionArgs
            process.environment = [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            ]
        }

        let stdErr = Pipe()
        process.standardError = stdErr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw LocalTranscriptionError.ffmpegNotFound
        }

        guard process.terminationStatus == 0 else {
            let data = stdErr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "ffmpeg failed"
            throw LocalTranscriptionError.conversionFailed(message)
        }

        return outputURL
    }
}
