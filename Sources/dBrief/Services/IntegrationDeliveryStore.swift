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

    func remove(id: UUID) throws {
        guard try load(id: id) != nil else { return }
        try FileManager.default.removeItem(at: url(id))
    }
}
