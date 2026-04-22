import Foundation

struct RecordingFinalizationResult: Sendable {
    let masterAudioURL: URL
    let segmentAudioURLs: [URL]
    let metadataURL: URL
    let warnings: [String]
}

actor RecordingFinalizer {
    private let fileManager = FileManager.default

    func finalize(
        tracks: CapturedTracks,
        recording: Recording,
        baseFolder: URL,
        segmentationEnabled: Bool = true
    ) async throws -> RecordingFinalizationResult {
        let snapshot = await MainActor.run { Snapshot(recording: recording) }
        let normalizedTitle = Self.normalizeMeetingTitle(snapshot.meetingTitle, fallback: snapshot.associatedApp)
        let targetFolder = try Self.datedFolder(baseFolder: baseFolder, date: snapshot.date, fileManager: fileManager)
        let baseName = Self.baseFileName(date: snapshot.date, title: normalizedTitle)
        let masterURL = try Self.uniqueFileURL(
            folder: targetFolder,
            baseName: baseName,
            fileExtension: "m4a",
            fileManager: fileManager
        )

        var warnings: [String] = []
        let ffmpegPath = resolveFFmpegPath()

        if let ffmpegPath {
            do {
                try transcodeWithFFmpeg(
                    ffmpegPath: ffmpegPath,
                    tracks: tracks,
                    outputURL: masterURL,
                    snapshot: snapshot
                )
                if let url = tracks.systemURL, fileManager.fileExists(atPath: url.path) {
                    try? fileManager.removeItem(at: url)
                }
                if let url = tracks.micURL, fileManager.fileExists(atPath: url.path) {
                    try? fileManager.removeItem(at: url)
                }
            } catch {
                warnings.append("ffmpeg merge failed; keeping raw CAF(s). \(error.localizedDescription)")
                try fallbackPromoteTrack(tracks: tracks, targetURL: masterURL)
            }
        } else {
            warnings.append("ffmpeg not found. Skipped merge and AAC encode; master is raw CAF.")
            try fallbackPromoteTrack(tracks: tracks, targetURL: masterURL)
        }

        var segmentURLs: [URL] = []
        if segmentationEnabled && snapshot.duration > 1800 {
            if let ffmpegPath, fileManager.fileExists(atPath: masterURL.path) {
                do {
                    segmentURLs = try createSegments(
                        ffmpegPath: ffmpegPath,
                        masterURL: masterURL
                    )
                    if segmentURLs.isEmpty {
                        warnings.append("Segmentation produced no output files.")
                    }
                } catch {
                    warnings.append("Segmentation failed. \(error.localizedDescription)")
                }
            } else {
                warnings.append("Segmentation skipped because ffmpeg is unavailable.")
            }
        }

        let metadataPayload = RecordingMetadataPayload(
            dateISO8601: ISO8601DateFormatter().string(from: snapshot.date),
            durationSeconds: snapshot.duration,
            meetingTitle: normalizedTitle,
            masterFileName: masterURL.lastPathComponent,
            segmentFileNames: segmentURLs.map(\.lastPathComponent),
            warnings: warnings
        )
        let metadataURL = masterURL.deletingPathExtension().appendingPathExtension("json")
        try writeMetadata(metadataPayload, to: metadataURL)

        return RecordingFinalizationResult(
            masterAudioURL: masterURL,
            segmentAudioURLs: segmentURLs,
            metadataURL: metadataURL,
            warnings: warnings
        )
    }

    private func transcodeWithFFmpeg(
        ffmpegPath: String,
        tracks: CapturedTracks,
        outputURL: URL,
        snapshot: Snapshot
    ) throws {
        let isoDate = ISO8601DateFormatter().string(from: snapshot.date)
        let title = Self.normalizeMeetingTitle(snapshot.meetingTitle, fallback: snapshot.associatedApp)
        let durationMeta = "duration_seconds=\(Int(snapshot.duration))"

        let args: [String]
        switch (tracks.systemURL, tracks.micURL) {
        case (let system?, let mic?):
            args = [
                "-y",
                "-i", system.path,
                "-i", mic.path,
                "-filter_complex",
                "[0:a]highpass=f=40,lowpass=f=12000[sys];"
                    + "[1:a]highpass=f=80,loudnorm=I=-16:TP=-1.5:LRA=11[mic];"
                    + "[sys][mic]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0[out]",
                "-map", "[out]",
                "-c:a", "aac", "-b:a", "96k",
                "-ar", "48000", "-ac", "2",
                "-movflags", "+faststart",
                "-metadata", "date=\(isoDate)",
                "-metadata", "title=\(title)",
                "-metadata", durationMeta,
                outputURL.path,
            ]
        case (nil, let mic?):
            args = [
                "-y",
                "-i", mic.path,
                "-af", "highpass=f=80,loudnorm=I=-16:TP=-1.5:LRA=11",
                "-c:a", "aac", "-b:a", "64k",
                "-ar", "48000", "-ac", "1",
                "-movflags", "+faststart",
                "-metadata", "date=\(isoDate)",
                "-metadata", "title=\(title)",
                "-metadata", durationMeta,
                outputURL.path,
            ]
        case (let system?, nil):
            args = [
                "-y",
                "-i", system.path,
                "-af", "highpass=f=40,lowpass=f=12000",
                "-c:a", "aac", "-b:a", "96k",
                "-ar", "48000", "-ac", "2",
                "-movflags", "+faststart",
                "-metadata", "date=\(isoDate)",
                "-metadata", "title=\(title)",
                "-metadata", durationMeta,
                outputURL.path,
            ]
        case (nil, nil):
            throw RecordingFinalizerError.ffmpegFailed("No input tracks to finalize.")
        }

        let result = runFFmpeg(ffmpegPath: ffmpegPath, arguments: args)
        guard result.status == 0 else {
            throw RecordingFinalizerError.ffmpegFailed(result.stderr)
        }
    }

    private func createSegments(ffmpegPath: String, masterURL: URL) throws -> [URL] {
        let stem = masterURL.deletingPathExtension().lastPathComponent
        let folder = masterURL.deletingLastPathComponent()
        let pattern = folder.appendingPathComponent("\(stem)_part%02d.m4a")

        let processResult = runFFmpeg(
            ffmpegPath: ffmpegPath,
            arguments: [
                "-y",
                "-i", masterURL.path,
                "-f", "segment",
                "-segment_time", "1800",
                "-segment_start_number", "1",
                "-c", "copy",
                "-reset_timestamps", "1",
                pattern.path,
            ]
        )

        guard processResult.status == 0 else {
            throw RecordingFinalizerError.ffmpegFailed(processResult.stderr)
        }

        let entries = (try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return entries
            .filter {
                $0.pathExtension.lowercased() == "m4a"
                    && $0.deletingPathExtension().lastPathComponent.hasPrefix("\(stem)_part")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func fallbackPromoteTrack(tracks: CapturedTracks, targetURL: URL) throws {
        let source: URL
        if let mic = tracks.micURL, fileManager.fileExists(atPath: mic.path) {
            source = mic
        } else if let system = tracks.systemURL, fileManager.fileExists(atPath: system.path) {
            source = system
        } else {
            throw RecordingFinalizerError.ffmpegFailed("No usable track for fallback.")
        }
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        do {
            try fileManager.moveItem(at: source, to: targetURL)
        } catch {
            try fileManager.copyItem(at: source, to: targetURL)
        }
    }

    private func resolveFFmpegPath() -> String? {
        let knownPaths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        for path in knownPaths where fileManager.isExecutableFile(atPath: path) {
            return path
        }

        let envProbe = runProcess(executable: "/usr/bin/env", arguments: ["ffmpeg", "-version"])
        if envProbe.status == 0 {
            return "/usr/bin/env"
        }

        let whichProbe = runProcess(executable: "/usr/bin/which", arguments: ["ffmpeg"])
        guard whichProbe.status == 0 else { return nil }
        let trimmed = whichProbe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, fileManager.isExecutableFile(atPath: trimmed) else { return nil }
        return trimmed
    }

    private func runFFmpeg(ffmpegPath: String, arguments: [String]) -> ProcessResult {
        if ffmpegPath == "/usr/bin/env" {
            return runProcess(
                executable: ffmpegPath,
                arguments: ["ffmpeg"] + arguments
            )
        }
        return runProcess(executable: ffmpegPath, arguments: arguments)
    }

    private func runProcess(executable: String, arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProcessResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(
            status: Int(process.terminationStatus),
            stdout: stdout,
            stderr: stderr
        )
    }

    private func writeMetadata(_ payload: RecordingMetadataPayload, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: url, options: .atomic)
    }
}

enum RecordingFinalizerError: Error, LocalizedError {
    case ffmpegFailed(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegFailed(let stderr):
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                return "ffmpeg command failed."
            }
            return "ffmpeg command failed: \(message)"
        }
    }
}

