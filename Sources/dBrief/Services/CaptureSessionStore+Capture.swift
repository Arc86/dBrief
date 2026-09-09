import Foundation

extension CaptureSessionStore {
    struct Session: Sendable {
        let id: UUID
        let startedAt: Date
        let files: InterruptedCaptureSession
    }
    struct CaptureState: Sendable {
        var tracks: CapturedTracks? = nil
        var duration: Double = 0
        var microphoneEnabled = false
        var systemAudioEnabled = false
        var writes = AudioCaptureWriteDiagnostics()
        var failure: DurabilityDiagnosticFailure? = nil
    }
    struct StoppedCapture: Sendable {
        let session: Session
        let state: CaptureState
        let fileSize: Int64
        let duration: Double
    }

    /// These commands belong to an owned capture task. Caller cancellation cannot
    /// interrupt a durable stop/checkpoint or release hardware ownership early.
    func create(id: UUID, startedAt: Date) throws -> Session {
        do {
            return try .init(id: id, startedAt: startedAt,
                             files: dependencies.create(id, startedAt, dependencies.root()))
        } catch {
            record(id, name: "capture_recovery_session_created", outcome: .failed, measurements: [:], failure: .init(error: error))
            throw error
        }
    }

    func began(_ session: Session, state: CaptureState) throws {
        try dependencies.write(manifest(session, state: .capturing, tracks: state.tracks), session.files.manifestURL)
        record(session.id, name: "capture_started", outcome: .succeeded,
               measurements: ["microphoneEnabled": state.microphoneEnabled ? 1 : 0,
                              "systemAudioEnabled": state.systemAudioEnabled ? 1 : 0])
    }

    func pauseResume(_ session: Session, state: CaptureState, paused: Bool) {
        try? dependencies.write(manifest(session, state: paused ? .paused : .capturing, tracks: state.tracks),
                                session.files.manifestURL)
        record(session.id, name: paused ? "capture_paused" : "capture_resumed", outcome: .succeeded,
               measurements: [:])
    }

    func failedStart(_ session: Session, state: CaptureState, failure: DurabilityDiagnosticFailure) {
        let files = dependencies.fileManager()
        record(session.id, name: "capture_started", outcome: .failed,
               measurements: measurements(state.tracks, files: files), failure: failure)
        // A failed size probe is not proof that no audio exists. Inspect the entire
        // session, including tracks whose URLs were never returned by failed setup.
        if provenEmpty(session, files: files) { try? dependencies.remove(session.files.manifestURL) }
    }

    func stopped(_ session: Session, state: CaptureState, terminating: Bool) async -> StoppedCapture {
        try? dependencies.write(manifest(session, state: .finalizing, tracks: state.tracks), session.files.manifestURL)
        let measurements = trackMeasurements(state.tracks)
        let timer = state.duration.isFinite && state.duration > 0 ? state.duration : 0
        var duration = timer
        if !terminating, let url = state.tracks?.micURL ?? state.tracks?.systemURL {
            let probed = await dependencies.duration(url)
            if probed.isFinite && probed > 0 { duration = probed }
        }
        let result = StoppedCapture(session: session, state: state,
                                    fileSize: measurements["trackBytes"] ?? 0, duration: duration)
        if terminating {
            recordTermination(result)
        } else {
            var facts = measurements
            facts["durationMilliseconds"] = duration >= Double(Int64.max) / 1_000 ? Int64.max : Int64(duration * 1_000)
            facts["microphoneBuffers"] = state.writes.microphone.buffersWritten
            facts["systemBuffers"] = state.writes.system.buffersWritten
            facts["microphoneDroppedBuffers"] = state.writes.microphone.droppedBuffers
            facts["systemDroppedBuffers"] = state.writes.system.droppedBuffers
            facts["microphoneWriteErrors"] = state.writes.microphone.writeErrors
            facts["systemWriteErrors"] = state.writes.system.writeErrors
            facts["systemStreamFailures"] = state.writes.systemStreamFailures
            let warnings = state.writes.microphone.droppedBuffers > 0 || state.writes.system.droppedBuffers > 0
                || state.writes.microphone.writeErrors > 0 || state.writes.system.writeErrors > 0
                || state.writes.systemStreamFailures > 0
            record(session.id, name: "capture_stopped", outcome: result.fileSize == 0 ? .failed : (warnings ? .warning : .succeeded),
                   measurements: facts, failure: state.failure)
        }
        return result
    }

    /// A quit arriving during a normal stop upgrades its UI disposition. The
    /// finalizing manifest is already written; append the termination fact once.
    func recordTermination(_ capture: StoppedCapture) {
        record(capture.session.id, name: "capture_checkpointed_for_termination",
               outcome: capture.fileSize > 0 ? .succeeded : .failed,
               measurements: trackMeasurements(capture.state.tracks))
    }

    private func measurements(_ tracks: CapturedTracks?, files: FileManager) -> [String: Int64] {
        guard let tracks else { return ["trackCount": 0, "trackBytes": 0] }
        return trackMeasurements(tracks, files: files)
    }

    private func manifest(_ session: Session, state: InterruptedSessionManifest.State,
                          tracks: CapturedTracks?) -> InterruptedSessionManifest {
        .init(captureID: session.id, startedAt: session.startedAt, state: state,
              manifestURL: session.files.manifestURL, capturedTracks: tracks)
    }

    private func provenEmpty(_ session: Session, files: FileManager) -> Bool {
        guard let urls = try? files.contentsOfDirectory(at: session.files.directoryURL,
                                                      includingPropertiesForKeys: nil, options: []) else { return false }
        let manifestPath = session.files.manifestURL.standardizedFileURL.path
        for url in urls where url.standardizedFileURL.path != manifestPath {
            guard let attributes = try? files.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.int64Value == 0 else { return false }
        }
        return true
    }
}
