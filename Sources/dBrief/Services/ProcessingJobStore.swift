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
        /// The job's folder, so the user can inspect it or move it aside. Nil when the
        /// store's own folder could not be listed.
        var directoryURL: URL? = nil
    }

    enum StoreError: Error, LocalizedError {
        case unsupportedVersion(Int)
        case mismatchedIdentifier
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                String(localized: "Processing job version \(version) is not supported.")
            case .mismatchedIdentifier:
                String(localized: "Processing job identity did not match its storage location.")
            case .verificationFailed:
                String(localized: "Processing job could not be verified after saving.")
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
                discovery.issues.append(Issue(kind: .corrupt, directoryURL: directory))
                continue
            }

            let job: PersistedProcessingJob
            do {
                job = try decoder.decode(PersistedProcessingJob.self, from: data)
            } catch {
                discovery.issues.append(Issue(kind: .corrupt, directoryURL: directory))
                continue
            }

            guard job.version == PersistedProcessingJob.currentVersion else {
                discovery.issues.append(Issue(kind: .unsupportedVersion(job.version), directoryURL: directory))
                continue
            }
            guard job.checkpoint.version == ProcessingCheckpoint.currentVersion else {
                discovery.issues.append(Issue(kind: .unsupportedVersion(job.checkpoint.version), directoryURL: directory))
                continue
            }
            guard job.id == directoryID, job.checkpoint.jobID == job.id else {
                discovery.issues.append(Issue(kind: .mismatchedIdentifier, directoryURL: directory))
                continue
            }
            do {
                try job.markdownExport?.validate()
            } catch {
                discovery.issues.append(Issue(kind: .corrupt, directoryURL: directory))
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

    /// Moves an unreadable job folder into `Unreadable/` inside the store, where
    /// discovery skips it (not a UUID name). Never moves a readable job; never deletes.
    func moveAside(_ directory: URL) throws -> URL {
        let directory = directory.standardizedFileURL
        guard directory.deletingLastPathComponent().path == rootURL.standardizedFileURL.path,
              let id = UUID(uuidString: directory.lastPathComponent),
              fileManager.fileExists(atPath: directory.appendingPathComponent(Self.manifestFileName).path),
              (try? load(id: id)) == nil else { throw StoreError.verificationFailed }
        let aside = rootURL.appendingPathComponent("Unreadable", isDirectory: true)
        try fileManager.createDirectory(at: aside, withIntermediateDirectories: true)
        var target = aside.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
        if fileManager.fileExists(atPath: target.path) {
            target = aside.appendingPathComponent("\(directory.lastPathComponent)-\(Int(Date().timeIntervalSince1970))",
                                                  isDirectory: true)
        }
        try fileManager.moveItem(at: directory, to: target)
        RecordingLibraryChange.notify()
        return target
    }

    func remove(id: UUID) throws {
        let directory = directoryURL(for: id)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        guard try load(id: id) != nil else { throw StoreError.verificationFailed }
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
