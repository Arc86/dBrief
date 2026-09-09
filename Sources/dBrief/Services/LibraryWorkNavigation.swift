import Foundation

enum LibraryWorkNavigation {
    enum Destination: Equatable, Sendable {
        case processing(UUID), delivery(UUID, URL), queue(UUID, URL), capture(UUID)
    }
    enum Failure: Error, LocalizedError {
        case changed, unavailable, busy
        var errorDescription: String? {
            switch self {
            case .changed: "This work has changed or is no longer pending. Refresh the library to see its current state."
            case .unavailable: "The recording is unavailable. Reconnect its storage and refresh the library."
            case .busy: "Wait for recording, processing or recovery to finish, then try again."
            }
        }
    }

    static func resolve(_ item: LibraryWorkItem, jobs: ProcessingJobStore, deliveries: any IntegrationDeliveryPersistence,
                        sessionsRoot: URL = InterruptedSessionStore.defaultRootURL) async throws -> Destination {
        try Task.checkCancellation()
        if item.target == .capture {
            let discovery = await jobs.discover()
            try Task.checkCancellation()
            guard discovery.issues.isEmpty else { throw Failure.changed }
            let path = sessionsRoot.appendingPathComponent(item.recoveryID.uuidString.lowercased())
                .appendingPathComponent(InterruptedSessionManifest.fileName).standardizedFileURL
            if let owner = discovery.jobs.first(where: {
                $0.recordingID == item.recoveryID || $0.source.recoveryManifestPath.map { URL(fileURLWithPath: $0).standardizedFileURL == path } == true
            }) {
                return try await resolveJob(owner, deliveries: deliveries)
            }
            guard InterruptedSessionDiscovery.discover(in: sessionsRoot).contains(where: { $0.manifest.id == item.recoveryID }) else {
                throw Failure.unavailable
            }
            return .capture(item.recoveryID)
        }
        let job = try await jobs.load(id: item.recoveryID)
        guard job?.dismissedFromQueue != true else { throw Failure.changed }
        let batch = try await deliveries.load(id: item.recoveryID)
        guard batch?.dismissedFromQueue != true else { throw Failure.changed }
        try Task.checkCancellation()
        if let batch, !batch.isComplete { return .delivery(batch.id, batch.bundle.audioFileURL) }
        if let job, job.checkpoint.hasCompleted(.markdownGenerated) || job.status == .completed {
            return try await resolveJob(job, deliveries: deliveries)
        }
        if item.target == .queue {
            guard let audio = item.audioURL, FileManager.default.fileExists(atPath: audio.path) else { throw Failure.unavailable }
            let marker = audio.deletingPathExtension().appendingPathExtension("queue.json")
            guard try QueueItem.load(from: marker).id == item.recoveryID else { throw Failure.changed }
            if let job, job.status == .failed || job.status == .cancelled { return .processing(job.id) }
            return .queue(item.recoveryID, audio)
        }
        guard let job else { throw Failure.changed }
        return try await resolveJob(job, deliveries: deliveries)
    }

    private static func resolveJob(_ job: PersistedProcessingJob, deliveries: any IntegrationDeliveryPersistence) async throws -> Destination {
        guard job.dismissedFromQueue != true else { throw Failure.changed }
        let batch = try await deliveries.load(id: job.id)
        try Task.checkCancellation()
        if let batch {
            guard batch.dismissedFromQueue != true else { throw Failure.changed }
            if !batch.isComplete { return .delivery(job.id, batch.bundle.audioFileURL) }
            if job.checkpoint.hasCompleted(.markdownGenerated) { throw Failure.changed }
        }
        guard job.status != .completed else { throw Failure.changed }
        if job.checkpoint.hasCompleted(.markdownGenerated) {
            guard let path = job.source.finalizedAudioPath else { throw Failure.unavailable }
            return .delivery(job.id, URL(fileURLWithPath: path))
        }
        return .processing(job.id)
    }
}
