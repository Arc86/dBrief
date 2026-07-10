import Foundation

struct RecordingFinalizationResult: Sendable {
    let masterAudioURL: URL
    let segmentAudioURLs: [URL]
    let metadataURL: URL
    let warnings: [String]
}

/// Classifies a finalization warning string into a benign, informational note
/// versus a genuine problem. A "track missing or empty" note is expected and
/// harmless — e.g. a listen-only meeting where the mic captured nothing — so the
/// UI shows it informationally rather than as a red error step, while real
/// problems (ffmpeg missing, merge/segmentation failures) stay surfaced as errors.
enum FinalizationWarning {
    /// Substring stamped into the benign "one source was silent/absent, the
    /// recording still succeeded from the other track" warnings. Shared with the
    /// message construction below so the two can never drift apart.
    static let emptyTrackMarker = "track missing or empty"

    static func isInformational(_ warning: String) -> Bool {
        warning.contains(emptyTrackMarker)
    }
}

actor RecordingFinalizer {
    private let fileManager = FileManager.default

    func finalize(
        tracks: CapturedTracks,
        recording: Recording,
        baseFolder: URL,
        segmentationEnabled: Bool = true,
        echoSuppressionEnabled: Bool = true,
        onProgress: (@Sendable (Double) -> Void)? = nil
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
        let ffmpegPath = FFmpegLocator.resolve()

        if let ffmpegPath {
            // Only pass tracks that actually exist and have audio data.
            // In mic-only mode the system CAF is never written; guard against
            // handing ffmpeg a missing file.
            let usableTracks = CapturedTracks(
                systemURL: tracks.systemURL.flatMap { hasAudioContent($0) ? $0 : nil },
                micURL:    tracks.micURL.flatMap    { hasAudioContent($0) ? $0 : nil }
            )
            if usableTracks.systemURL == nil, let url = tracks.systemURL {
                warnings.append("System audio \(FinalizationWarning.emptyTrackMarker) (\(url.lastPathComponent)); using mic-only output.")
            }
            if usableTracks.micURL == nil, let url = tracks.micURL {
                warnings.append("Mic \(FinalizationWarning.emptyTrackMarker) (\(url.lastPathComponent)).")
            }
            do {
                try transcodeWithFFmpeg(
                    ffmpegPath: ffmpegPath,
                    tracks: usableTracks,
                    outputURL: masterURL,
                    snapshot: snapshot,
                    echoSuppressionEnabled: echoSuppressionEnabled,
                    onProgress: onProgress
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

    /// Relocate an already-encoded audio file (e.g. a YouTube/yt-dlp download) into
    /// the dated recordings folder so it becomes discoverable by history and the
    /// transcript viewer. Unlike `finalize`, this performs no DSP or AAC re-encode —
    /// the source is assumed to already be a finished audio file.
    func importExistingAudio(
        sourceURL: URL,
        recording: Recording,
        baseFolder: URL,
        segmentationEnabled: Bool = true
    ) async throws -> RecordingFinalizationResult {
        let snapshot = await MainActor.run { Snapshot(recording: recording) }
        let normalizedTitle = Self.normalizeMeetingTitle(snapshot.meetingTitle, fallback: snapshot.associatedApp)
        let targetFolder = try Self.datedFolder(baseFolder: baseFolder, date: snapshot.date, fileManager: fileManager)
        let baseName = Self.baseFileName(date: snapshot.date, title: normalizedTitle)
        let fileExtension = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let masterURL = try Self.uniqueFileURL(
            folder: targetFolder,
            baseName: baseName,
            fileExtension: fileExtension,
            fileManager: fileManager
        )

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw RecordingFinalizerError.ffmpegFailed("Imported audio file is missing: \(sourceURL.lastPathComponent)")
        }
        do {
            try fileManager.moveItem(at: sourceURL, to: masterURL)
        } catch {
            // Cross-volume move fails (e.g. temp on a different volume than the
            // recordings folder); fall back to copy, then remove the temp source so
            // imported temp files (YouTube downloads, watched-folder copies) don't leak.
            try fileManager.copyItem(at: sourceURL, to: masterURL)
            try? fileManager.removeItem(at: sourceURL)
        }

        var warnings: [String] = []
        var segmentURLs: [URL] = []
        if segmentationEnabled && snapshot.duration > 1800 {
            if let ffmpegPath = FFmpegLocator.resolve() {
                do {
                    segmentURLs = try createSegments(ffmpegPath: ffmpegPath, masterURL: masterURL)
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
        snapshot: Snapshot,
        echoSuppressionEnabled: Bool,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        let isoDate = ISO8601DateFormatter().string(from: snapshot.date)
        let title = Self.normalizeMeetingTitle(snapshot.meetingTitle, fallback: snapshot.associatedApp)
        let durationMeta = "duration_seconds=\(Int(snapshot.duration))"

        let args: [String]
        switch (tracks.systemURL, tracks.micURL) {
        case (let system?, let mic?):
            // When both tracks are present, the system track is the exact
            // audio being played through the speakers, which is the same
            // signal the built-in mic is leaking back as echo. We use it as
            // a sidechain detector on a compressor/gate so the mic is
            // aggressively ducked whenever system audio is active — removing
            // the speaker bleed without needing precise time alignment.
            //
            // threshold=0.03  → any system audio above ~-30dBFS triggers ducking
            // ratio=20        → near-gate attenuation of the mic during speaker playback
            // attack=5        → catch the leading edge of speaker audio quickly
            // release=250     → hold the duck through brief gaps so reverb tails don't bleed through
            // level_sc=2      → boost detector sensitivity (~+6dB) so soft remote speech still triggers
            let filterGraph: String
            if echoSuppressionEnabled {
                // Split the system track: one copy for the final mix, one as
                // the sidechain reference used to duck the mic during speaker
                // playback.
                filterGraph = "[0:a]asplit=2[sys0][scref];"
                    + "[sys0]highpass=f=40,lowpass=f=12000[sys];"
                    + "[scref]aformat=channel_layouts=mono[scmono];"
                    + "[1:a]highpass=f=80[michp];"
                    + "[michp][scmono]sidechaincompress=threshold=0.03:ratio=20:attack=5:release=250:level_sc=2:makeup=1:mode=downward[micducked];"
                    + "[micducked]loudnorm=I=-16:TP=-1.5:LRA=11[mic];"
                    + "[sys][mic]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0[out]"
            } else {
                filterGraph = "[0:a]highpass=f=40,lowpass=f=12000[sys];"
                    + "[1:a]highpass=f=80,loudnorm=I=-16:TP=-1.5:LRA=11[mic];"
                    + "[sys][mic]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0[out]"
            }
            args = [
                "-y",
                "-i", system.path,
                "-i", mic.path,
                "-filter_complex",
                filterGraph,
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

        // Stream ffmpeg's -progress output into a determinate progress fraction when
        // we know the target duration and a caller wants updates. The merge/encode is
        // single-pass, so out_time advances monotonically to the recording length.
        let progress: FFmpegProgress? = onProgress.flatMap { handler in
            snapshot.duration > 0 ? FFmpegProgress(duration: snapshot.duration, handler: handler) : nil
        }
        let result = runFFmpeg(ffmpegPath: ffmpegPath, arguments: args, progress: progress)
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

    private func hasAudioContent(_ url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[FileAttributeKey.size] as? Int64 else { return false }
        return size > 4096  // a valid CAF header + at least one audio packet
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

    private func runFFmpeg(
        ffmpegPath: String,
        arguments: [String],
        progress: FFmpegProgress? = nil
    ) -> ProcessResult {
        if ffmpegPath == "/usr/bin/env" {
            return runProcess(
                executable: ffmpegPath,
                arguments: ["ffmpeg"] + arguments,
                progress: progress
            )
        }
        return runProcess(executable: ffmpegPath, arguments: arguments, progress: progress)
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        progress: FFmpegProgress? = nil
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // When a caller wants progress, ask ffmpeg to emit machine-readable key/value
        // progress on stdout and silence the stderr stats spam. Prepended so it applies
        // before the output file argument.
        process.arguments = progress == nil ? arguments : ["-progress", "pipe:1", "-nostats"] + arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Parse -progress output live off stdout as it streams. The readability handler
        // runs on a background queue while waitUntilExit() blocks this thread, so it
        // updates the fraction without waiting for the encode to finish.
        if let progress, progress.duration > 0 {
            let duration = progress.duration
            let handler = progress.handler
            let buffer = ProgressLineBuffer()
            stdoutPipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty else { return }
                for line in buffer.append(data) {
                    if let seconds = RecordingFinalizer.parseFFmpegProgressSeconds(from: line) {
                        handler(min(0.99, max(0, seconds / duration)))
                    }
                }
            }
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            return ProcessResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        // Detach the live reader before draining the remaining pipe data.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        let stdout = progress == nil
            ? (String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            : ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(
            status: Int(process.terminationStatus),
            stdout: stdout,
            stderr: stderr
        )
    }

    /// Duration + handler bundle for streaming ffmpeg `-progress` into a 0…1 fraction.
    private struct FFmpegProgress {
        let duration: TimeInterval
        let handler: @Sendable (Double) -> Void
    }

    /// Parse the seconds elapsed from one ffmpeg `-progress` output line. Prefers the
    /// unambiguous microsecond field, falling back to the `HH:MM:SS.ffffff` timecode.
    /// Returns `nil` for non-time lines and `N/A` placeholders. Pure — unit-tested.
    static func parseFFmpegProgressSeconds(from line: String) -> Double? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let range = trimmed.range(of: "out_time_us=") {
            if let us = Double(trimmed[range.upperBound...]), us >= 0 { return us / 1_000_000 }
            return nil
        }
        if let range = trimmed.range(of: "out_time=") {
            return parseTimecodeSeconds(String(trimmed[range.upperBound...]))
        }
        return nil
    }

    /// Parse an `HH:MM:SS.ffffff` timecode into seconds. Pure — unit-tested.
    static func parseTimecodeSeconds(_ timecode: String) -> Double? {
        let parts = timecode.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2])
        else { return nil }
        return h * 3600 + m * 60 + s
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
    /// The AI-generated meeting title, written back into the sidecar after
    /// post-processing (the audio file itself is never renamed). `nil` until AI
    /// title generation runs, and absent in sidecars written before this field
    /// existed — so the transcript browser can prefer it when present and fall
    /// back to the (draft) filename otherwise. See #71.
    var generatedTitle: String? = nil
}

private struct ProcessResult: Sendable {
    let status: Int
    let stdout: String
    let stderr: String
}

/// Accumulates streamed ffmpeg `-progress` bytes and yields complete lines. Only ever
/// touched from a single `FileHandle` readability queue, so the mutable state is safe
/// despite `@unchecked Sendable`.
private final class ProgressLineBuffer: @unchecked Sendable {
    private var partial = ""

    func append(_ data: Data) -> [String] {
        partial += String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        while let newline = partial.firstIndex(of: "\n") {
            lines.append(String(partial[..<newline]))
            partial = String(partial[partial.index(after: newline)...])
        }
        return lines
    }
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
