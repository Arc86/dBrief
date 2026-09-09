import Foundation

/// The shared writer for canonical recording metadata. Transactions contain no
/// suspension points, so independent field updates always read the latest file.
actor RecordingMetadataStore {
    static let shared = RecordingMetadataStore()

    struct Files: Sendable {
        var read: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
        var write: @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
        var changed: @Sendable () -> Void = { RecordingLibraryChange.notify() }
    }
    enum Update: Sendable {
        case generatedTitle(String)
        case meetingContext(participants: [String], calendarAttendees: [String])
    }
    private let files: Files
    init(files: Files = .init()) { self.files = files }

    /// Finalization owns a newly selected output path. A failed/cancelled write
    /// throws before the caller is allowed to consume its original capture/input.
    func create(_ payload: RecordingMetadataPayload, at url: URL) throws {
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try writeVerified(encoder.encode(payload), to: url)
    }

    /// Optional descriptive edits retain the prior missing/corrupt-file no-op
    /// behavior. Modify only named fields, preserving completion and future keys.
    func update(_ update: Update, audioURL: URL) throws {
        try Task.checkCancellation()
        let url = audioURL.deletingPathExtension().appendingPathExtension("json")
        let data = try? files.read(url)
        try Task.checkCancellation()
        guard let data,
              let payload = try? JSONDecoder().decode(RecordingMetadataPayload.self, from: data),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        switch update {
        case .generatedTitle(let title):
            guard payload.generatedTitle != title else { return }
            object["generatedTitle"] = title
        case .meetingContext(let participants, let attendees):
            guard payload.participants != participants || payload.calendarAttendees != attendees else { return }
            object["participants"] = participants
            object["calendarAttendees"] = attendees
        }
        try writeVerified(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]), to: url)
    }

    private func writeVerified(_ bytes: Data, to url: URL) throws {
        try Task.checkCancellation()
        defer { files.changed() }
        try files.write(bytes, url)
        try Task.checkCancellation()
        let saved = try files.read(url)
        try Task.checkCancellation()
        guard saved == bytes else { throw Failure.verificationFailed }
    }

    enum Failure: Error, LocalizedError {
        case recordingUnavailable, invalidMetadata, verificationFailed
        var errorDescription: String? {
            switch self {
            case .recordingUnavailable: "The recording is unavailable. Its processing completion date could not be saved."
            case .invalidMetadata: "The recording metadata could not be read. Its recovery journal has been kept."
            case .verificationFailed: "The recording metadata could not be verified."
            }
        }
    }

    func record(_ completion: ProcessingCompletionStamp, audioURL: URL,
                       fallback: RecordingMetadataPayload) throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        let audioType = try fm.attributesOfItem(atPath: audioURL.path)[.type] as? FileAttributeType
        guard audioType == .typeRegular else { throw Failure.recordingUnavailable }
        let url = audioURL.deletingPathExtension().appendingPathExtension("json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        var object: [String: Any]
        do {
            guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
                throw Failure.invalidMetadata
            }
            let bytes = try files.read(url)
            try Task.checkCancellation()
            guard (try? JSONDecoder().decode(RecordingMetadataPayload.self, from: bytes)) != nil,
                  let parsed = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure.invalidMetadata }
            object = parsed
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            guard let parsed = try JSONSerialization.jsonObject(with: encoder.encode(fallback)) as? [String: Any] else { throw Failure.invalidMetadata }
            object = parsed
        }
        // Legacy queue entries and reopened viewers may have a different
        // in-memory recording ID. The actual processed audio path owns this
        // metadata; preserve its existing stable identity and all other fields.
        if let existing = object["lastProcessingCompletion"], !(existing is NSNull) {
            let old = try JSONDecoder().decode(ProcessingCompletionStamp.self, from: JSONSerialization.data(withJSONObject: existing))
            if old.jobID == completion.jobID || old.completedAt >= completion.completedAt { return }
        }
        object["lastProcessingCompletion"] = try JSONSerialization.jsonObject(with: encoder.encode(completion))
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        try writeVerified(bytes, to: url)
    }

    func reconcile(_ record: PersistedProcessingJob) throws {
        try Task.checkCancellation()
        guard let completedAt = record.completedAt, let path = record.source.finalizedAudioPath else { return }
        let audio = URL(fileURLWithPath: path)
        guard try audioStillExists(audio) else { return }
        let source = record.source
        let fallback = RecordingMetadataPayload(recordingID: record.recordingID,
            dateISO8601: ISO8601DateFormatter().string(from: source.recordingDate), durationSeconds: source.duration,
            meetingTitle: source.meetingTitle, masterFileName: audio.lastPathComponent,
            segmentFileNames: source.segmentAudioPaths.map { URL(fileURLWithPath: $0).lastPathComponent }, warnings: [],
            participants: source.participants, calendarAttendees: source.calendarEvent?.attendeeNames ?? [], associatedApp: source.associatedApp)
        try self.record(.init(jobID: record.id, completedAt: completedAt), audioURL: audio, fallback: fallback)
    }

    func reconcile(_ batch: IntegrationDeliveryBatch) throws {
        try Task.checkCancellation()
        guard let completion = batch.successfulWorkflowCompletion else { return }
        let audio = batch.bundle.audioFileURL
        guard try audioStillExists(audio) else { return }
        let fallback = RecordingMetadataPayload(recordingID: batch.recordingID,
            dateISO8601: ISO8601DateFormatter().string(from: batch.bundle.createdAt), durationSeconds: batch.bundle.durationSeconds,
            meetingTitle: batch.bundle.title, masterFileName: audio.lastPathComponent, segmentFileNames: [], warnings: [])
        try record(completion, audioURL: audio, fallback: fallback)
    }

    private func audioStillExists(_ url: URL) throws -> Bool {
        // Enumerating the parent distinguishes a deleted recording from offline
        // storage. Failure preserves the journal instead of losing its date.
        let siblings = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        return siblings.contains { $0.lastPathComponent == url.lastPathComponent }
    }
}
