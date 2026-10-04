import CryptoKit
import Darwin
import Foundation
import dBriefWire

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
        var configuration: Data
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
        /// Optional for legacy journals. Managed preparation freezes this before
        /// effects, and recovery never transfers it to a replaced master/owner.
        var authority: RecordingDeletionAuthority? = nil
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
    enum PreparationStage: Sendable { case snapshotAdmission, snapshotPrepared, restorationPrepared, publicationAdmission }
    private let preparationStage: @Sendable (PreparationStage) async -> Void
    private let fm = FileManager.default

    init(root: URL = AppSupportPaths.subdirectory("Reprocessing"),
         publicationStep: (@Sendable (String) throws -> Void)? = nil,
         preparationStage: @escaping @Sendable (PreparationStage) async -> Void = { _ in }) {
        self.root = root.standardizedFileURL
        self.publicationStep = publicationStep
        self.preparationStage = preparationStage
    }

    func prepare(audioURL: URL, configuration: Data, authority: RecordingDeletionAuthority? = nil) async throws -> Attempt {
        await preparationStage(.snapshotAdmission)
        try Task.checkCancellation()
        let attempt = try withStoreLock {
            try prepareUnlocked(audioURL: audioURL, configuration: configuration, authority: authority)
        }
        await preparationStage(.snapshotPrepared)
        return attempt
    }

    func load(attemptID: UUID) throws -> Attempt {
        try withStoreLock { try readAttempt(attemptID) }
    }

    func discover() throws -> [Attempt] {
        try withStoreLock { try discoverUnlocked() }
    }

    /// Retention admission retains a finite aggregate, without acquiring claims
    /// or loading every historical configuration before checking its bounds.
    func discoverForRetention() throws -> [Attempt] {
        try withStoreLock { try discoverRetentionUnlocked() }
    }
    private func discoverRetentionUnlocked() throws -> [Attempt] {
        var values: [Attempt] = [], bytes = 0
        try RecordingDeletionAuthority.scanChildren(root, includeHidden: true) { directory in
            guard let id = UUID(uuidString: directory.lastPathComponent) else { return }
            try requireDirectory(directory)
            let file = directory.appendingPathComponent("manifest.json")
            guard let stamp = try RecordingDeletionAuthority.Stamp.read(file) else { return }
            guard values.count < 128, stamp.size >= 0, stamp.size <= 512 * 1_024 - bytes else { throw LiveArtifactError.artifactTooLarge }
            let value = try readAttempt(id)
            guard try RecordingDeletionAuthority.Stamp.read(file) == stamp else { throw LiveArtifactError.wrongOwner }
            bytes += Int(stamp.size); values.append(value)
        }
        return values
    }

    func pendingAttempt(audioURL: URL) throws -> Attempt? {
        try withStoreLock {
            let source = canonicalAudio(audioURL)
            return try attemptsForAudioUnlocked(source).pending
        }
    }

    /// A finite per-recording selection for hydration. It retains at most one
    /// pending and one completed manifest, never all historical attempts.
    func latestCompleted(audioURL: URL) throws -> Attempt? {
        try withStoreLock { try attemptsForAudioUnlocked(canonicalAudio(audioURL)).completed }
    }

    struct ManagedFinal: Sendable {
        let transcript: RichTranscript?
        let fallbackText: String?
        let matchesReceipt: Bool
        let authority: [RecordingDeletionAuthority.Item]
        var hasFinal: Bool { transcript != nil || fallbackText != nil }
        func validateAuthority() throws {
            for item in authority {
                try LiveSessionArtifactStore.requireSafeParents(item.url)
                guard try RecordingDeletionAuthority.Stamp.read(item.url) == item.stamp else { throw LiveArtifactError.wrongOwner }
            }
        }
    }

    /// Read only the final facts used by chat. Voice embeddings, edit tokens and
    /// original-text copies are omitted before decoding/retention. The caller
    /// holds a separate inspection lease through the actual actor return.
    func managedFinal(audioURL: URL, identity: LiveSessionIdentity, nonpersistingReplacement: Bool = false) throws -> ManagedFinal? {
        try withStoreLock {
            let audio = canonicalAudio(audioURL)
            let attempts = try attemptsForAudioUnlocked(audio)
            guard attempts.pending == nil else { throw StoreError.alreadyPending }
            var targets: [String: Fingerprint]?
            if let receipt = attempts.completed {
                let request = try JSONDecoder().decode(ReprocessingRequest.self, from: receipt.configuration)
                if let managed = request.liveSessionIdentity {
                    guard managed == identity, request.recordingID == identity.recordingID else { throw StoreError.invalidManifest }
                    try validateSource(receipt)
                    guard let published = receipt.publishedFingerprints else { throw StoreError.invalidManifest }
                    targets = published
                } else if !nonpersistingReplacement { return nil }
            } else if !nonpersistingReplacement { return nil }
            let source = try RecordingDeletionAuthority(audioURL: audio, expectedRecordingID: identity.recordingID)
            let rawURL = sidecar(audio, "transcript.json"), richURL = sidecar(audio, "richtranscript.json")
            let authority = [source.audio, source.metadata, try .init(rawURL), try .init(richURL)]
            struct Raw: Decodable {
                struct Segment: Decodable { let text: String }
                let text: String
                let segments: [Segment]
            }
            struct Rich: Decodable {
                struct Segment: Decodable {
                    let id: UUID
                    let start: Double
                    let end: Double
                    let text: String
                    let speakerId: String?
                }
                let version: Int?
                let segments: [Segment]
                let speakerLabels: [SpeakerLabel]?
            }
            let raw: Raw? = try RecordingDeletionAuthority.readHeader(rawURL, maximumBytes: 3 * 1_024 * 1_024, tokenLimit: 1_048_576)
            let rich: Rich? = try RecordingDeletionAuthority.readHeader(richURL, maximumBytes: 3 * 1_024 * 1_024, tokenLimit: 1_048_576)
            guard raw?.segments.count ?? 0 <= 100_000, rich?.segments.count ?? 0 <= 100_000,
                  rich?.version ?? RichTranscript.currentVersion == RichTranscript.currentVersion else { throw LiveArtifactError.corruptArtifact }
            var fallback: String?
            if (rich?.segments.isEmpty ?? true), let raw {
                var text = raw.text
                if text.isEmpty {
                    for segment in raw.segments {
                        guard text.utf8.count + segment.text.utf8.count + 1 <= LiveRecordingArtifactOwner.finalPublicationLimit / 6 else {
                            throw LiveArtifactError.artifactTooLarge
                        }
                        if !text.isEmpty { text.append("\n") }; text.append(segment.text)
                    }
                }
                guard text.utf8.count <= LiveRecordingArtifactOwner.finalPublicationLimit / 6 else { throw LiveArtifactError.artifactTooLarge }
                fallback = text
            }
            let transcript = rich.map { value in RichTranscript(segments: value.segments.map {
                .init(id: $0.id, start: $0.start, end: $0.end, text: $0.text, originalText: $0.text, speakerId: $0.speakerId)
            }, speakerLabels: value.speakerLabels ?? []) }
            _ = try LiveAppFinalPublication.bounded(id: UUID(), revision: 1, transcript: transcript ?? .init(segments: []),
                fallbackText: fallback, limit: LiveRecordingArtifactOwner.finalPublicationLimit)
            // A final-only RAM replacement has no durable capture ledger to
            // reconcile. Its exact terminal phase authorizes a fresh projection
            // of the preserved current canonical result, also after Discard.
            let matches = try nonpersistingReplacement || (fingerprint(at: rawURL) == targets?["transcript.json"] && fingerprint(at: richURL) == targets?["richtranscript.json"])
            let result = ManagedFinal(transcript: transcript, fallbackText: fallback, matchesReceipt: matches, authority: authority)
            try result.validateAuthority()
            return result
        }
    }

    func qualifyManaged(attemptID: UUID, expectedConfiguration: Data, configuration: Data,
                        identity: LiveSessionIdentity, authority: RecordingDeletionAuthority) throws {
        try withStoreLock {
            var attempt = try mutableAttempt(attemptID)
            try attempt.authority?.validateExact()
            guard attempt.configuration == expectedConfiguration,
                  try RecordingDeletionAuthority.canonical(attempt.audioURL) == authority.audioURL,
                  authority.recordingID == identity.recordingID else {
                throw StoreError.changedInput("Reprocessing configuration")
            }
            try authority.validateExact()
            try validateSource(attempt)
            try validateResults(attempt, expected: attempt.resultFingerprints)
            let request = try JSONDecoder().decode(ReprocessingRequest.self, from: configuration)
            guard request.recordingID == identity.recordingID, request.liveSessionIdentity == identity else {
                throw StoreError.invalidManifest
            }
            try RecordingResultMutation.claim(audioURL: attempt.audioURL, attemptID: attempt.id)
            attempt.configuration = configuration
            // Only a legacy nil journal gains authority. A stopped managed
            // journal cannot inherit byte-identical replacement files.
            attempt.authority = attempt.authority ?? authority
            try authority.validateExact()
            try save(&attempt)
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
            try attempt.authority?.validateExact()
            try validateSource(attempt)
            try validateResults(attempt, expected: attempt.resultFingerprints)
        }
    }

    func commit(attemptID: UUID) async throws {
        await preparationStage(.publicationAdmission)
        try withStoreLock {
            var attempt = try readAttempt(attemptID)
            if attempt.status == .completed { return }
            try attempt.authority?.validateExact()
            if attempt.status != .publishing {
                try validateSource(attempt)
                try validateResults(attempt, expected: attempt.resultFingerprints)
                guard !attempt.stagedFingerprints.isEmpty else { throw StoreError.invalidStatus }
                // Verify every candidate BEFORE committing the journal, so corruption
                // can never strand a partially replaced set that cannot roll forward.
                for (suffix, expected) in attempt.stagedFingerprints {
                    try validatePayload(attempt.id, "staged", suffix, expected: expected)
                }
                attempt.publishedFingerprints = attempt.resultFingerprints.merging(attempt.stagedFingerprints) { _, new in new }
                attempt.status = .publishing
                try attempt.authority?.validateExact()
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
            let attempts = try attemptsForAudioUnlocked(source)
            return attempts.pending == nil && attempts.completed?.publishedFingerprints != nil
        }
    }

    func restore(audioURL: URL, managedIdentity: LiveSessionIdentity? = nil, configuration: Data? = nil) throws {
        try withStoreLock {
            var restoration = try prepareRestorationUnlocked(audioURL: audioURL, managedIdentity: managedIdentity, configuration: configuration)
            try finishPublication(&restoration)
        }
    }

    /// Publish the restoration journal and retain its claim, but perform no
    /// canonical mutation until the manager has retired the original generation.
    func prepareRestoration(audioURL: URL, managedIdentity: LiveSessionIdentity? = nil,
                            configuration: Data? = nil, preserveChat: Bool = false,
                            authority: RecordingDeletionAuthority? = nil) async throws -> Attempt {
        let attempt = try withStoreLock { try prepareRestorationUnlocked(audioURL: audioURL, managedIdentity: managedIdentity,
            configuration: configuration, preserveChat: preserveChat, authority: authority) }
        await preparationStage(.restorationPrepared)
        return attempt
    }

    private func prepareRestorationUnlocked(audioURL: URL, managedIdentity: LiveSessionIdentity?,
                                           configuration: Data?, preserveChat: Bool = false,
                                           authority: RecordingDeletionAuthority? = nil) throws -> Attempt {
            try authority?.validateExact()
            let keepChat = managedIdentity != nil || preserveChat
            let source = canonicalAudio(audioURL)
            let attempts = try attemptsForAudioUnlocked(source)
            guard attempts.pending == nil else { throw StoreError.alreadyPending }
            guard let previous = attempts.completed,
                  let expected = previous.publishedFingerprints else { throw StoreError.noPreviousResults }
            if let managedIdentity {
                let request = try JSONDecoder().decode(ReprocessingRequest.self, from: configuration ?? previous.configuration)
                guard request.liveSessionIdentity == managedIdentity,
                      request.recordingID == managedIdentity.recordingID else { throw StoreError.invalidManifest }
                struct ChatOwner: Decodable { let identity: LiveSessionIdentity? }
                let chat: ChatOwner? = try RecordingDeletionAuthority.readHeader(sidecar(source, "chat.json"),
                    maximumBytes: LiveRecordingArtifactOwner.chatHistoryLimit, tokenLimit: 262_144)
                guard chat == nil || chat?.identity == managedIdentity else { throw StoreError.invalidManifest }
            }
            try validateSource(previous)
            // Chat and spoken summaries can legitimately be recreated after a
            // successful commit. Restore invalidates them for the restored text;
            // they neither block restoring results nor return from old backups.
            try validateResults(previous, expected: expected, excluding: Self.derivativeSuffixes)
            // Verify immutable originals before the new claim; subsequent copies
            // stream fixed chunks and verify the same frozen content.
            for suffix in Self.allowedSuffixes.subtracting(Self.derivativeSuffixes) {
                guard let fingerprint = previous.resultFingerprints[suffix] else { throw StoreError.invalidManifest }
                try validatePayload(previous.id, "original", suffix, expected: fingerprint)
            }
            var restoreTargets = previous.resultFingerprints
            for suffix in Self.derivativeSuffixes { restoreTargets[suffix] = .missing }
            // Do not advertise a queued processing attempt during restore staging:
            // interruption before the journal is durable leaves canonical files intact.
            var restoration = try prepareUnlocked(audioURL: source, configuration: configuration ?? previous.configuration, persist: false, authority: authority)
            if keepChat { restoreTargets["chat.json"] = restoration.resultFingerprints["chat.json"] }
            var journalPublished = false
            do {
                for suffix in Self.allowedSuffixes {
                    if keepChat, suffix == "chat.json" {
                        // The current owned conversation was frozen by the new
                        // claim. Preserve it, including answers added since commit.
                        continue
                    }
                    if restoreTargets[suffix]?.exists == true {
                        try copyPrivate(from: payloadURL(previous.id, "original", suffix),
                            to: payloadURL(restoration.id, "staged", suffix), expected: restoreTargets[suffix]!)
                    }
                    restoration.stagedFingerprints[suffix] = restoreTargets[suffix]
                }
                restoration.publishedFingerprints = restoreTargets
                restoration.status = .publishing
                try validateSource(restoration)
                try validateResults(restoration, expected: restoration.resultFingerprints)
                try restoration.authority?.validateExact()
                try save(&restoration)
                try synchronizeDirectory(root)
                journalPublished = true
                return restoration
            } catch {
                if !journalPublished {
                    try? fm.removeItem(at: directory(restoration.id))
                    RecordingResultMutation.release(audioURL: source, attemptID: restoration.id)
                }
                throw error
            }
    }

    func discard(attemptID: UUID) throws {
        try withStoreLock {
            let attempt = try readAttempt(attemptID)
            try attempt.authority?.validateExact()
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
    func purgeCompletedForMissingAudio(protectedBases: Set<String> = [], bounded: Bool = false) throws -> Int {
        try withStoreLock {
            let attempts = try bounded ? discoverRetentionUnlocked() : discoverUnlocked()
            let pendingSources = Set(attempts.filter { $0.status != .completed }.map(\.audioURL))
            let expired = try attempts.filter { attempt in
                guard attempt.status == .completed, !pendingSources.contains(attempt.audioURL),
                      !RetentionCleanup.isProtectedByQueue(attempt.audioURL, queuedBases: protectedBases) else { return false }
                if bounded { return try !RecordingDeletionAuthority.regularFileExistsInAvailableParent(attempt.audioURL) }
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
    func purgeCompletedTranscriptHistory(olderThan cutoff: Date, in folders: [URL], protectedBases: Set<String> = [], bounded: Bool = false) throws -> Int {
        try withStoreLock {
            let selectedFolders = folders.filter(\.isFileURL).map { canonicalAudio($0).pathComponents }
            guard !selectedFolders.isEmpty else { return 0 }
            let attempts = try bounded ? discoverRetentionUnlocked() : discoverUnlocked()
            let pendingSources = Set(attempts.filter { $0.status != .completed }.map(\.audioURL))
            let expired = attempts.filter { attempt in
                guard attempt.status == .completed, attempt.updatedAt <= cutoff,
                      !RetentionCleanup.isProtectedByQueue(attempt.audioURL, queuedBases: protectedBases),
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

    private func prepareUnlocked(audioURL: URL, configuration: Data, persist: Bool = true,
                                 authority: RecordingDeletionAuthority? = nil) throws -> Attempt {
        guard configuration.count <= 512 * 1_024 else { throw LiveArtifactError.artifactTooLarge }
        let source = canonicalAudio(audioURL)
        try authority?.validateExact()
        if let authority, canonicalAudio(authority.audioURL) != source { throw StoreError.invalidManifest }
        guard source.isFileURL else { throw StoreError.missingAudio }
        guard try attemptsForAudioUnlocked(source).pending == nil else {
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
                    try copyPrivate(from: url, to: payloadURL(id, "original", suffix), expected: current)
                }
            }
            var attempt = Attempt(id: id, audioURL: source, configuration: configuration,
                                  createdAt: Date(), updatedAt: Date(), status: .queued,
                                  completedStages: [], progress: 0, message: nil,
                                  sourceFingerprint: sourceFingerprint, resultFingerprints: snapshots,
                                  stagedFingerprints: [:], publishedFingerprints: nil, authority: authority)
            try validateSource(attempt)
            try validateResults(attempt, expected: snapshots)
            try authority?.validateExact()
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
        try attempt.authority?.validateExact()
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
            try validatePayload(attempt.id, "staged", suffix, expected: expected)
        }
        for suffix in attempt.stagedFingerprints.keys.sorted() {
            try attempt.authority?.validateExact()
            guard let expected = target[suffix] else { throw StoreError.invalidManifest }
            let url = sidecar(attempt.audioURL, suffix)
            let current = try fingerprint(at: url)
            if current == expected { continue }
            guard current == attempt.resultFingerprints[suffix] else { throw StoreError.changedInput(url.lastPathComponent) }
            if expected.exists {
                try copyPrivate(from: payloadURL(attempt.id, "staged", suffix), to: url, expected: expected, publicationAuthority: attempt.authority)
            } else {
                try fm.removeItem(at: url)
                try synchronizeDirectory(url.deletingLastPathComponent())
            }
            try publicationStep?(suffix)
        }
        try validateSource(attempt)
        try validateResults(attempt, expected: target)
        try attempt.authority?.validateExact()
        attempt.status = .completed
        attempt.progress = 1
        attempt.message = nil
        try save(&attempt)
        RecordingResultMutation.release(audioURL: attempt.audioURL, attemptID: attempt.id)
        // Keep exactly one complete prior set. Cleanup happens after completion is
        // durable, so crashing here can at worst retain an extra backup temporarily.
        try RecordingDeletionAuthority.scanChildren(root, includeHidden: true) { url in
            guard let id = UUID(uuidString: url.lastPathComponent), id != attempt.id else { return }
            guard let header: AttemptHeader = try RecordingDeletionAuthority.readHeader(url.appendingPathComponent("manifest.json"),
                maximumBytes: 1_024 * 1_024, tokenLimit: 262_144) else { return }
            guard header.id == id else { throw StoreError.invalidManifest }
            guard header.audioURL == attempt.audioURL, header.status == .completed else { return }
            let old = try readAttempt(id)
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
        guard let attempt: Attempt = try RecordingDeletionAuthority.readHeader(url,
            maximumBytes: 1_024 * 1_024, tokenLimit: 262_144) else { throw StoreError.invalidManifest }
        guard attempt.id == id, attempt.audioURL.isFileURL,
              attempt.audioURL == canonicalAudio(attempt.audioURL),
              Set(attempt.resultFingerprints.keys) == Self.allowedSuffixes,
              Set(attempt.stagedFingerprints.keys).isSubset(of: Self.allowedSuffixes),
              attempt.publishedFingerprints.map({ Set($0.keys) == Self.allowedSuffixes }) ?? true,
              attempt.status != .publishing || attempt.publishedFingerprints != nil else {
            throw StoreError.invalidManifest
        }
        if let authority = attempt.authority {
            guard try RecordingDeletionAuthority.canonical(authority.audioURL) == RecordingDeletionAuthority.canonical(attempt.audioURL),
                  try RecordingDeletionAuthority.canonical(sidecar(attempt.audioURL, "json")) == authority.metadata.url,
                  !authority.audio.directory, !authority.metadata.directory else { throw StoreError.invalidManifest }
        }
        return attempt
    }

    private struct AttemptHeader: Decodable {
        let id: UUID
        let audioURL: URL
        let status: Status
        let createdAt: Date
    }
    private func attemptsForAudioUnlocked(_ audio: URL) throws -> (pending: Attempt?, completed: Attempt?) {
        var pending: Attempt?, completed: Attempt?
        try RecordingDeletionAuthority.scanChildren(root, includeHidden: true) { url in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return }
            try requireDirectory(url)
            guard let header: AttemptHeader = try RecordingDeletionAuthority.readHeader(url.appendingPathComponent("manifest.json"),
                maximumBytes: 1_024 * 1_024, tokenLimit: 262_144) else { return }
            guard header.id == id else { throw StoreError.invalidManifest }
            guard header.audioURL == audio else { return }
            if header.status == .completed {
                if completed == nil || header.createdAt > completed!.createdAt { completed = try readAttempt(id) }
            } else {
                guard pending == nil else { throw StoreError.alreadyPending }
                pending = try readAttempt(id)
                try RecordingResultMutation.claim(audioURL: audio, attemptID: id)
            }
        }
        return (pending, completed)
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
        let bytes = try LiveArtifactEncoding.encode(attempt, limit: 1_024 * 1_024)
        try writePrivate(bytes, to: directory(attempt.id).appendingPathComponent("manifest.json"))
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

    private func validatePayload(_ id: UUID, _ kind: String, _ suffix: String, expected: Fingerprint) throws {
        guard expected.exists else { return }
        let url = payloadURL(id, kind, suffix)
        try requireDirectory(url.deletingLastPathComponent())
        guard try fingerprint(at: url) == expected else { throw StoreError.invalidManifest }
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

    /// Retain one fixed chunk for backups and publication, including spoken
    /// audio. Verify content and physical identity before the atomic rename.
    private func copyPrivate(from source: URL, to target: URL, expected: Fingerprint,
                             publicationAuthority: RecordingDeletionAuthority? = nil) throws {
        try requireDirectory(target.deletingLastPathComponent())
        try requireRegularOrMissing(target)
        guard expected.exists, let stamp = try RecordingDeletionAuthority.Stamp.read(source),
              stamp.size >= 0, UInt64(stamp.size) == expected.byteCount else { throw StoreError.invalidManifest }
        let inputFD = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard inputFD >= 0 else { throw StoreError.unsafeFile(source.lastPathComponent) }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
        defer { try? input.close() }
        let temp = target.deletingLastPathComponent().appendingPathComponent(".reprocessing-\(UUID().uuidString)")
        let outputFD = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard outputFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close(); try? fm.removeItem(at: temp) }
        var hash = SHA256(), count: UInt64 = 0
        while let chunk = try input.read(upToCount: 512 * 1_024), !chunk.isEmpty {
            guard count <= expected.byteCount, UInt64(chunk.count) <= expected.byteCount - count else {
                throw StoreError.changedInput(source.lastPathComponent)
            }
            hash.update(data: chunk); count += UInt64(chunk.count)
            try output.write(contentsOf: chunk)
        }
        let actual = Fingerprint(exists: true, byteCount: count,
            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
        guard actual == expected, try RecordingDeletionAuthority.Stamp.read(source) == stamp else {
            throw StoreError.changedInput(source.lastPathComponent)
        }
        try output.synchronize()
        try publicationAuthority?.validateExact()
        guard rename(temp.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try synchronizeDirectory(target.deletingLastPathComponent())
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
    /// Live ledgers share reprocessing admission without changing the persisted
    /// attempt inventory or making old capture evidence a replacement result.
    private static let guardedSuffixes = ReprocessingStore.allowedSuffixes.union(["live-transcript.json", "live-binding.json"])
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
            if let suffix = guardedSuffixes.first(where: { path.hasSuffix("." + $0) }),
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

    static func withDeletion<T>(of audioURL: URL, _ body: () throws -> T) throws -> T {
        try withTransaction {
            guard state.owners[basePath(audioURL)] == nil else { throw ReprocessingStore.StoreError.alreadyPending }
            return try body()
        }
    }

    /// A pending replacement may inspect its own original managed ledger. This
    /// grants no write/deletion authority and never bypasses another attempt.
    static func withClaimedInspection<T>(of audioURL: URL, attemptID: UUID, _ body: () throws -> T) throws -> T {
        try withTransaction {
            guard state.owners[basePath(audioURL)] == attemptID else { throw ReprocessingStore.StoreError.alreadyPending }
            return try body()
        }
    }

    private static func basePath(_ audioURL: URL) -> String {
        audioURL.standardizedFileURL.resolvingSymlinksInPath().deletingPathExtension().path
    }
}
