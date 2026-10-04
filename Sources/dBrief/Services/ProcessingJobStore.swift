import Foundation

/// Versioned, atomic persistence for processing jobs. Each job gets an isolated
/// directory so imported audio can be staged durably beside its manifest before
/// finalization starts.
actor ProcessingJobStore {
    static let manifestFileName = "job.json"

    struct Discovery: Sendable {
        var jobs: [PersistedProcessingJob] = []
        var issues: [Issue] = []
    }

    struct Issue: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case corrupt
            case unsupportedVersion(Int)
            case mismatchedIdentifier
        }

        let kind: Kind
    }

    enum StoreError: Error, LocalizedError {
        case unsupportedVersion(Int)
        case mismatchedIdentifier
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                "Processing job version \(version) is not supported."
            case .mismatchedIdentifier:
                "Processing job identity did not match its storage location."
            case .verificationFailed:
                "Processing job could not be verified after saving."
            }
        }
    }

    static var defaultRootURL: URL {
        AppSupportPaths.subdirectory("Processing Jobs")
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL = defaultRootURL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    /// Creates and verifies a new job. Imported/temp audio is copied into the
    /// job directory first; its old staging copy is removed only after the job
    /// manifest is durable and verified.
    func create(
        _ original: PersistedProcessingJob,
        stagingInputURL: URL? = nil
    ) throws -> PersistedProcessingJob {
        var job = original
        let directory = directoryURL(for: job.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        if let stagingInputURL {
            let rawExtension = stagingInputURL.pathExtension.lowercased()
            let safeExtension = rawExtension.allSatisfy { $0.isLetter || $0.isNumber }
                ? rawExtension
                : ""
            let name = safeExtension.isEmpty ? "input.audio" : "input.\(safeExtension)"
            let durableInput = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: durableInput.path) {
                try fileManager.copyItem(at: stagingInputURL, to: durableInput)
            }
            job.source.stagedInputPath = durableInput.path
        }

        try save(job)
        if let stagingInputURL,
           stagingInputURL.standardizedFileURL.path != job.source.stagedInputPath
        {
            try? fileManager.removeItem(at: stagingInputURL)
        }
        return job
    }

    func save(_ job: PersistedProcessingJob) throws {
        try job.markdownExport?.validate()
        guard job.version == PersistedProcessingJob.currentVersion else {
            throw StoreError.unsupportedVersion(job.version)
        }
        guard job.checkpoint.version == ProcessingCheckpoint.currentVersion else {
            throw StoreError.unsupportedVersion(job.checkpoint.version)
        }
        guard job.checkpoint.jobID == job.id else {
            throw StoreError.mismatchedIdentifier
        }

        let url = manifestURL(for: job.id)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(job)
        try data.write(to: url, options: .atomic)

        guard let verified = try? decoder.decode(
            PersistedProcessingJob.self,
            from: Data(contentsOf: url)
        ), verified == job else {
            throw StoreError.verificationFailed
        }
        RecordingLibraryChange.notify()
    }

    func load(id: UUID) throws -> PersistedProcessingJob? {
        let url = manifestURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let job = try decoder.decode(
            PersistedProcessingJob.self,
            from: Data(contentsOf: url)
        )
        try validate(job, directoryID: id)
        return job
    }

    /// Corrupt and future-version manifests are reported but never modified or
    /// deleted. Valid jobs are returned oldest-first for deterministic recovery.
    func discover() -> Discovery {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return fileManager.fileExists(atPath: rootURL.path)
                ? Discovery(issues: [Issue(kind: .corrupt)]) : Discovery()
        }

        var discovery = Discovery()
        for directory in directories {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let directoryID = UUID(uuidString: directory.lastPathComponent)
            else { continue }

            let url = directory.appendingPathComponent(Self.manifestFileName)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                discovery.issues.append(Issue(kind: .corrupt))
                continue
            }

            let job: PersistedProcessingJob
            do {
                job = try decoder.decode(PersistedProcessingJob.self, from: data)
            } catch {
                discovery.issues.append(Issue(kind: .corrupt))
                continue
            }

            guard job.version == PersistedProcessingJob.currentVersion else {
                discovery.issues.append(Issue(kind: .unsupportedVersion(job.version)))
                continue
            }
            guard job.checkpoint.version == ProcessingCheckpoint.currentVersion else {
                discovery.issues.append(Issue(kind: .unsupportedVersion(job.checkpoint.version)))
                continue
            }
            guard job.id == directoryID, job.checkpoint.jobID == job.id else {
                discovery.issues.append(Issue(kind: .mismatchedIdentifier))
                continue
            }
            do {
                try job.markdownExport?.validate()
            } catch {
                discovery.issues.append(Issue(kind: .corrupt))
                continue
            }
            discovery.jobs.append(job)
        }

        discovery.jobs.sort {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
        return discovery
    }

    func remove(id: UUID, expectedRecordingID: UUID? = nil, authority: RecordingDeletionAuthority? = nil, retention: Bool = false) throws {
        if let authority {
            try RecordingResultMutation.withDeletion(of: authority.audioURL) {
                try authority.validate()
                guard let header = try deletionHeader(id: id, retention: retention) else { return }
                guard header.recordingID == expectedRecordingID,
                      try header.source.finalizedAudioPath.map({ try RecordingDeletionAuthority.canonical(URL(fileURLWithPath: $0)).path }) == authority.audioURL.path else { throw LiveArtifactError.wrongOwner }
                try fileManager.removeItem(at: directoryURL(for: id)); RecordingLibraryChange.notify()
            }
        } else { try removeVerified(id: id, expectedRecordingID: expectedRecordingID) }
    }

    func removeForRetention(id: UUID, expectedRecordingID: UUID, expected: RecoveryRetentionAuthority,
                            audioAuthority: RecordingDeletionAuthority? = nil) throws {
        func remove() throws {
            try audioAuthority?.validate()
            guard expected.manifest.url == (try RecordingDeletionAuthority.canonical(manifestURL(for: id))),
                  expected.directory?.url.path == (try RecordingDeletionAuthority.canonical(directoryURL(for: id))).path else { throw LiveArtifactError.wrongOwner }
            try expected.validate()
            if let header = try deletionHeader(id: id, retention: true) {
                guard header.recordingID == expectedRecordingID else { throw LiveArtifactError.wrongOwner }
                if let audioAuthority {
                    guard try header.source.finalizedAudioPath.map({ try RecordingDeletionAuthority.canonical(URL(fileURLWithPath: $0)) }) == audioAuthority.audioURL else { throw LiveArtifactError.wrongOwner }
                }
            }
            // The absent original header does not imply its frozen scratch
            // directory is gone. Validate and finish only surviving originals.
            guard try RecordingDeletionAuthority.Stamp.read(directoryURL(for: id), directory: true) != nil else { try expected.validate(); return }
            try expected.validate()
            try fileManager.removeItem(at: directoryURL(for: id))
            RecordingLibraryChange.notify()
        }
        if let audioAuthority { try RecordingResultMutation.withDeletion(of: audioAuthority.audioURL, remove) }
        else { try RecordingResultMutation.withTransaction(remove) }
    }

    private struct DeletionHeader: Decodable {
        struct Checkpoint: Decodable { let version: Int; let jobID: UUID }
        struct Source: Decodable { let finalizedAudioPath: String? }
        let version: Int, id: UUID, recordingID: UUID
        let checkpoint: Checkpoint
        let source: Source
    }
    private func deletionHeader(id: UUID, retention: Bool = false) throws -> DeletionHeader? {
        guard let header: DeletionHeader = try RecordingDeletionAuthority.readHeader(manifestURL(for: id), maximumBytes: retention ? 128 * 1_024 : 16 * 1_024, tokenLimit: retention ? 32_768 : 512) else { return nil }
        guard header.version == PersistedProcessingJob.currentVersion, header.checkpoint.version == ProcessingCheckpoint.currentVersion,
              header.id == id, header.checkpoint.jobID == id else { throw StoreError.mismatchedIdentifier }
        guard (header.source.finalizedAudioPath?.utf8.count ?? 0) <= 4_096 else { throw LiveArtifactError.artifactTooLarge }
        return header
    }
    /// Finite full-value discovery used only within retention's charged lease.
    func discoverForRetention() throws -> [PersistedProcessingJob] { try retentionInventory().map(\.value) }
    func retentionInventory() throws -> [RecoveryRetentionRecord<PersistedProcessingJob>] {
        var values: [RecoveryRetentionRecord<PersistedProcessingJob>] = [], bytes = 0
        try RecordingDeletionAuthority.scanChildren(rootURL) { directory in
            guard let id = UUID(uuidString: directory.lastPathComponent) else { return }
            guard try RecordingDeletionAuthority.Stamp.read(directory, directory: true) != nil else { return }
            let file = directory.appendingPathComponent(Self.manifestFileName)
            let manifest = try RecordingDeletionAuthority.Item(file)
            guard let stamp = manifest.stamp else { return }
            guard stamp.size <= 128 * 1_024, values.count < 128,
                  stamp.size <= 512 * 1_024 - bytes else { throw LiveArtifactError.artifactTooLarge }
            bytes += Int(stamp.size)
            guard let record: PersistedProcessingJob = try RecordingDeletionAuthority.readHeader(file, maximumBytes: 128 * 1_024,
                tokenLimit: 32_768) else { throw StoreError.verificationFailed }
            try validate(record, directoryID: id)
            values.append(.init(value: record, authority: try .init(manifest: manifest, directory: directory)))
        }
        return values.sorted { $0.value.createdAt < $1.value.createdAt }
    }

    func deletionOwners(for audioURL: URL, byteLimit: Int, retention: Bool = false) throws -> [UUID: UUID] {
        let path = try RecordingDeletionAuthority.canonical(audioURL).path
        var result: [UUID: UUID] = [:]
        try RecordingDeletionAuthority.scanChildren(rootURL) { directory in
            guard let id = UUID(uuidString: directory.lastPathComponent) else { return }
            guard try RecordingDeletionAuthority.Stamp.read(directory, directory: true) != nil else { return }
            guard let header = try deletionHeader(id: id, retention: retention), let source = header.source.finalizedAudioPath,
                  try RecordingDeletionAuthority.canonical(URL(fileURLWithPath: source)).path == path else { return }
            guard result.count < 128, (result.count + 1) * 160 <= byteLimit else { throw LiveArtifactError.artifactTooLarge }
            result[id] = header.recordingID
        }
        return result
    }
    private func removeVerified(id: UUID, expectedRecordingID: UUID?) throws {
        let directory = directoryURL(for: id)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        guard let current = try load(id: id) else { throw StoreError.verificationFailed }
        guard expectedRecordingID == nil || current.recordingID == expectedRecordingID else { throw LiveArtifactError.wrongOwner }
        try fileManager.removeItem(at: directory)
        RecordingLibraryChange.notify()
    }

    private func validate(_ job: PersistedProcessingJob, directoryID: UUID) throws {
        try job.markdownExport?.validate()
        guard job.version == PersistedProcessingJob.currentVersion else {
            throw StoreError.unsupportedVersion(job.version)
        }
        guard job.checkpoint.version == ProcessingCheckpoint.currentVersion else {
            throw StoreError.unsupportedVersion(job.checkpoint.version)
        }
        guard job.id == directoryID, job.checkpoint.jobID == job.id else {
            throw StoreError.mismatchedIdentifier
        }
    }

    private func directoryURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func manifestURL(for id: UUID) -> URL {
        directoryURL(for: id).appendingPathComponent(Self.manifestFileName)
    }
}
