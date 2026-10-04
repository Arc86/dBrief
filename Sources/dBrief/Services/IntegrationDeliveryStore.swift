import Foundation

protocol IntegrationDeliveryPersistence: Sendable {
    func load(id: UUID) async throws -> IntegrationDeliveryBatch?
    func save(_ batch: IntegrationDeliveryBatch) async throws
}

actor IntegrationDeliveryStore: IntegrationDeliveryPersistence {
    enum StoreError: Error, LocalizedError {
        case invalidRecord, verificationFailed, busy
        var errorDescription: String? {
            switch self {
            case .invalidRecord: "Saved integration deliveries could not be read. Their files were left untouched."
            case .verificationFailed: "Integration delivery progress could not be saved. No further sends were attempted."
            case .busy: "Integration delivery is already running."
            }
        }
    }
    private let rootURL: URL
    init(rootURL: URL = AppSupportPaths.subdirectory("Integration Deliveries")) {
        self.rootURL = rootURL
    }
    private func url(_ id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("json")
    }
    func load(id: UUID) throws -> IntegrationDeliveryBatch? {
        guard FileManager.default.fileExists(atPath: url(id).path) else { return nil }
        let batch = try JSONDecoder().decode(IntegrationDeliveryBatch.self, from: Data(contentsOf: url(id)))
        try batch.validate()
        guard batch.id == id else { throw StoreError.invalidRecord }
        return batch
    }
    func save(_ batch: IntegrationDeliveryBatch) throws {
        try batch.validate()
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(batch).write(to: url(batch.id), options: .atomic)
        guard try load(id: batch.id) == batch else { throw StoreError.verificationFailed }
        RecordingLibraryChange.notify()
    }
    func createIfAbsent(_ batch: IntegrationDeliveryBatch) throws -> IntegrationDeliveryBatch {
        if let existing = try load(id: batch.id) { return existing }
        try save(batch)
        return batch
    }
    func latest(forAudioURL audioURL: URL) throws -> IntegrationDeliveryBatch? {
        let matches = try discover().filter {
            $0.bundle.audioFileURL.standardizedFileURL == audioURL.standardizedFileURL
        }
        let ordered = matches.sorted { $0.createdAt > $1.createdAt }
        // A newer successful analysis must not hide an older failed delivery.
        return ordered.first(where: { !$0.isComplete }) ?? ordered.first
    }

    func discover() throws -> [IntegrationDeliveryBatch] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
        var matches: [IntegrationDeliveryBatch] = []
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let batch = try load(id: id) else { throw StoreError.invalidRecord }
            matches.append(batch)
        }
        return matches.sorted { $0.createdAt < $1.createdAt }
    }

    func remove(id: UUID, expectedRecordingID: UUID? = nil, authority: RecordingDeletionAuthority? = nil, retention: Bool = false) throws {
        if let authority {
            try RecordingResultMutation.withDeletion(of: authority.audioURL) {
                try authority.validate()
                guard let header = try deletionHeader(id: id, retention: retention) else { return }
                guard header.recordingID == expectedRecordingID,
                      try RecordingDeletionAuthority.canonical(header.bundle.audioFileURL).path == authority.audioURL.path else { throw LiveArtifactError.wrongOwner }
                try FileManager.default.removeItem(at: url(id)); RecordingLibraryChange.notify()
            }
        } else { try removeVerified(id: id, expectedRecordingID: expectedRecordingID) }
    }

    func removeForRetention(id: UUID, expectedRecordingID: UUID, expected: RecoveryRetentionAuthority,
                            audioAuthority: RecordingDeletionAuthority? = nil) throws {
        func remove() throws {
            try audioAuthority?.validate()
            guard expected.manifest.url == (try RecordingDeletionAuthority.canonical(url(id))),
                  expected.directory == nil, expected.children.isEmpty else { throw LiveArtifactError.wrongOwner }
            try expected.validate()
            guard let header = try deletionHeader(id: id, retention: true) else { try expected.validate(); return }
            guard header.recordingID == expectedRecordingID else { throw LiveArtifactError.wrongOwner }
            if let audioAuthority {
                guard try RecordingDeletionAuthority.canonical(header.bundle.audioFileURL) == audioAuthority.audioURL else { throw LiveArtifactError.wrongOwner }
            }
            try expected.validate()
            try FileManager.default.removeItem(at: url(id))
            RecordingLibraryChange.notify()
        }
        if let audioAuthority { try RecordingResultMutation.withDeletion(of: audioAuthority.audioURL, remove) }
        else { try RecordingResultMutation.withTransaction(remove) }
    }

    private struct DeletionHeader: Decodable {
        struct Bundle: Decodable { let audioFileURL: URL }
        let version: Int, id: UUID, recordingID: UUID
        let bundle: Bundle
    }
    private func deletionHeader(id: UUID, retention: Bool = false) throws -> DeletionHeader? {
        guard let header: DeletionHeader = try RecordingDeletionAuthority.readHeader(url(id), maximumBytes: retention ? 128 * 1_024 : 16 * 1_024, tokenLimit: retention ? 32_768 : 512) else { return nil }
        guard header.version == IntegrationDeliveryBatch.currentVersion, header.id == id else { throw StoreError.invalidRecord }
        guard header.bundle.audioFileURL.isFileURL, header.bundle.audioFileURL.absoluteString.utf8.count <= 4_096 else { throw LiveArtifactError.artifactTooLarge }
        return header
    }
    func discoverForRetention() throws -> [IntegrationDeliveryBatch] { try retentionInventory().map(\.value) }
    func retentionInventory() throws -> [RecoveryRetentionRecord<IntegrationDeliveryBatch>] {
        var values: [RecoveryRetentionRecord<IntegrationDeliveryBatch>] = [], bytes = 0
        try RecordingDeletionAuthority.scanChildren(rootURL) { file in
            guard file.pathExtension == "json" else { return }
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let stamp = try RecordingDeletionAuthority.Stamp.read(file) else { throw StoreError.invalidRecord }
            let manifest = try RecordingDeletionAuthority.Item(file)
            guard manifest.stamp == stamp else { throw LiveArtifactError.wrongOwner }
            guard stamp.size <= 128 * 1_024, values.count < 128,
                  stamp.size <= 512 * 1_024 - bytes else { throw LiveArtifactError.artifactTooLarge }
            bytes += Int(stamp.size)
            guard let batch: IntegrationDeliveryBatch = try RecordingDeletionAuthority.readHeader(file, maximumBytes: 128 * 1_024,
                tokenLimit: 32_768) else { throw StoreError.invalidRecord }
            try batch.validate(); guard batch.id == id else { throw StoreError.invalidRecord }
            values.append(.init(value: batch, authority: try .init(manifest: manifest)))
        }
        return values.sorted { $0.value.createdAt < $1.value.createdAt }
    }

    func deletionOwners(for audioURL: URL, alsoIDs: Set<UUID>, byteLimit: Int, retention: Bool = false) throws -> [UUID: UUID] {
        let path = try RecordingDeletionAuthority.canonical(audioURL).path
        var result: [UUID: UUID] = [:]
        try RecordingDeletionAuthority.scanChildren(rootURL) { file in
            guard file.pathExtension == "json" else { return }
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let header = try deletionHeader(id: id, retention: retention) else { throw StoreError.invalidRecord }
            let ownedAudio = try RecordingDeletionAuthority.canonical(header.bundle.audioFileURL).path == path
            guard !alsoIDs.contains(id) || ownedAudio else { throw LiveArtifactError.wrongOwner }
            guard alsoIDs.contains(id) || ownedAudio else { return }
            guard result.count < 128, (result.count + 1) * 160 <= byteLimit else { throw LiveArtifactError.artifactTooLarge }
            result[id] = header.recordingID
        }
        return result
    }
    private func removeVerified(id: UUID, expectedRecordingID: UUID?) throws {
        guard let current = try load(id: id) else { return }
        guard expectedRecordingID == nil || current.recordingID == expectedRecordingID else { throw LiveArtifactError.wrongOwner }
        try FileManager.default.removeItem(at: url(id))
        RecordingLibraryChange.notify()
    }
}
