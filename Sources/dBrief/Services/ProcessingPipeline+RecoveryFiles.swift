import Foundation

struct FinalizedRecordingMatch: Equatable, Sendable {
    let audioURL: URL
    let metadataURL: URL
    let segmentURLs: [URL]
}

extension ProcessingPipeline {
    struct RecoveredRecordingSource: Sendable {
        let fileURL: URL
        let duration: Double
        let fileSize: Int64
        var finalizedAudioURL: URL? = nil
        var segmentAudioURLs: [URL] = []
        var metadataURL: URL? = nil
        var importSourceURL: URL? = nil
        var capturedTracks: CapturedTracks? = nil
        var recoveryManifestURL: URL? = nil
    }

    /// Resolve durable inputs without touching the observable Recording. A missing
    /// staged input intentionally does not fall through to capture recovery; the
    /// saved source kind remains authoritative. No files are changed by discovery.
    func recoverRecordingSource(recordingID: UUID, source: PersistedProcessingJob.Source,
                                recordingFolder: URL, recoveryRoot: URL,
                                fileManager: FileManager = .default) async throws -> RecoveredRecordingSource? {
        try Task.checkCancellation()
        let result = try await resolveRecordingSource(recordingID: recordingID, source: source,
            recordingFolder: recordingFolder, recoveryRoot: recoveryRoot, fileManager: fileManager)
        // Even a nil result must cross the cancellation check: it drives a
        // missing-input checkpoint at startup, whereas cancellation must not.
        try Task.checkCancellation()
        return result
    }

    private func resolveRecordingSource(recordingID: UUID, source: PersistedProcessingJob.Source,
                                        recordingFolder: URL, recoveryRoot: URL,
                                        fileManager: FileManager) async throws -> RecoveredRecordingSource? {
        var finalized = source.finalizedAudioPath.map(URL.init(fileURLWithPath:))
        var metadata = source.metadataPath.map(URL.init(fileURLWithPath:))
        var segments = source.segmentAudioPaths.map(URL.init(fileURLWithPath:))
        if let url = finalized, !fileManager.fileExists(atPath: url.path) { finalized = nil }
        if finalized == nil, let match = findFinalizedRecording(recordingID: recordingID, in: recordingFolder, fileManager: fileManager) {
            finalized = match.audioURL
            metadata = match.metadataURL
            segments = match.segmentURLs
        }
        try Task.checkCancellation()
        if let finalized {
            let attributes = try? fileManager.attributesOfItem(atPath: finalized.path)
            let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? source.fileSize
            return .init(fileURL: finalized, duration: source.duration, fileSize: bytes,
                finalizedAudioURL: finalized,
                segmentAudioURLs: segments.filter { fileManager.fileExists(atPath: $0.path) }, metadataURL: metadata)
        }
        if let path = source.stagedInputPath {
            let url = URL(fileURLWithPath: path)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return .init(fileURL: url, duration: source.duration, fileSize: source.fileSize, importSourceURL: url)
        }
        guard let path = source.recoveryManifestPath else { return nil }
        let manifest = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard let candidate = InterruptedSessionDiscovery.discover(in: recoveryRoot).first(where: {
            $0.manifestURL.resolvingSymlinksInPath().standardizedFileURL == manifest
        }) else { return nil }
        let tracks = candidate.capturedTracks
        let bytes = [tracks.systemURL, tracks.micURL].compactMap { $0 }.reduce(Int64(0)) { total, url in
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        var seconds = source.duration
        if seconds <= 0, let url = tracks.micURL ?? tracks.systemURL {
            let probed = await duration(url)
            seconds = probed.isFinite && probed > 0 ? probed : 0
        }
        try Task.checkCancellation()
        return .init(fileURL: candidate.manifestURL.deletingLastPathComponent().appendingPathComponent("capture"),
            duration: seconds, fileSize: bytes, capturedTracks: tracks, recoveryManifestURL: candidate.manifestURL)
    }

    /// Finds a finalized master by the stable recording UUID embedded in its
    /// metadata. This closes the crash window after the finalizer moved the audio
    /// but before the processing-job manifest learned the destination path.
    func findFinalizedRecording(
        recordingID: UUID,
        in folder: URL,
        fileManager: FileManager = .default
    ) -> FinalizedRecordingMatch? {
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let decoder = JSONDecoder()
        for case let metadataURL as URL in enumerator {
            guard metadataURL.pathExtension.lowercased() == "json",
                  let data = try? Data(contentsOf: metadataURL),
                  let payload = try? decoder.decode(RecordingMetadataPayload.self, from: data),
                  payload.recordingID == recordingID,
                  payload.masterFileName == URL(fileURLWithPath: payload.masterFileName).lastPathComponent
            else { continue }

            let directory = metadataURL.deletingLastPathComponent()
            let audioURL = directory.appendingPathComponent(payload.masterFileName)
            guard fileManager.fileExists(atPath: audioURL.path) else { continue }
            let segments = payload.segmentFileNames.compactMap { name -> URL? in
                guard name == URL(fileURLWithPath: name).lastPathComponent else { return nil }
                let url = directory.appendingPathComponent(name)
                return fileManager.fileExists(atPath: url.path) ? url : nil
            }
            return FinalizedRecordingMatch(
                audioURL: audioURL,
                metadataURL: metadataURL,
                segmentURLs: segments
            )
        }
        return nil
    }

}
