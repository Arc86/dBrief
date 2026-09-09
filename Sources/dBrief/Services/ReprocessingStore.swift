import CryptoKit
import Darwin
import Foundation

/// Owns only recording result sidecars. Audio, recording metadata, privacy receipts,
/// integration journals, and external notes are never publication targets.
///
/// Publication is a recoverable transaction, not a filesystem-wide atomic swap.
/// Call `recover()` before loading canonical results at launch. Cooperating writers
/// must stop editing while an attempt owns the recording; fingerprints also detect
/// independent edits, but cannot eliminate the final external-writer TOCTOU window.
actor ReprocessingStore {
    static let allowedSuffixes: Set<String> = [
        "transcript.json", "richtranscript.json", "insights.json", "chat.json",
        "spokensummary.json", "spokensummary.m4a", "reprocessing.json",
    ]
    private static let derivativeSuffixes: Set<String> = [
        "chat.json", "spokensummary.json", "spokensummary.m4a",
    ]

    enum Status: String, Codable, Sendable {
        case queued, transcribing, speakers, analysis, waitingForSpeakerReview
        case ready, publishing, completed, failed, stopped
    }

    struct Fingerprint: Codable, Equatable, Sendable {
        var exists: Bool
        var byteCount: UInt64
        var sha256: String
        static let missing = Fingerprint(exists: false, byteCount: 0, sha256: "")
    }

    struct Attempt: Codable, Identifiable, Sendable {
        let id: UUID
        let audioURL: URL
        let configuration: Data
        let createdAt: Date
        var updatedAt: Date
        var status: Status
        var completedStages: Set<String>
        var progress: Double
        var message: String?
        let sourceFingerprint: Fingerprint
        let resultFingerprints: [String: Fingerprint]
        var stagedFingerprints: [String: Fingerprint]
        /// Full target set persisted BEFORE the first canonical mutation. Kept after
        /// completion so Restore can reject changes made since publication.
        var publishedFingerprints: [String: Fingerprint]?
    }

    enum StoreError: LocalizedError {
        case missingAudio, alreadyPending, invalidSuffix(String), invalidManifest
        case changedInput(String), noPreviousResults, invalidStatus, unsafeFile(String)
        var errorDescription: String? {
            switch self {
            case .missingAudio: "The original recording is missing. Locate it before resuming."
            case .alreadyPending: "This recording already has a pending reprocessing attempt."
            case .invalidSuffix(let suffix): "Reprocessing does not own the file type \(suffix)."
            case .invalidManifest: "The saved reprocessing attempt is incomplete or damaged."
            case .changedInput(let name): "\(name) changed since this attempt started. The saved candidate has been preserved."
            case .noPreviousResults: "No previous result set is available to restore."
            case .invalidStatus: "This attempt cannot be changed in its current state."
            case .unsafeFile(let name): "Reprocessing cannot use a symbolic link or non-regular file: \(name)."
            }
        }
    }

    private let root: URL
    private let publicationStep: (@Sendable (String) throws -> Void)?
    private let fm = FileManager.default

    init(root: URL = AppSupportPaths.subdirectory("Reprocessing"),
         publicationStep: (@Sendable (String) throws -> Void)? = nil) {
        self.root = root.standardizedFileURL
        self.publicationStep = publicationStep
    }

    func prepare(audioURL: URL, configuration: Data) throws -> Attempt {
        try withStoreLock {
            try prepareUnlocked(audioURL: audioURL, configuration: configuration)
        }
    }

    func load(attemptID: UUID) throws -> Attempt {
        try withStoreLock { try readAttempt(attemptID) }
    }

    func discover() throws -> [Attempt] {
        try withStoreLock { try discoverUnlocked() }
    }

    func pendingAttempt(audioURL: URL) throws -> Attempt? {
        try withStoreLock {
            let source = canonicalAudio(audioURL)
            return try discoverUnlocked().first { $0.audioURL == source && $0.status != .completed }
        }
    }

    func stage(_ data: Data, suffix: String, attemptID: UUID) throws {
        try withStoreLock {
            try checkSuffix(suffix)
            var attempt = try mutableAttempt(attemptID)
            try writePrivate(data, to: payloadURL(attemptID, "staged", suffix))
            attempt.stagedFingerprints[suffix] = fingerprint(data)
            try save(&attempt)
        }
    }

    func stageRemoval(suffix: String, attemptID: UUID) throws {
        try withStoreLock {
            try checkSuffix(suffix)
            var attempt = try mutableAttempt(attemptID)
            // A durable missing marker is sufficient; unused prior stage bytes are
            // harmless and removed with the attempt, never interpreted as output.
            attempt.stagedFingerprints[suffix] = .missing
            try save(&attempt)
        }
    }

    func stagedData(suffix: String, attemptID: UUID) throws -> Data? {
        try withStoreLock {
            try checkSuffix(suffix)
            let attempt = try readAttempt(attemptID)
            guard let expected = attempt.stagedFingerprints[suffix] else { return nil }
            return try readPayload(attemptID, "staged", suffix, expected: expected)
        }
    }

    func originalData(suffix: String, attemptID: UUID) throws -> Data? {
        try withStoreLock {
            try checkSuffix(suffix)
            let attempt = try readAttempt(attemptID)
            guard let expected = attempt.resultFingerprints[suffix] else { throw StoreError.invalidManifest }
            return try readPayload(attemptID, "original", suffix, expected: expected)
        }
    }

    func checkpoint(attemptID: UUID, status: Status, completedStage: String? = nil,
                    progress: Double = 0, message: String? = nil) throws {
        try withStoreLock {
            var attempt = try mutableAttempt(attemptID)
            guard status != .publishing && status != .completed, progress.isFinite else {
                throw StoreError.invalidStatus
            }
            attempt.status = status
            attempt.progress = min(1, max(0, progress))
            attempt.message = message
            if let completedStage { attempt.completedStages.insert(completedStage) }
            try save(&attempt)
        }
    }

    func validate(attemptID: UUID) throws {
        try withStoreLock {
            let attempt = try readAttempt(attemptID)
            try validateSource(attempt)
            try validateResults(attempt, expected: attempt.resultFingerprints)
        }
    }

    func commit(attemptID: UUID) throws {
        try withStoreLock {
            var attempt = try readAttempt(attemptID)
            if attempt.status == .completed { return }
            if attempt.status != .publishing {
                try validateSource(attempt)
                try validateResults(attempt, expected: attempt.resultFingerprints)
                guard !attempt.stagedFingerprints.isEmpty else { throw StoreError.invalidStatus }
                // Verify every candidate BEFORE committing the journal, so corruption
                // can never strand a partially replaced set that cannot roll forward.
                for (suffix, expected) in attempt.stagedFingerprints {
                    _ = try readPayload(attempt.id, "staged", suffix, expected: expected)
                }
                attempt.publishedFingerprints = attempt.resultFingerprints.merging(attempt.stagedFingerprints) { _, new in new }
                attempt.status = .publishing
                try save(&attempt)
            }
            try finishPublication(&attempt)
        }
    }

    /// Finishes only journaled publications. Explicitly stopped and failed work
    /// stays parked; recovery never executes transcription or other processing.
    @discardableResult
    func recover() throws -> [Attempt] {
        try withStoreLock {
            for var attempt in try discoverUnlocked() where attempt.status == .publishing {
                try finishPublication(&attempt)
            }
            return try discoverUnlocked()
        }
    }

    func canRestore(audioURL: URL) throws -> Bool {
        try withStoreLock {
            let source = canonicalAudio(audioURL)
            let attempts = try discoverUnlocked().filter { $0.audioURL == source }
            return !attempts.contains { $0.status != .completed }
                && attempts.contains { $0.status == .completed && $0.publishedFingerprints != nil }
        }
    }

    func restore(audioURL: URL) throws {
        try withStoreLock {
            let source = canonicalAudio(audioURL)
            let attempts = try discoverUnlocked().filter { $0.audioURL == source }
            guard !attempts.contains(where: { $0.status != .completed }) else { throw StoreError.alreadyPending }
            guard let previous = attempts.first(where: { $0.status == .completed }),
                  let expected = previous.publishedFingerprints else { throw StoreError.noPreviousResults }
            try validateSource(previous)
            // Chat and spoken summaries can legitimately be recreated after a
            // successful commit. Restore invalidates them for the restored text;
            // they neither block restoring results nor return from old backups.
            try validateResults(previous, expected: expected, excluding: Self.derivativeSuffixes)
            // Read all backup bytes before creating the new attempt. Originals are
            // immutable, and remain available even if this restore is interrupted.
            var originals: [String: Data] = [:]
            for suffix in Self.allowedSuffixes.subtracting(Self.derivativeSuffixes) {
                guard let fingerprint = previous.resultFingerprints[suffix] else { throw StoreError.invalidManifest }
                originals[suffix] = try readPayload(previous.id, "original", suffix, expected: fingerprint)
            }
            var restoreTargets = previous.resultFingerprints
            for suffix in Self.derivativeSuffixes { restoreTargets[suffix] = .missing }
            // Do not advertise a queued processing attempt during restore staging:
            // interruption before the journal is durable leaves canonical files intact.
            var restoration = try prepareUnlocked(audioURL: source, configuration: previous.configuration, persist: false)
            var journalPublished = false
            do {
                for suffix in Self.allowedSuffixes {
                    if let data = originals[suffix] {
                        try writePrivate(data, to: payloadURL(restoration.id, "staged", suffix))
                    }
                    restoration.stagedFingerprints[suffix] = restoreTargets[suffix]
                }
                restoration.publishedFingerprints = restoreTargets
                restoration.status = .publishing
                try save(&restoration)
                try synchronizeDirectory(root)
                journalPublished = true
                try finishPublication(&restoration)
            } catch {
                if !journalPublished {
                    try? fm.removeItem(at: directory(restoration.id))
                    RecordingResultMutation.release(audioURL: source, attemptID: restoration.id)
                }
                throw error
            }
        }
    }

    func discard(attemptID: UUID) throws {
        try withStoreLock {
            let attempt = try readAttempt(attemptID)
            // A journaled publication must be reconciled, not discarded mid-swap.
            guard attempt.status != .publishing && attempt.status != .completed else { throw StoreError.invalidStatus }
            try fm.removeItem(at: directory(attempt.id))
            RecordingResultMutation.release(audioURL: attempt.audioURL, attemptID: attempt.id)
            try synchronizeDirectory(root)
        }
    }

    /// Deletes private retained backups after an explicit recording deletion.
    /// Pending work, including a publication journal, must never be purged here.
    @discardableResult
    func purgeCompleted(audioURL: URL) throws -> Int {
        try withStoreLock {
            let source = canonicalAudio(audioURL)
            let attempts = try discoverUnlocked().filter { $0.audioURL == source }
            guard attempts.allSatisfy({ $0.status == .completed }) else { throw StoreError.alreadyPending }
            return try purgeCompletedUnlocked(attempts)
        }
    }

    /// Retention cleanup can remove audio outside this store. Remove only its
    /// completed backups, preserving resumable work and that work's prior backup.
    @discardableResult
    func purgeCompletedForMissingAudio() throws -> Int {
        try withStoreLock {
            let attempts = try discoverUnlocked()
            let pendingSources = Set(attempts.filter { $0.status != .completed }.map(\.audioURL))
            let expired = try attempts.filter { attempt in
                guard attempt.status == .completed, !pendingSources.contains(attempt.audioURL) else { return false }
                try requireRegularOrMissing(attempt.audioURL)
                return !fm.fileExists(atPath: attempt.audioURL.path)
            }
            return try purgeCompletedUnlocked(expired)
        }
    }

    /// Transcript retention also covers the private copies of old results, even
    /// when the corresponding audio is retained. Match selected folders recursively
    /// by path components so a sibling with the same path prefix is never included.
    @discardableResult
    func purgeCompletedTranscriptHistory(olderThan cutoff: Date, in folders: [URL]) throws -> Int {
        try withStoreLock {
            let selectedFolders = folders.filter(\.isFileURL).map { canonicalAudio($0).pathComponents }
            guard !selectedFolders.isEmpty else { return 0 }
            let attempts = try discoverUnlocked()
            let pendingSources = Set(attempts.filter { $0.status != .completed }.map(\.audioURL))
            let expired = attempts.filter { attempt in
                guard attempt.status == .completed, attempt.updatedAt <= cutoff,
                      !pendingSources.contains(attempt.audioURL) else { return false }
                let parent = attempt.audioURL.deletingLastPathComponent().pathComponents
                return selectedFolders.contains { parent.starts(with: $0) }
            }
            return try purgeCompletedUnlocked(expired)
        }
    }

    // MARK: - Transaction internals (called under the cross-instance store lock)

    private func purgeCompletedUnlocked(_ attempts: [Attempt]) throws -> Int {
        guard attempts.allSatisfy({ $0.status == .completed }) else { throw StoreError.invalidStatus }
        for attempt in attempts { try fm.removeItem(at: directory(attempt.id)) }
        if !attempts.isEmpty { try synchronizeDirectory(root) }
        return attempts.count
    }

    private func prepareUnlocked(audioURL: URL, configuration: Data, persist: Bool = true) throws -> Attempt {
        let source = canonicalAudio(audioURL)
        guard source.isFileURL else { throw StoreError.missingAudio }
        guard !(try discoverUnlocked()).contains(where: { $0.audioURL == source && $0.status != .completed }) else {
            throw StoreError.alreadyPending
        }
        let sourceFingerprint = try fingerprint(at: source)
        guard sourceFingerprint.exists else { throw StoreError.missingAudio }
        let id = UUID()
        try RecordingResultMutation.claim(audioURL: source, attemptID: id)
        do {
            try createPrivateDirectory(directory(id))
            try createPrivateDirectory(directory(id).appendingPathComponent("original"))
            try createPrivateDirectory(directory(id).appendingPathComponent("staged"))
            var snapshots: [String: Fingerprint] = [:]
            for suffix in Self.allowedSuffixes.sorted() {
                let url = sidecar(source, suffix)
                let current = try fingerprint(at: url)
                snapshots[suffix] = current
                if current.exists {
                    let data = try Data(contentsOf: url)
                    guard fingerprint(data) == current else { throw StoreError.changedInput(url.lastPathComponent) }
                    try writePrivate(data, to: payloadURL(id, "original", suffix))
                }
            }
            var attempt = Attempt(id: id, audioURL: source, configuration: configuration,
                                  createdAt: Date(), updatedAt: Date(), status: .queued,
                                  completedStages: [], progress: 0, message: nil,
                                  sourceFingerprint: sourceFingerprint, resultFingerprints: snapshots,
                                  stagedFingerprints: [:], publishedFingerprints: nil)
            try validateSource(attempt)
            try validateResults(attempt, expected: snapshots)
            if persist {
                try save(&attempt)
                try synchronizeDirectory(root)
            }
            return attempt
        } catch {
            try? fm.removeItem(at: directory(id))
            RecordingResultMutation.release(audioURL: source, attemptID: id)
            throw error
        }
    }

    private func finishPublication(_ attempt: inout Attempt) throws {
        guard attempt.status == .publishing, let target = attempt.publishedFingerprints else {
            throw StoreError.invalidManifest
        }
        try validateSource(attempt)
        // The old or new value is allowed for each file because an interrupted
        // atomic rename can precede the next journal update. A third value is an edit.
        for suffix in Self.allowedSuffixes {
            let current = try fingerprint(at: sidecar(attempt.audioURL, suffix))
            guard current == attempt.resultFingerprints[suffix] || current == target[suffix] else {
                throw StoreError.changedInput(sidecar(attempt.audioURL, suffix).lastPathComponent)
            }
        }
        // Recheck candidates on recovery too, before any further canonical changes.
        for (suffix, expected) in attempt.stagedFingerprints {
            _ = try readPayload(attempt.id, "staged", suffix, expected: expected)
        }
        for suffix in attempt.stagedFingerprints.keys.sorted() {
            guard let expected = target[suffix] else { throw StoreError.invalidManifest }
            let url = sidecar(attempt.audioURL, suffix)
            let current = try fingerprint(at: url)
            if current == expected { continue }
            guard current == attempt.resultFingerprints[suffix] else { throw StoreError.changedInput(url.lastPathComponent) }
            if let data = try readPayload(attempt.id, "staged", suffix, expected: expected) {
                try writePrivate(data, to: url)
            } else {
                try fm.removeItem(at: url)
                try synchronizeDirectory(url.deletingLastPathComponent())
            }
            try publicationStep?(suffix)
        }
        try validateSource(attempt)
        try validateResults(attempt, expected: target)
        attempt.status = .completed
        attempt.progress = 1
        attempt.message = nil
        try save(&attempt)
        RecordingResultMutation.release(audioURL: attempt.audioURL, attemptID: attempt.id)
        // Keep exactly one complete prior set. Cleanup happens after completion is
        // durable, so crashing here can at worst retain an extra backup temporarily.
        for old in try discoverUnlocked() where old.audioURL == attempt.audioURL && old.id != attempt.id && old.status == .completed {
            try fm.removeItem(at: directory(old.id))
        }
        try synchronizeDirectory(root)
    }

    private func validateSource(_ attempt: Attempt) throws {
        let actual = try fingerprint(at: attempt.audioURL)
        guard actual.exists else { throw StoreError.missingAudio }
        guard actual == attempt.sourceFingerprint else { throw StoreError.changedInput(attempt.audioURL.lastPathComponent) }
    }

    private func validateResults(_ attempt: Attempt, expected: [String: Fingerprint], excluding: Set<String> = []) throws {
        for suffix in Self.allowedSuffixes.subtracting(excluding) {
            let url = sidecar(attempt.audioURL, suffix)
            guard try fingerprint(at: url) == expected[suffix] else { throw StoreError.changedInput(url.lastPathComponent) }
        }
    }

    private func mutableAttempt(_ id: UUID) throws -> Attempt {
        let attempt = try readAttempt(id)
        guard attempt.status != .publishing && attempt.status != .completed else { throw StoreError.invalidStatus }
        return attempt
    }

    private func readAttempt(_ id: UUID) throws -> Attempt {
        try requireDirectory(directory(id))
        let url = directory(id).appendingPathComponent("manifest.json")
        try requireRegularOrMissing(url)
        let attempt = try JSONDecoder().decode(Attempt.self, from: Data(contentsOf: url))
        guard attempt.id == id, attempt.audioURL.isFileURL,
              attempt.audioURL == canonicalAudio(attempt.audioURL),
              Set(attempt.resultFingerprints.keys) == Self.allowedSuffixes,
              Set(attempt.stagedFingerprints.keys).isSubset(of: Self.allowedSuffixes),
              attempt.publishedFingerprints.map({ Set($0.keys) == Self.allowedSuffixes }) ?? true,
              attempt.status != .publishing || attempt.publishedFingerprints != nil else {
            throw StoreError.invalidManifest
        }
        return attempt
    }

    private func discoverUnlocked() throws -> [Attempt] {
        let urls = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let attempts = try urls.compactMap { url -> Attempt? in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            // A crash during initial snapshot preparation leaves an unadvertised
            // workspace without a manifest. It cannot own or publish any results.
            guard fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else { return nil }
            return try readAttempt(id)
        }.sorted { $0.createdAt > $1.createdAt }
        for attempt in attempts where attempt.status != .completed {
            try RecordingResultMutation.claim(audioURL: attempt.audioURL, attemptID: attempt.id)
        }
        return attempts
    }

    private func save(_ attempt: inout Attempt) throws {
        attempt.updatedAt = Date()
        try writePrivate(JSONEncoder().encode(attempt), to: directory(attempt.id).appendingPathComponent("manifest.json"))
    }

    private func readPayload(_ id: UUID, _ kind: String, _ suffix: String, expected: Fingerprint) throws -> Data? {
        guard expected.exists else { return nil }
        let url = payloadURL(id, kind, suffix)
        try requireDirectory(url.deletingLastPathComponent())
        try requireRegularOrMissing(url)
        let data = try Data(contentsOf: url)
        guard fingerprint(data) == expected else { throw StoreError.invalidManifest }
        return data
    }

    private func checkSuffix(_ suffix: String) throws {
        guard Self.allowedSuffixes.contains(suffix) else { throw StoreError.invalidSuffix(suffix) }
    }

    private func canonicalAudio(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    private func sidecar(_ audio: URL, _ suffix: String) -> URL { audio.deletingPathExtension().appendingPathExtension(suffix) }
    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func payloadURL(_ id: UUID, _ kind: String, _ suffix: String) -> URL {
        directory(id).appendingPathComponent(kind, isDirectory: true).appendingPathComponent(suffix)
    }

    private func fingerprint(_ data: Data) -> Fingerprint {
        Fingerprint(exists: true, byteCount: UInt64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    /// Streams source audio instead of loading a recording-sized allocation.
    private func fingerprint(at url: URL) throws -> Fingerprint {
        try requireRegularOrMissing(url)
        guard fm.fileExists(atPath: url.path) else { return .missing }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: UInt64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hash.update(data: chunk)
            count += UInt64(chunk.count)
        }
        return Fingerprint(exists: true, byteCount: count, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private func requireRegularOrMissing(_ url: URL) throws {
        do {
            let attrs = try fm.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else { throw StoreError.unsafeFile(url.lastPathComponent) }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return
        }
    }

    private func requireDirectory(_ url: URL) throws {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw StoreError.unsafeFile(url.lastPathComponent) }
    }

    private func createPrivateDirectory(_ url: URL) throws {
        if fm.fileExists(atPath: url.path) {
            try requireDirectory(url)
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// A 0600 temporary file, fsync, atomic rename, and parent-directory fsync make
    /// both journal and payload writes durable without a public-permission window.
    private func writePrivate(_ data: Data, to url: URL) throws {
        try requireDirectory(url.deletingLastPathComponent())
        try requireRegularOrMissing(url)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".reprocessing-\(UUID().uuidString)")
        let descriptor = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? fm.removeItem(at: temp) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Actors serialize one instance; this advisory lock also serializes separate
    /// store instances sharing a root, including a second app process.
    private func withStoreLock<T>(_ body: () throws -> T) throws -> T {
        try createPrivateDirectory(root)
        let descriptor = open(root.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try RecordingResultMutation.withTransaction(body)
    }
}


/// Synchronous publication boundary shared by canonical sidecar writers. Claims
/// last across stopped/failed attempts until commit or explicit discard. The
/// recursive lock drains already-running writes before the baseline is captured.
/// The closure must contain the actual disk mutation, not enqueue another task.
enum RecordingResultMutation {
    private final class State: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var owners: [String: UUID] = [:]
    }
    private static let state = State()

    static func claim(audioURL: URL, attemptID: UUID) throws {
        try withTransaction {
            let key = basePath(audioURL)
            if let owner = state.owners[key], owner != attemptID {
                throw ReprocessingStore.StoreError.alreadyPending
            }
            state.owners[key] = attemptID
        }
    }

    static func release(audioURL: URL, attemptID: UUID) {
        withTransaction {
            let key = basePath(audioURL)
            if state.owners[key] == attemptID { state.owners.removeValue(forKey: key) }
        }
    }

    static func withWrite<T>(to url: URL, _ body: () throws -> T) throws -> T {
        try withTransaction {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            if let suffix = ReprocessingStore.allowedSuffixes.first(where: { path.hasSuffix("." + $0) }),
               state.owners[String(path.dropLast(suffix.count + 1))] != nil {
                throw ReprocessingStore.StoreError.alreadyPending
            }
            return try body()
        }
    }

    static func withTransaction<T>(_ body: () throws -> T) rethrows -> T {
        state.lock.lock()
        defer { state.lock.unlock() }
        return try body()
    }

    private static func basePath(_ audioURL: URL) -> String {
        audioURL.standardizedFileURL.resolvingSymlinksInPath().deletingPathExtension().path
    }
}
