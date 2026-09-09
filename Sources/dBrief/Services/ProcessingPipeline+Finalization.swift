import Foundation

extension ProcessingPipeline {
    enum FinalizationSource: Sendable {
        case existing(URL)
        case imported
        case capture(CapturedTracks)
    }
    struct FinalizationRecovery: Sendable {
        let url: URL
        let manifest: InterruptedSessionManifest

        static func capture(id: UUID, startedAt: Date, manifestURL: URL?, tracks: CapturedTracks?) -> Self? {
            guard let manifestURL else { return nil }
            return .init(url: manifestURL, manifest: .init(captureID: id, startedAt: startedAt, state: .finalizing,
                manifestURL: manifestURL, capturedTracks: tracks))
        }
    }
    struct FinalizationRequest: Sendable {
        let recordingID: UUID
        let duration: Double
        let source: FinalizationSource
        let recovery: FinalizationRecovery?
    }
    struct FinalizedAudioFacts: Sendable {
        let url: URL
        let fileSize: Int64?
        let duration: Double?
    }
    struct FinalizationSteps: Sendable {
        var finalize: @Sendable () async throws -> RecordingFinalizationResult
        var adopt: @Sendable (RecordingFinalizationResult) async -> Void
        var measured: @Sendable (FinalizedAudioFacts) async -> Void
        var recoveryCompleted: @Sendable (URL) async -> Void
    }
    struct FinalizationFiles: Sendable {
        var size: @Sendable (URL) -> Int64? = { url in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            return (attributes[.size] as? NSNumber)?.int64Value
        }
        var writeRecovery: @Sendable (FinalizationRecovery) throws -> Void = {
            try InterruptedSessionStore.write($0.manifest, to: $0.url)
        }
        var removeRecovery: @Sendable (URL) throws -> Void = {
            try InterruptedSessionStore.removeSession(containing: $0, finalState: .completed)
        }
        var record: @Sendable (DurabilityEvent) -> Void = { DurabilityJournal.shared.record($0) }
    }

    /// Once the finalizer returns, raw inputs may already be consumed. Adoption,
    /// probes and recovery retirement must finish even when Stop cancels this task.
    /// The caller waits for this handoff before snapshotting its cancelled journal.
    /// All file operations and diagnostic writes execute on this actor; callbacks
    /// publish only to the captured Recording, including post-recording actions
    /// that do not own a ProcessingJob.
    func finalizeAudio(_ input: FinalizationRequest, steps: FinalizationSteps,
                       files: FinalizationFiles = .init()) async throws {
        try Task.checkCancellation()
        if case .existing(let url) = input.source {
            if input.duration <= 0 {
                let seconds = await duration(url)
                await steps.measured(.init(url: url, fileSize: nil, duration: validDuration(seconds)))
            }
            await finishFinalizationRecovery(input, steps: steps, files: files)
            return
        }

        if case .capture(let tracks) = input.source {
            if let recovery = input.recovery { try? files.writeRecovery(recovery) }
            files.record(.init(sessionID: input.recordingID, name: "audio_finalization", outcome: .started,
                               measurements: finalizationTrackMeasurements(tracks, files: files)))
        }
        let result: RecordingFinalizationResult
        do {
            try Task.checkCancellation()
            result = try await steps.finalize()
        } catch {
            if case .capture(let tracks) = input.source {
                var measurements = finalizationTrackMeasurements(tracks, files: files)
                if let failure = error as? RecordingFinalizerError {
                    measurements.merge(failure.diagnosticMeasurements, uniquingKeysWith: { _, new in new })
                }
                files.record(.init(sessionID: input.recordingID, name: "audio_finalization", outcome: .failed,
                                   measurements: measurements, failure: .init(error: error)))
            }
            throw error
        }
        // No cancellation/active-job guard after a committed finalization result.
        await steps.adopt(result)
        let bytes = files.size(result.masterAudioURL)
        if case .imported = input.source {
            await steps.measured(.init(url: result.masterAudioURL, fileSize: bytes, duration: nil))
            return
        }
        let seconds = validDuration(await duration(result.masterAudioURL))
        await steps.measured(.init(url: result.masterAudioURL, fileSize: bytes, duration: seconds))
        var measurements: [String: Int64] = [
            "masterBytes": bytes ?? 0,
            "durationMilliseconds": Int64((seconds ?? input.duration) * 1_000),
            "segmentCount": Int64(result.segmentAudioURLs.count),
            "warningCount": Int64(result.warnings.count),
        ]
        if let diagnostics = result.ffmpegDiagnostics {
            measurements.merge(diagnostics.measurements, uniquingKeysWith: { _, new in new })
        }
        files.record(.init(sessionID: input.recordingID, name: "audio_finalization", outcome: .succeeded,
                           measurements: measurements))
        await finishFinalizationRecovery(input, steps: steps, files: files)
    }

    private func validDuration(_ seconds: Double) -> Double? {
        seconds.isFinite && seconds > 0 ? seconds : nil
    }

    private func finalizationTrackMeasurements(_ tracks: CapturedTracks, files: FinalizationFiles) -> [String: Int64] {
        let system = tracks.systemURL.flatMap(files.size) ?? 0
        let mic = tracks.micURL.flatMap(files.size) ?? 0
        return ["trackCount": Int64([tracks.systemURL, tracks.micURL].compactMap { $0 }.count),
                "trackBytes": system + mic, "systemTrackBytes": system, "microphoneTrackBytes": mic]
    }

    private func finishFinalizationRecovery(_ input: FinalizationRequest, steps: FinalizationSteps,
                                            files: FinalizationFiles) async {
        guard let recovery = input.recovery else { return }
        do { try files.removeRecovery(recovery.url) }
        catch {
            files.record(.init(sessionID: input.recordingID, name: "recovery_session_cleanup", outcome: .warning,
                               failure: .init(error: error)))
        }
        // Preserve existing best-effort cleanup policy, including clearing the
        // in-memory reference after a warning. Never clear a replacement URL.
        await steps.recoveryCompleted(recovery.url)
    }
}
