import Foundation

struct RecordingFinalizationResult: Sendable {
    let masterAudioURL: URL
    let segmentAudioURLs: [URL]
    let metadataURL: URL
    let warnings: [String]
    let ffmpegDiagnostics: FFmpegRunDiagnostics?
}

struct FFmpegRunDiagnostics: Sendable {
    let exitStatus: Int32
    let stdoutByteCount: Int64
    let stderrByteCount: Int64
    let elapsedMilliseconds: Int64

    var measurements: [String: Int64] {
        [
            "ffmpegExitStatus": Int64(exitStatus),
            "ffmpegStdoutBytes": stdoutByteCount,
            "ffmpegStderrBytes": stderrByteCount,
            "ffmpegElapsedMilliseconds": elapsedMilliseconds,
        ]
    }
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
    private let serialization = FinalizationMutex()
    private let processRunner = FFmpegProcessRunner()

    func finalize(
        tracks: CapturedTracks,
        recording: Recording,
        baseFolder: URL,
        segmentationEnabled: Bool = true,
        echoSuppressionEnabled: Bool = true,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> RecordingFinalizationResult {
        let snapshot = await MainActor.run { Snapshot(recording: recording) }
        return try await serialization.withLock { [self] in
            try await finalizeLocked(
                tracks: tracks,
                snapshot: snapshot,
                baseFolder: baseFolder,
                segmentationEnabled: segmentationEnabled,
                echoSuppressionEnabled: echoSuppressionEnabled,
                onProgress: onProgress
            )
        }
    }

    private func finalizeLocked(
        tracks: CapturedTracks,
        snapshot: Snapshot,
        baseFolder: URL,
        segmentationEnabled: Bool,
        echoSuppressionEnabled: Bool,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> RecordingFinalizationResult {
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
        var ffmpegDiagnostics: FFmpegRunDiagnostics?
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
                ffmpegDiagnostics = try await transcodeWithFFmpeg(
                    ffmpegPath: ffmpegPath,
                    tracks: usableTracks,
                    outputURL: masterURL,
                    snapshot: snapshot,
                    echoSuppressionEnabled: echoSuppressionEnabled,
                    onProgress: onProgress
                )
            } catch let error as RecordingFinalizerError where error.preservesRawTracks {
                try? fileManager.removeItem(at: masterURL)
                throw error
            } catch {
                warnings.append("ffmpeg merge failed; using one raw CAF as the master. \(error.localizedDescription)")
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
                    segmentURLs = try await createSegments(
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

        // Raw capture is the last-resort recovery source. Consume it only after
        // both durable outputs exist. If metadata or output validation fails,
        // the caller can retry from the untouched tracks on the next launch.
        guard hasNonEmptyFile(masterURL), hasNonEmptyFile(metadataURL) else {
            throw RecordingFinalizerError.ffmpegFailed(
                "Finalized output verification failed; raw capture was retained."
            )
        }
        removeCaptureTracks(tracks)

        return RecordingFinalizationResult(
            masterAudioURL: masterURL,
            segmentAudioURLs: segmentURLs,
            metadataURL: metadataURL,
            warnings: warnings,
            ffmpegDiagnostics: ffmpegDiagnostics
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
        return try await serialization.withLock { [self] in
            try await importExistingAudioLocked(
                sourceURL: sourceURL,
                snapshot: snapshot,
                baseFolder: baseFolder,
                segmentationEnabled: segmentationEnabled
            )
        }
    }

    private func importExistingAudioLocked(
        sourceURL: URL,
        snapshot: Snapshot,
        baseFolder: URL,
        segmentationEnabled: Bool
    ) async throws -> RecordingFinalizationResult {
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
        // Copy first and consume the source only after metadata is durable. A
        // move here made a metadata-write failure strand the only known source.
        try fileManager.copyItem(at: sourceURL, to: masterURL)

        var warnings: [String] = []
        var segmentURLs: [URL] = []
        if segmentationEnabled && snapshot.duration > 1800 {
            if let ffmpegPath = FFmpegLocator.resolve() {
                do {
                    segmentURLs = try await createSegments(ffmpegPath: ffmpegPath, masterURL: masterURL)
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
        guard hasNonEmptyFile(masterURL), hasNonEmptyFile(metadataURL) else {
            throw RecordingFinalizerError.ffmpegFailed(
                "Imported output verification failed; the source was retained."
            )
        }
        try? fileManager.removeItem(at: sourceURL)

        return RecordingFinalizationResult(
            masterAudioURL: masterURL,
            segmentAudioURLs: segmentURLs,
            metadataURL: metadataURL,
            warnings: warnings,
            ffmpegDiagnostics: nil
        )
    }

    private func transcodeWithFFmpeg(
        ffmpegPath: String,
        tracks: CapturedTracks,
        outputURL: URL,
        snapshot: Snapshot,
        echoSuppressionEnabled: Bool,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> FFmpegRunDiagnostics {
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
        // Always request machine-readable progress, even when no UI callback is
        // installed. The process runner uses stdout activity as its watchdog so
        // recovery and queue finalizations cannot hang indefinitely either.
        let progress = FFmpegProgress(duration: snapshot.duration, handler: onProgress)
        let result: ProcessRunResult
        do {
            result = try await runFFmpeg(
                ffmpegPath: ffmpegPath,
                arguments: args,
                progress: progress
            )
        } catch let error as ProcessRunError {
            try? fileManager.removeItem(at: outputURL)
            throw RecordingFinalizerError.processRunner(error)
        }
        guard result.exitStatus == 0 else {
            try? fileManager.removeItem(at: outputURL)
            throw RecordingFinalizerError.processFailed(
                status: result.exitStatus,
                stderrByteCount: result.stderrByteCount
            )
        }
        return FFmpegRunDiagnostics(
            exitStatus: result.exitStatus,
            stdoutByteCount: result.stdoutByteCount,
            stderrByteCount: result.stderrByteCount,
            elapsedMilliseconds: result.elapsedMilliseconds
        )
    }

    private func createSegments(ffmpegPath: String, masterURL: URL) async throws -> [URL] {
        let stem = masterURL.deletingPathExtension().lastPathComponent
        let folder = masterURL.deletingLastPathComponent()
        let pattern = folder.appendingPathComponent("\(stem)_part%02d.m4a")

        let processResult: ProcessRunResult
        do {
            processResult = try await runFFmpeg(
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
                ],
                progress: FFmpegProgress(duration: 0, handler: nil)
            )
        } catch let error as ProcessRunError {
            removeSegmentOutputs(stem: stem, folder: folder)
            throw RecordingFinalizerError.processRunner(error)
        }

        guard processResult.exitStatus == 0 else {
            removeSegmentOutputs(stem: stem, folder: folder)
            throw RecordingFinalizerError.processFailed(
                status: processResult.exitStatus,
                stderrByteCount: processResult.stderrByteCount
            )
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

    private func removeSegmentOutputs(stem: String, folder: URL) {
        let entries = (try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in entries where url.pathExtension.lowercased() == "m4a"
            && url.deletingPathExtension().lastPathComponent.hasPrefix("\(stem)_part")
        {
            try? fileManager.removeItem(at: url)
        }
    }

    private func hasAudioContent(_ url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[FileAttributeKey.size] as? NSNumber else { return false }
        return size.int64Value > 4096  // a valid CAF header + at least one audio packet
    }

    private func hasNonEmptyFile(_ url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return false }
        return size.int64Value > 0
    }

    private func removeCaptureTracks(_ tracks: CapturedTracks) {
        for url in Set([tracks.systemURL, tracks.micURL].compactMap { $0 })
            where fileManager.fileExists(atPath: url.path)
        {
            try? fileManager.removeItem(at: url)
        }
    }

    func fallbackPromoteTrack(tracks: CapturedTracks, targetURL: URL) throws {
        let source: URL
        if let mic = tracks.micURL, hasAudioContent(mic) {
            source = mic
        } else if let system = tracks.systemURL, hasAudioContent(system) {
            source = system
        } else {
            throw RecordingFinalizerError.ffmpegFailed("No usable track for fallback.")
        }
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        try fileManager.copyItem(at: source, to: targetURL)
    }

    private func runFFmpeg(
        ffmpegPath: String,
        arguments: [String],
        progress: FFmpegProgress
    ) async throws -> ProcessRunResult {
        let ffmpegArguments = ["-progress", "pipe:1", "-nostats"] + arguments
        if ffmpegPath == "/usr/bin/env" {
            return try await runProcess(
                executable: ffmpegPath,
                arguments: ["ffmpeg"] + ffmpegArguments,
                progress: progress
            )
        }
        return try await runProcess(
            executable: ffmpegPath,
            arguments: ffmpegArguments,
            progress: progress
        )
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        progress: FFmpegProgress
    ) async throws -> ProcessRunResult {
        let progressLines = ProgressLineBuffer()
        let progressDuration = progress.duration
        let progressHandler = progress.handler
        return try await processRunner.run(
            executable: executable,
            arguments: arguments,
            monitorProgress: true,
            stdoutChunkHandler: { data in
                guard let progressHandler, progressDuration > 0 else { return }
                for line in progressLines.append(data) {
                    if let seconds = RecordingFinalizer.parseFFmpegProgressSeconds(from: line) {
                        progressHandler(min(0.99, max(0, seconds / progressDuration)))
                    }
                }
            }
        )
    }

    /// Duration + handler bundle for streaming ffmpeg `-progress` into a 0…1 fraction.
    private struct FFmpegProgress {
        let duration: TimeInterval
        let handler: (@Sendable (Double) -> Void)?
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
    case processFailed(status: Int32, stderrByteCount: Int64)
    case processRunner(ProcessRunError)

    var preservesRawTracks: Bool {
        switch self {
        case .processFailed, .processRunner:
            true
        case .ffmpegFailed:
            false
        }
    }

    var diagnosticMeasurements: [String: Int64] {
        switch self {
        case .ffmpegFailed:
            [:]
        case .processFailed(let status, let stderrByteCount):
            [
                "ffmpegExitStatus": Int64(status),
                "ffmpegStderrBytes": stderrByteCount,
            ]
        case .processRunner(let error):
            error.diagnosticMeasurements
        }
    }

    var errorDescription: String? {
        switch self {
        case .ffmpegFailed(let stderr):
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                return "ffmpeg command failed."
            }
            return "ffmpeg command failed: \(message)"
        case .processFailed(let status, let stderrByteCount):
            return "Audio finalization failed with status \(status) after producing \(stderrByteCount) bytes of diagnostic output. The original recording tracks were preserved."
        case .processRunner(let error):
            return error.localizedDescription
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
    /// The people in this meeting, written back at processing start: the names typed/confirmed
    /// in the post-recording sheet, and the matched calendar event's attendees. Both are
    /// session-only on `Recording`, so without them a recording reopened from the transcript
    /// browser can only offer voice-library names when assigning speakers. Decoded leniently
    /// (empty for sidecars written before these fields existed).
    var participants: [String] = []
    var calendarAttendees: [String] = []

    private enum CodingKeys: String, CodingKey {
        case dateISO8601, durationSeconds, meetingTitle, masterFileName
        case segmentFileNames, warnings, generatedTitle, participants, calendarAttendees
    }

    init(
        dateISO8601: String,
        durationSeconds: TimeInterval,
        meetingTitle: String,
        masterFileName: String,
        segmentFileNames: [String],
        warnings: [String],
        generatedTitle: String? = nil,
        participants: [String] = [],
        calendarAttendees: [String] = []
    ) {
        self.dateISO8601 = dateISO8601
        self.durationSeconds = durationSeconds
        self.meetingTitle = meetingTitle
        self.masterFileName = masterFileName
        self.segmentFileNames = segmentFileNames
        self.warnings = warnings
        self.generatedTitle = generatedTitle
        self.participants = participants
        self.calendarAttendees = calendarAttendees
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dateISO8601 = try c.decode(String.self, forKey: .dateISO8601)
        durationSeconds = try c.decode(TimeInterval.self, forKey: .durationSeconds)
        meetingTitle = try c.decode(String.self, forKey: .meetingTitle)
        masterFileName = try c.decode(String.self, forKey: .masterFileName)
        segmentFileNames = try c.decode([String].self, forKey: .segmentFileNames)
        warnings = try c.decode([String].self, forKey: .warnings)
        generatedTitle = try c.decodeIfPresent(String.self, forKey: .generatedTitle)
        participants = try c.decodeIfPresent([String].self, forKey: .participants) ?? []
        calendarAttendees = try c.decodeIfPresent([String].self, forKey: .calendarAttendees) ?? []
    }
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

/// Preserves the finalizer's historical one-at-a-time behavior even though the
/// child process wait is now asynchronous and actor-reentrant. A stalled job is
/// bounded by the process watchdog, so later jobs can no longer wait forever.
private actor FinalizationMutex {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        await lock()
        defer { unlock() }
        return try await operation()
    }

    private func lock() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func unlock() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
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
