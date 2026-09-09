import AVFoundation
import Foundation

/// Capture recovery filesystem work and diagnostics execute away from MainActor.
/// Hardware/UI lifetime ownership remains with the caller.
actor CaptureSessionStore {
    struct RecoveryInput: Sendable {
        let candidate: InterruptedSessionCandidate
        let fileSize: Int64
        let duration: Double
    }
    struct RecoveryReport: Equatable, Sendable {
        let recovered: Int
        let failed: Int
    }
    struct Dependencies: Sendable {
        var root: @Sendable () -> URL = { InterruptedSessionStore.defaultRootURL }
        // Construct the non-Sendable Foundation object on the owning actor.
        var fileManager: @Sendable () -> FileManager = { .default }
        var duration: @Sendable (URL) async -> Double = CaptureSessionStore.probeDuration
        var now: @Sendable () -> Date = { Date() }
        var record: @Sendable (DurabilityEvent) -> Void = { DurabilityJournal.shared.record($0) }
        var create: @Sendable (UUID, Date, URL) throws -> InterruptedCaptureSession = {
            try InterruptedSessionStore.createSession(id: $0, startedAt: $1, rootURL: $2)
        }
        var write: @Sendable (InterruptedSessionManifest, URL) throws -> Void = {
            try InterruptedSessionStore.write($0, to: $1)
        }
        var remove: @Sendable (URL) throws -> Void = {
            try InterruptedSessionStore.removeSession(containing: $0, finalState: .discarded)
        }
    }

    let dependencies: Dependencies
    init(dependencies: Dependencies = .init()) { self.dependencies = dependencies }

    /// Recovery only finalizes audio. The injected finalizer owns durable master/
    /// metadata verification and raw-track cleanup; this workflow never deletes it.
    /// Ordinary per-session failures do not prevent later recovery candidates.
    func recoverInterrupted(only sessionID: UUID? = nil,
                            finalize: @Sendable (RecoveryInput) async throws -> URL) async throws -> RecoveryReport {
        try Task.checkCancellation()
        let files = dependencies.fileManager()
        let candidates = InterruptedSessionDiscovery.discover(in: dependencies.root(), fileManager: files)
            .filter { sessionID == nil || $0.manifest.id == sessionID }
        try Task.checkCancellation()
        var recovered = 0, failed = 0
        for candidate in candidates {
            try Task.checkCancellation()
            let measurements = trackMeasurements(candidate.capturedTracks, files: files)
            record(candidate.manifest.id, name: "interrupted_capture_discovered", outcome: .warning,
                   measurements: measurements)
            let tracks = candidate.capturedTracks
            let seconds = if let url = tracks.micURL ?? tracks.systemURL { await dependencies.duration(url) } else { 0.0 }
            try Task.checkCancellation()
            let input = RecoveryInput(candidate: candidate, fileSize: measurements["trackBytes"] ?? 0,
                                      duration: seconds.isFinite && seconds > 0 ? seconds : 0)
            do {
                let audioURL = try await finalize(input)
                // A returned master is already committed. Record its true outcome
                // before observing cancellation; no failed event may replace it.
                recovered += 1
                record(candidate.manifest.id, name: "interrupted_capture_recovered", outcome: .succeeded,
                       measurements: ["masterBytes": fileSize(audioURL, files: files)])
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                failed += 1
                record(candidate.manifest.id, name: "interrupted_capture_recovered", outcome: .failed,
                       measurements: trackMeasurements(tracks, files: files), failure: .init(error: error))
            }
            // Historical durability events above still stand, but the caller must
            // not publish success UI or finalize another session after cancellation.
            try Task.checkCancellation()
        }
        return .init(recovered: recovered, failed: failed)
    }

    func fileSize(_ url: URL, files: FileManager) -> Int64 {
        guard let attributes = try? files.attributesOfItem(atPath: url.path) else { return 0 }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    func trackMeasurements(_ tracks: CapturedTracks?) -> [String: Int64] {
        guard let tracks else { return ["trackCount": 0, "trackBytes": 0] }
        return trackMeasurements(tracks, files: dependencies.fileManager())
    }

    func trackMeasurements(_ tracks: CapturedTracks, files: FileManager) -> [String: Int64] {
        let system = tracks.systemURL.map { fileSize($0, files: files) } ?? 0
        let mic = tracks.micURL.map { fileSize($0, files: files) } ?? 0
        return ["trackCount": Int64([tracks.systemURL, tracks.micURL].compactMap { $0 }.count),
                "trackBytes": system + mic, "systemTrackBytes": system, "microphoneTrackBytes": mic]
    }

    func record(_ id: UUID, name: String, outcome: DurabilityEvent.Outcome,
                        measurements: [String: Int64], failure: DurabilityDiagnosticFailure? = nil) {
        dependencies.record(.init(timestamp: dependencies.now(), sessionID: id, name: name,
                                  outcome: outcome, measurements: measurements, failure: failure))
    }

    private nonisolated static func probeDuration(_ url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }
}