struct RecordingMetadataPayload: Codable, Equatable, Sendable {
    let dateISO8601: String
    let durationSeconds: TimeInterval
    let meetingTitle: String
    let masterFileName: String
    let segmentFileNames: [String]
    let warnings: [String]
}

private struct ProcessResult: Sendable {
    let status: Int
    let stdout: String
    let stderr: String
}

private struct Snapshot: Sendable {
    let date: Date
    let duration: TimeInterval
    let meetingTitle: String
    let associatedApp: String?

    @MainActor
    init(recording: Recording) {
        self.date = recording.date
        self.duration = recording.duration
        self.meetingTitle = recording.meetingTitleDraft
        self.associatedApp = recording.associatedApp
    }
}

extension RecordingFinalizer {
    static func normalizeMeetingTitle(_ value: String, fallback associatedApp: String?) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackValue = (associatedApp ?? "meeting").trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? (fallbackValue.isEmpty ? "meeting" : fallbackValue) : trimmed

        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let collapsed = source
            .components(separatedBy: invalid)
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.isEmpty { return "meeting" }
        return collapsed.replacingOccurrences(of: " ", with: "-")
    }

    static func datedFolder(baseFolder: URL, date: Date, fileManager: FileManager = .default) throws -> URL {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let folder = baseFolder
            .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func baseFileName(date: Date, title: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return "\(formatter.string(from: date))_\(normalizeMeetingTitle(title, fallback: nil))"
    }

    static func uniqueFileURL(
        folder: URL,
        baseName: String,
        fileExtension: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName)_\(index)").appendingPathExtension(fileExtension)
            index += 1
        }
        return candidate
    }
}
