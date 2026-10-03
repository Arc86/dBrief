import CryptoKit
import Darwin
import Foundation
import dBriefWire

enum LiveArtifactStage: Sendable {
    case historyLoad
    case sourceChat, sourceTranscript, journalPrepared, targetChat, targetTranscript, journalCommitted
    case sourceCleanup, deletionIntent, deletionCleanup
}
enum LiveArtifactError: Error, Equatable, LocalizedError {
    case staleRevision, revisionConflict, bindingPending, deleted, queueFull, artifactTooLarge
    case wrongOwner, unsupportedVersion, corruptArtifact, unsafePath, verificationFailed
    var errorDescription: String? {
        switch self {
        case .staleRevision: "A newer live history revision has already been accepted."
        case .revisionConflict: "The saved history differs at the same revision. Both copies have been kept."
        case .bindingPending: "Live history binding needs a retry. New history remains in memory."
        case .deleted: "This live session has been deleted."
        case .queueFull: "Live history is waiting for storage. Retry after the current save finishes."
        case .artifactTooLarge: "Live history exceeds the supported artifact size."
        case .wrongOwner: "The history or recording belongs to another session."
        case .unsupportedVersion: "This history uses an unsupported version and has been kept."
        case .corruptArtifact: "The history could not be read and has been kept."
        case .unsafePath: "The history path is unavailable or unsafe."
        case .verificationFailed: "The history save could not be verified."
        }
    }
}

/// One admitted pump serializes physical mutations across suspension points.
/// Each write interval retains two latest-value slots, never every snapshot.
/// Controls are separate barriers with reserved admission. Accepted memory and
/// durable revisions are reported separately; failure never pretends to save.
actor LiveSessionArtifactStore {
    /// Content retirement follows this verified commit, independently of the
    /// cleanup outcome. Only this writer can construct the cleanup authority.
    struct DeletionReceipt: Sendable {
        let identity: LiveSessionIdentity
        fileprivate let intentDigest: String
        fileprivate let intentByteCount: Int
    }
    struct Restored: Sendable {
        let chat: ChatHistory?
        let transcriptValue: LiveTranscriptArtifactCodec.Value?
        var transcript: LiveTranscriptCheckpoint? { transcriptValue?.native }
        var appTranscript: LiveTranscriptArtifact? { transcriptValue?.app }
        let audioURL: URL?
        let deleted: Bool
    }
    struct Status: Sendable {
        let acceptedChatRevision: UInt64
        let durableChatRevision: UInt64
        let acceptedTranscriptRevision: UInt64
        let durableTranscriptRevision: UInt64
        let failure: String?
        let admittedWriteWaiters: Int
        let admittedControls: Int
        let queuedEncodedBytes: Int
        let retainedPayloads: Int
        let audioURL: URL?
        let deleted: Bool
    }
    enum Kind: String, Codable, Sendable { case chat, transcript }
    private struct Payload: Sendable {
        let kind: Kind
        let revision: UInt64
        let data: Data // Canonical, unbound content; target headers are derived.
        let fingerprint: Fingerprint
        init(kind: Kind, revision: UInt64, data: Data) {
            self.kind = kind; self.revision = revision; self.data = data
            fingerprint = .init(revision: revision, count: data.count, sha256: Self.digest(data))
        }
        static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    }
    private struct Fingerprint: Codable, Sendable, Equatable {
        let revision: UInt64
        let count: Int
        let sha256: String
    }
    /// Nil vectors explicitly mean absence. Payload digests exclude only the
    /// binding generation, so copied content is checked without trusting a rev.
    private struct Journal: Codable, Sendable, Equatable {
        enum Phase: String, Codable, Sendable { case prepared, committed }
        let version: Int
        let identity: LiveSessionIdentity
        let generation: UUID
        let audioURL: URL
        let chat: Fingerprint?
        let transcript: Fingerprint?
        var phase: Phase
    }
    private struct Deletion: Codable, Sendable {
        let version: Int
        let identity: LiveSessionIdentity
        let audioURL: URL?
        let generation: UUID?
        let intentID: UUID?
        var cleanupComplete: Bool?
    }
    private enum Outcome { case restored(Restored), deletion(DeletionReceipt) }
    private final class Batch {
        var chat: Payload?, transcript: Payload?
        var waiters: [CheckedContinuation<Outcome?, any Error>] = []
    }
    private enum Operation {
        case writes(Batch), clear(Payload), bind(URL), recover, retry(chat: Payload?, transcript: Payload?), delete
        case deletionIntent, deletionCleanup(DeletionReceipt)
        var isControl: Bool { if case .writes = self { false } else { true } }
    }
    private struct Job {
        let operation: Operation
        let continuation: CheckedContinuation<Outcome?, any Error>?
    }
    private static let maxArtifactBytes = 32 * 1_024 * 1_024
    private static let maxQueuedBytes = 8 * 1_024 * 1_024
    let identity: LiveSessionIdentity
    let rootURL: URL
    var sessionURL: URL { rootURL.appendingPathComponent(identity.captureSessionID.uuidString, isDirectory: true) }
    private var journalURL: URL { sessionURL.appendingPathComponent("binding.json") }
    private var deletionURL: URL { sessionURL.appendingPathComponent("deletion.json") }
    private let beforeStage: @Sendable (LiveArtifactStage) async throws -> Void
    private let validity: RecordingDerivativeValidity
    private let payloadReservation: LiveRecordingPayloadBudget.Lease?
    private let payloadLimit: Int
    private let queueByteLimit: Int
    private let chatPayloadLimit: Int
    private let fm = FileManager.default
    private var queue: [Job] = []
    private var inFlight: Job?
    private var pumping = false
    private var acceptedChat: Payload?, acceptedTranscript: Payload?
    private var durableChat: Payload?, durableTranscript: Payload?
    private var journal: Journal?
    private var isDeleted = false
    private var failure: String?

    init(identity: LiveSessionIdentity, rootURL: URL = AppSupportPaths.subdirectory("LiveSessions"),
         validity: RecordingDerivativeValidity = RecordingDerivativeValidity(),
         payloadReservation: LiveRecordingPayloadBudget.Lease? = nil,
         payloadLimit: Int = maxArtifactBytes, queueByteLimit: Int = maxQueuedBytes,
         chatPayloadLimit: Int = maxArtifactBytes,
         beforeStage: @escaping @Sendable (LiveArtifactStage) async throws -> Void = { _ in }) {
        self.identity = identity; self.rootURL = rootURL.standardizedFileURL; self.beforeStage = beforeStage
        self.validity = validity
        self.payloadReservation = payloadReservation
        self.payloadLimit = min(Self.maxArtifactBytes, max(1, payloadLimit))
        self.chatPayloadLimit = min(self.payloadLimit, max(1, chatPayloadLimit))
        self.queueByteLimit = min(Self.maxQueuedBytes, max(1, queueByteLimit))
    }

    func saveChat(_ history: ChatHistory, revision: UInt64) async throws {
        var history = history
        try history.validateVersion()
        guard history.identity == nil || history.identity == identity else { throw LiveArtifactError.wrongOwner }
        history.version = ChatHistory.currentVersion; history.identity = identity; history.revision = revision; history.bindingGeneration = nil
        try await submitWrite(.init(kind: .chat, revision: revision, data: LiveArtifactEncoding.encode(history, limit: chatPayloadLimit)))
    }
    func saveTranscript(_ checkpoint: LiveTranscriptCheckpoint) async throws {
        try checkpoint.validate()
        guard checkpoint.identity == identity else { throw LiveArtifactError.wrongOwner }
        var copy = checkpoint; copy.bindingGeneration = nil
        try await submitWrite(.init(kind: .transcript, revision: copy.revision, data: encode(copy)))
    }
    func saveTranscript(_ artifact: LiveTranscriptArtifact) async throws {
        try artifact.validate()
        guard artifact.identity == identity else { throw LiveArtifactError.wrongOwner }
        let bytes = try LiveTranscriptArtifactCodec.Value.app(artifact).encoded(generation: nil, limit: payloadLimit)
        try await submitWrite(.init(kind: .transcript, revision: artifact.revision, data: bytes))
    }
    func clearChat(revision: UInt64) async throws {
        let history = ChatHistory(messages: [], identity: identity, revision: revision)
        let payload = Payload(kind: .chat, revision: revision, data: try encode(history))
        try validateAdmission(payload, control: true)
        acceptedChat = payload
        _ = try await submitControl(.clear(payload))
    }
    func bind(to audioURL: URL) async throws { _ = try await submitControl(.bind(audioURL.standardizedFileURL)) }
    func recover() async throws -> Restored {
        guard case .restored(let restored) = try await submitControl(.recover, allowingDeleted: true) else { throw LiveArtifactError.verificationFailed }
        return restored
    }
    func retry() async throws {
        // Capture this interval before its first suspension. Future accepted
        // slots may belong after a queued Clear/Bind/Delete barrier.
        let chat = acceptedChat.flatMap { $0.fingerprint == durableChat?.fingerprint ? nil : $0 }
        let transcript = acceptedTranscript.flatMap { $0.fingerprint == durableTranscript?.fingerprint ? nil : $0 }
        _ = try await submitControl(.retry(chat: chat, transcript: transcript))
    }
    func recordDeletionIntent() async throws { _ = try await submitControl(.delete, allowingDeleted: true) }
    func commitDeletionIntent() async throws -> DeletionReceipt {
        guard case .deletion(let receipt) = try await submitControl(.deletionIntent, allowingDeleted: true) else { throw LiveArtifactError.verificationFailed }
        return receipt
    }
    func cleanupDeletion(_ receipt: DeletionReceipt) async throws {
        _ = try await submitControl(.deletionCleanup(receipt), allowingDeleted: true, allowingRetiredCleanup: true)
    }

    func status() -> Status {
        let retained = retainedPayloads()
        return .init(acceptedChatRevision: acceptedChat?.revision ?? 0, durableChatRevision: durableChat?.revision ?? 0,
            acceptedTranscriptRevision: acceptedTranscript?.revision ?? 0, durableTranscriptRevision: durableTranscript?.revision ?? 0,
            failure: failure, admittedWriteWaiters: writeWaiters, admittedControls: controls,
            queuedEncodedBytes: retained.reduce(0) { $0 + $1.data.count }, retainedPayloads: retained.count,
            audioURL: journal?.phase == .committed ? journal?.audioURL : nil, deleted: isDeleted)
    }
    private var jobs: [Job] { (inFlight.map { [$0] } ?? []) + queue }
    private var writeWaiters: Int { jobs.reduce(0) { n, job in if case .writes(let batch) = job.operation { n + batch.waiters.count } else { n } } }
    private var controls: Int { jobs.filter { $0.operation.isControl }.count }
    private func retainedPayloads(replacing payload: Payload? = nil, control: Bool = false) -> [Payload] {
        var values: [Payload] = []
        for (index, job) in jobs.enumerated() {
            switch job.operation {
            case .writes(let batch):
                let replaceTail = !control && payload != nil && !queue.isEmpty && index == jobs.count - 1
                if let chat = batch.chat, !replaceTail || payload?.kind != .chat { values.append(chat) }
                if let transcript = batch.transcript, !replaceTail || payload?.kind != .transcript { values.append(transcript) }
            case .clear(let value): values.append(value)
            case .retry(let chat, let transcript): values.append(contentsOf: [chat, transcript].compactMap { $0 })
            default: break
            }
        }
        // Failed writes remain in the latest dirty slots for an explicit retry.
        for value in [acceptedChat, acceptedTranscript].compactMap({ $0 }) {
            let durable = value.kind == .chat ? durableChat : durableTranscript
            if durable?.fingerprint != value.fingerprint, payload?.kind != value.kind { values.append(value) }
        }
        if let payload { values.append(payload) }
        var seen = Set<String>()
        return values.filter { seen.insert("\($0.kind.rawValue):\($0.fingerprint.sha256)").inserted }
    }
    private func validateAdmission(_ payload: Payload, control: Bool) throws {
        try validity.withValidResult {}
        guard !isDeleted else { throw LiveArtifactError.deleted }
        guard payload.data.count <= payloadLimit else { throw LiveArtifactError.artifactTooLarge }
        let prior = payload.kind == .chat ? acceptedChat : acceptedTranscript
        if let prior {
            guard payload.revision >= prior.revision else { throw LiveArtifactError.staleRevision }
            guard payload.revision != prior.revision || payload.data == prior.data else { throw LiveArtifactError.revisionConflict }
        }
        guard (control ? controls < 8 : writeWaiters < 64),
              retainedPayloads(replacing: payload, control: control).reduce(0, { $0 + $1.data.count }) <= queueByteLimit else {
            throw LiveArtifactError.queueFull
        }
    }
    private func submitWrite(_ payload: Payload) async throws {
        try validateAdmission(payload, control: false)
        if payload.kind == .chat { acceptedChat = payload } else { acceptedTranscript = payload }
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Outcome?, any Error>) in
            if let tail = queue.last, case .writes(let batch) = tail.operation {
                if payload.kind == .chat { batch.chat = payload } else { batch.transcript = payload }
                batch.waiters.append(continuation)
            } else {
                let batch = Batch(); batch.waiters = [continuation]
                if payload.kind == .chat { batch.chat = payload } else { batch.transcript = payload }
                queue.append(.init(operation: .writes(batch), continuation: nil))
            }
            startPump()
        }
    }
    private func submitControl(_ operation: Operation, allowingDeleted: Bool = false, allowingRetiredCleanup: Bool = false) async throws -> Outcome? {
        if !allowingRetiredCleanup { try validity.withValidResult {} }
        guard allowingDeleted || !isDeleted else { throw LiveArtifactError.deleted }
        guard controls < 8, retainedPayloads().reduce(0, { $0 + $1.data.count }) <= queueByteLimit else { throw LiveArtifactError.queueFull }
        return try await withCheckedThrowingContinuation { continuation in
            queue.append(.init(operation: operation, continuation: continuation)); startPump()
        }
    }
    private func startPump() {
        guard !pumping else { return }
        pumping = true
        Task { await self.pump() }
    }
    private func pump() async {
        while !queue.isEmpty {
            let job = queue.removeFirst(); inFlight = job
            do {
                let result = try await execute(job.operation)
                if durableChat?.fingerprint == acceptedChat?.fingerprint && durableTranscript?.fingerprint == acceptedTranscript?.fingerprint && journal?.phase != .prepared {
                    failure = nil
                }
                if case .writes(let batch) = job.operation { for waiter in batch.waiters { waiter.resume(returning: nil) } }
                job.continuation?.resume(returning: result)
            } catch {
                failure = error.localizedDescription
                if case .writes(let batch) = job.operation { for waiter in batch.waiters { waiter.resume(throwing: error) } }
                job.continuation?.resume(throwing: error)
            }
            inFlight = nil
        }
        pumping = false
    }
    private func execute(_ operation: Operation) async throws -> Outcome? {
        // A verified intent grants cleanup only; a retired token can never use
        // that authority to inspect/recover content or admit a new write.
        if case .deletionCleanup(let receipt) = operation {
            try await cleanupDeleted(receipt); return nil
        }
        if case .recover = operation { try await beforeStage(.historyLoad) }
        try inspectDisk()
        switch operation {
        case .delete:
            try await cleanupDeleted(commitIntent()); return nil
        case .deletionIntent:
            return .deletion(try await commitIntent())
        case .recover:
            if isDeleted {
                try await cleanupDeleted(currentDeletionReceipt())
                return .restored(.init(chat: nil, transcriptValue: nil, audioURL: nil, deleted: true))
            }
            if let journal { try await finishBinding(journal) }
            return .restored(try restoreDisk())
        default: guard !isDeleted else { throw LiveArtifactError.deleted }
        }
        switch operation {
        case .writes(let batch):
            if let transcript = batch.transcript { try await write(transcript) }
            if let chat = batch.chat { try await write(chat) }
        case .clear(let payload): try await write(payload)
        case .bind(let audio): try await beginBinding(audio)
        case .retry(let chat, let transcript):
            if let journal { try await finishBinding(journal) }
            if let transcript, durableTranscript?.fingerprint != transcript.fingerprint { try await write(transcript) }
            if let chat, durableChat?.fingerprint != chat.fingerprint { try await write(chat) }
        case .delete, .recover, .deletionIntent, .deletionCleanup: break
        }
        return nil
    }

    /// Re-read the ledger before every operation, including an old actor's late
    /// callback. A durable tombstone or another instance's binding wins routing.
    private func inspectDisk() throws {
        try derivativeTransaction { try inspectDiskWhileValid() }
    }
    /// Called with both the result mutation guard and the shared token held.
    private func inspectDiskWhileValid() throws {
        try requireSafeParents(sessionURL)
        if let bytes = try read(deletionURL) {
            let intent: Deletion = try decode(bytes)
            try validate(intent); isDeleted = true
        }
        guard !isDeleted else { return }
        if let bytes = try read(journalURL) {
            let value: Journal = try decode(bytes)
            try validate(value); journal = value
        }
        if let journal, journal.phase == .committed { try verifyBindingLedger(journal) }
        let generation = journal?.phase == .committed ? journal?.generation : nil
        for kind in [Kind.transcript, .chat] {
            let url = generation == nil ? sourceURL(kind) : targetURL(kind, audio: journal!.audioURL)
            if let payload = try readPayload(kind, from: url, generation: generation) { adoptDurable(payload) }
        }
    }
    private func derivativeTransaction<T>(_ body: () throws -> T) throws -> T {
        try RecordingResultMutation.withTransaction { try validity.withValidResult(body) }
    }
    private func adoptDurable(_ payload: Payload) {
        if payload.kind == .chat {
            durableChat = payload
            if acceptedChat == nil || acceptedChat!.revision < payload.revision { acceptedChat = payload }
        } else {
            durableTranscript = payload
            if acceptedTranscript == nil || acceptedTranscript!.revision < payload.revision { acceptedTranscript = payload }
        }
    }
    private func write(_ payload: Payload) async throws {
        guard journal?.phase != .prepared else { throw LiveArtifactError.bindingPending }
        let bound = journal?.phase == .committed
        let stage: LiveArtifactStage = payload.kind == .chat ? (bound ? .targetChat : .sourceChat) : (bound ? .targetTranscript : .sourceTranscript)
        try await beforeStage(stage)
        try derivativeTransaction {
            try inspectDiskWhileValid()
            guard !isDeleted else { throw LiveArtifactError.deleted }
            guard journal?.phase != .prepared else { throw LiveArtifactError.bindingPending }
            let generation = journal?.generation
            let url = journal.map { targetURL(payload.kind, audio: $0.audioURL) } ?? sourceURL(payload.kind)
            try RecordingResultMutation.withWrite(to: url) {
                if let journal { try requireOwner(journal.audioURL) }
                let old = try readPayload(payload.kind, from: url, generation: generation)
                if let old {
                    guard payload.revision >= old.revision else { throw LiveArtifactError.staleRevision }
                    guard payload.revision != old.revision || payload.data == old.data else { throw LiveArtifactError.revisionConflict }
                }
                try createSessionDirectory()
                let bytes = try boundBytes(payload, generation: generation)
                try writeVerified(bytes, to: url)
                adoptDurable(payload)
            }
        }
    }

    private func beginBinding(_ audio: URL) async throws {
        if let journal {
            guard journal.audioURL == audio else { throw LiveArtifactError.wrongOwner }
            try await finishBinding(journal); return
        }
        let prepared: Journal = try derivativeTransaction {
            try requireOwner(audio)
            let chat = try readPayload(.chat, from: sourceURL(.chat), generation: nil)
            let transcript = try readPayload(.transcript, from: sourceURL(.transcript), generation: nil)
            // Existing target content requires a matching binding generation;
            // a filename, legacy header or a new UUID never authorizes adoption.
            for kind in [Kind.chat, .transcript] where try read(targetURL(kind, audio: audio)) != nil { throw LiveArtifactError.wrongOwner }
            guard try read(bindingTarget(audio)) == nil else { throw LiveArtifactError.wrongOwner }
            return .init(version: 1, identity: identity, generation: UUID(), audioURL: audio,
                chat: chat?.fingerprint, transcript: transcript?.fingerprint, phase: .prepared)
        }
        try await beforeStage(.journalPrepared)
        try derivativeTransaction {
            try requireNotDeleted(); try requireOwner(audio)
            guard try read(journalURL) == nil else { throw LiveArtifactError.revisionConflict }
            try verifySources(prepared)
            try createSessionDirectory(); try writeVerified(encode(prepared), to: journalURL)
            journal = prepared
        }
        try await finishBinding(prepared)
    }
    private func finishBinding(_ original: Journal) async throws {
        var value = original
        if value.phase == .prepared {
            for kind in [Kind.transcript, .chat] {
                try await beforeStage(kind == .chat ? .targetChat : .targetTranscript)
                try derivativeTransaction {
                    try requireNotDeleted(); try requireOwner(value.audioURL)
                    try requireCurrentJournal(value); try verifySources(value)
                    let url = targetURL(kind, audio: value.audioURL)
                    try RecordingResultMutation.withWrite(to: url) {
                        let source = try readPayload(kind, from: sourceURL(kind), generation: nil)
                        let existing = try readPayload(kind, from: url, generation: value.generation)
                        guard existing == nil || existing?.fingerprint == source?.fingerprint else { throw LiveArtifactError.revisionConflict }
                        if let source { try writeVerified(boundBytes(source, generation: value.generation), to: url) }
                        else if existing != nil { throw LiveArtifactError.revisionConflict }
                    }
                }
            }
            try await beforeStage(.journalCommitted)
            try derivativeTransaction {
                try requireNotDeleted(); try requireOwner(value.audioURL); try requireCurrentJournal(value); try verifySources(value)
                try verifyTargets(value, allowingNewer: false)
                value.phase = .committed
                try RecordingResultMutation.withWrite(to: bindingTarget(value.audioURL)) {
                    if let bytes = try read(bindingTarget(value.audioURL)) {
                        let old: Journal = try decode(bytes)
                        try validate(old)
                        guard old == value else { throw LiveArtifactError.revisionConflict }
                    }
                    try writeVerified(encode(value), to: bindingTarget(value.audioURL))
                }
                // Routing changes at the durable commit, before any cleanup.
                try writeVerified(encode(value), to: journalURL)
                journal = value
            }
        }
        try await beforeStage(.sourceCleanup)
        try derivativeTransaction {
            try requireNotDeleted(); try requireOwner(value.audioURL); try requireCurrentJournal(value)
            try verifyBindingLedger(value)
            try verifyTargets(value, allowingNewer: true)
            for kind in [Kind.transcript, .chat] {
                if let source = try readPayload(kind, from: sourceURL(kind), generation: nil) {
                    guard source.fingerprint == vector(kind, value) else { throw LiveArtifactError.revisionConflict }
                    try removeVerified(sourceURL(kind))
                }
                if let target = try readPayload(kind, from: targetURL(kind, audio: value.audioURL), generation: value.generation) { adoptDurable(target) }
            }
        }
    }
    private func restoreDisk() throws -> Restored {
        try derivativeTransaction {
            try inspectDiskWhileValid()
            guard !isDeleted else { return .init(chat: nil, transcriptValue: nil, audioURL: nil, deleted: true) }
            let audio = journal?.phase == .committed ? journal?.audioURL : nil
            if let audio { try requireOwner(audio) }
            let generation = audio == nil ? nil : journal?.generation
            let chat = try readPayload(.chat, from: audio.map { targetURL(.chat, audio: $0) } ?? sourceURL(.chat), generation: generation)
            let transcript = try readPayload(.transcript, from: audio.map { targetURL(.transcript, audio: $0) } ?? sourceURL(.transcript), generation: generation)
            return .init(chat: try chat.map { try decode($0.data, as: ChatHistory.self).interruptedAfterRestart },
                transcriptValue: try transcript.map { try LiveTranscriptArtifactCodec.decode($0.data) }, audioURL: audio, deleted: false)
        }
    }

    private func commitIntent() async throws -> DeletionReceipt {
        if !isDeleted { try await beforeStage(.deletionIntent) }
        return try derivativeTransaction {
            try inspectDiskWhileValid()
            if isDeleted { return try currentDeletionReceipt() }
            if let journal { try requireOwner(journal.audioURL) }
            let intent = Deletion(version: 2, identity: identity, audioURL: journal?.audioURL, generation: journal?.generation,
                                  intentID: UUID(), cleanupComplete: false)
            try createSessionDirectory(); try writeVerified(encode(intent), to: deletionURL)
            isDeleted = true
            // Construct the verified receipt before releasing the token. A
            // concurrent retirement cannot turn a committed intent into a
            // reported admission failure in a second token transaction.
            return try currentDeletionReceipt()
        }
    }
    private func currentDeletionReceipt() throws -> DeletionReceipt {
        guard let bytes = try read(deletionURL) else { throw LiveArtifactError.verificationFailed }
        let intent: Deletion = try decode(bytes); try validate(intent)
        return try deletionReceipt(intent)
    }
    private func deletionReceipt(_ value: Deletion) throws -> DeletionReceipt {
        // Completion changes only cleanup state, never the immutable authority.
        // The original version1 intent's canonical shape remains compatible.
        var intent = value; intent.cleanupComplete = nil
        let bytes = try encode(intent)
        return .init(identity: intent.identity, intentDigest: Payload.digest(bytes), intentByteCount: bytes.count)
    }
    private func cleanupDeleted(_ receipt: DeletionReceipt) async throws {
        try await beforeStage(.deletionCleanup)
        try RecordingResultMutation.withTransaction {
            guard let bytes = try read(deletionURL) else { throw LiveArtifactError.verificationFailed }
            var intent: Deletion = try decode(bytes); try validate(intent)
            let current = try deletionReceipt(intent)
            guard receipt.identity == identity, current.intentDigest == receipt.intentDigest,
                  current.intentByteCount == receipt.intentByteCount else { throw LiveArtifactError.wrongOwner }
            if intent.cleanupComplete == true {
                try requireDeletedArtifactAbsence(intent)
                isDeleted = true; acceptedChat = nil; acceptedTranscript = nil; durableChat = nil; durableTranscript = nil
                return
            }
            if let audio = intent.audioURL { try requireOwner(audio) }
            for kind in [Kind.transcript, .chat] {
                if try readPayload(kind, from: sourceURL(kind), generation: nil) != nil { try removeVerified(sourceURL(kind)) }
            }
            if let audio = intent.audioURL, let generation = intent.generation {
                try requireOwner(audio)
                for kind in [Kind.transcript, .chat] {
                    let url = targetURL(kind, audio: audio)
                    try RecordingResultMutation.withWrite(to: url) {
                        if try readPayload(kind, from: url, generation: generation) != nil { try removeVerified(url) }
                    }
                }
                try RecordingResultMutation.withWrite(to: bindingTarget(audio)) {
                    if let bytes = try read(bindingTarget(audio)) {
                        let old: Journal = try decode(bytes); try validate(old)
                        guard old.generation == generation && old.audioURL == audio else { throw LiveArtifactError.wrongOwner }
                        try removeVerified(bindingTarget(audio))
                    }
                }
            }
            try requireDeletedArtifactAbsence(intent)
            intent.cleanupComplete = true
            try writeVerified(encode(intent), to: deletionURL)
            isDeleted = true
            acceptedChat = nil; acceptedTranscript = nil; durableChat = nil; durableTranscript = nil
        }
    }
    private func requireDeletedArtifactAbsence(_ intent: Deletion) throws {
        var paths = [sourceURL(.chat), sourceURL(.transcript)]
        if let audio = intent.audioURL {
            paths += [targetURL(.chat, audio: audio), targetURL(.transcript, audio: audio), bindingTarget(audio)]
        }
        guard try paths.allSatisfy({ try read($0, maximum: 0, contents: false) == nil }) else { throw LiveArtifactError.verificationFailed }
    }

    private func sourceURL(_ kind: Kind) -> URL { sessionURL.appendingPathComponent(kind == .chat ? "chat.json" : "live-transcript.json") }
    private func targetURL(_ kind: Kind, audio: URL) -> URL { audio.deletingPathExtension().appendingPathExtension(kind == .chat ? "chat.json" : "live-transcript.json") }
    private func bindingTarget(_ audio: URL) -> URL { audio.deletingPathExtension().appendingPathExtension("live-binding.json") }
    private func vector(_ kind: Kind, _ journal: Journal) -> Fingerprint? { kind == .chat ? journal.chat : journal.transcript }
    private func validate(_ value: Journal) throws {
        guard value.version == 1 else { throw LiveArtifactError.unsupportedVersion }
        guard value.identity == identity else { throw LiveArtifactError.wrongOwner }
        try validateBindingPaths(value.audioURL)
        for fingerprint in [value.chat, value.transcript].compactMap({ $0 }) {
            guard fingerprint.count > 0, fingerprint.count <= Self.maxArtifactBytes,
                  fingerprint.sha256.count == 64 && fingerprint.sha256.allSatisfy({ $0.isHexDigit }) else { throw LiveArtifactError.corruptArtifact }
        }
    }
    private func validate(_ value: Deletion) throws {
        guard value.version == 1 || value.version == 2 else { throw LiveArtifactError.unsupportedVersion }
        guard value.version == 1 ? value.intentID == nil : value.intentID != nil && value.cleanupComplete != nil else {
            throw LiveArtifactError.corruptArtifact
        }
        guard value.identity == identity, (value.audioURL == nil) == (value.generation == nil),
              value.audioURL.map({ $0.isFileURL && $0 == $0.standardizedFileURL }) ?? true else { throw LiveArtifactError.wrongOwner }
        if let audio = value.audioURL { try validateBindingPaths(audio) }
    }
    private func requireCurrentJournal(_ value: Journal) throws {
        guard let bytes = try read(journalURL), try decode(bytes, as: Journal.self) == value else { throw LiveArtifactError.revisionConflict }
    }
    private func requireNotDeleted() throws {
        if let bytes = try read(deletionURL) { let intent: Deletion = try decode(bytes); try validate(intent); isDeleted = true; throw LiveArtifactError.deleted }
    }
    private func requireOwner(_ audio: URL) throws {
        try validateBindingPaths(audio)
        try requireSafeParents(audio)
        guard try read(audio, maximum: 0, contents: false) != nil,
              let bytes = try read(audio.deletingPathExtension().appendingPathExtension("json")),
              let metadata = try? JSONDecoder().decode(RecordingMetadataPayload.self, from: bytes),
              metadata.recordingID == identity.recordingID && metadata.masterFileName == audio.lastPathComponent else { throw LiveArtifactError.wrongOwner }
    }
    private func validateBindingPaths(_ audio: URL) throws {
        guard audio.isFileURL, audio == audio.standardizedFileURL,
              RetentionCleanup.audioExtensions.contains(audio.pathExtension.lowercased()),
              !audio.deletingPathExtension().lastPathComponent.isEmpty else { throw LiveArtifactError.unsafePath }
        let paths = [audio, audio.deletingPathExtension().appendingPathExtension("json"), bindingTarget(audio),
                     targetURL(.chat, audio: audio), targetURL(.transcript, audio: audio)]
        guard Set(paths).count == paths.count, paths.allSatisfy({
            $0.path != sessionURL.path && !$0.path.hasPrefix(sessionURL.path + "/")
        }) else { throw LiveArtifactError.unsafePath }
        try requireSafeParents(audio)
        // APFS can give a directory another spelling through case folding or
        // the fixed system aliases. String prefixes cannot prove disjointness.
        var managed = stat()
        guard stat(sessionURL.path, &managed) == 0 else {
            if errno == ENOENT { return }
            throw LiveArtifactError.unsafePath
        }
        guard (managed.st_mode & S_IFMT) == S_IFDIR else { throw LiveArtifactError.unsafePath }
        var parent = audio.deletingLastPathComponent()
        while true {
            var ancestor = stat()
            if stat(parent.path, &ancestor) == 0 {
                guard (ancestor.st_mode & S_IFMT) == S_IFDIR,
                      ancestor.st_dev != managed.st_dev || ancestor.st_ino != managed.st_ino else { throw LiveArtifactError.unsafePath }
            } else if errno != ENOENT { throw LiveArtifactError.unsafePath }
            if parent.path == "/" { break }
            parent.deleteLastPathComponent()
        }
    }
    private func verifyBindingLedger(_ value: Journal) throws {
        guard value.phase == .committed, let bytes = try read(bindingTarget(value.audioURL)) else {
            throw LiveArtifactError.verificationFailed
        }
        let target: Journal = try decode(bytes); try validate(target)
        guard target == value else { throw LiveArtifactError.revisionConflict }
    }
    private func verifySources(_ journal: Journal) throws {
        for kind in [Kind.transcript, .chat] {
            let source = try readPayload(kind, from: sourceURL(kind), generation: nil)
            guard source?.fingerprint == vector(kind, journal) else { throw LiveArtifactError.revisionConflict }
        }
    }
    private func verifyTargets(_ journal: Journal, allowingNewer: Bool) throws {
        for kind in [Kind.transcript, .chat] {
            let target = try readPayload(kind, from: targetURL(kind, audio: journal.audioURL), generation: journal.generation)
            if let expected = vector(kind, journal), let target {
                guard target.fingerprint == expected || (allowingNewer && target.revision > expected.revision) else { throw LiveArtifactError.revisionConflict }
            } else if vector(kind, journal) != nil || (target != nil && !allowingNewer) { throw LiveArtifactError.revisionConflict }
        }
    }
    private func readPayload(_ kind: Kind, from url: URL, generation: UUID?) throws -> Payload? {
        let maximum = kind == .chat ? chatPayloadLimit : payloadLimit
        guard let bytes = try read(url, maximum: maximum) else { return nil }
        switch kind {
        case .chat:
            var value: ChatHistory = try decode(bytes)
            guard value.version == ChatHistory.currentVersion else { throw LiveArtifactError.unsupportedVersion }
            guard value.identity == identity, let revision = value.revision, value.bindingGeneration == generation else { throw LiveArtifactError.wrongOwner }
            value.bindingGeneration = nil
            _ = try LiveArtifactEncoding.estimatedBytes(value, limit: chatPayloadLimit)
            return .init(kind: kind, revision: revision, data: try encode(value))
        case .transcript:
            let value = try LiveTranscriptArtifactCodec.decode(bytes)
            guard value.identity == identity, value.bindingGeneration == generation else { throw LiveArtifactError.wrongOwner }
            return .init(kind: kind, revision: value.revision, data: try value.encoded(generation: nil, limit: payloadLimit))
        }
    }
    private func boundBytes(_ payload: Payload, generation: UUID?) throws -> Data {
        switch payload.kind {
        case .chat:
            var value: ChatHistory = try decode(payload.data); value.bindingGeneration = generation; return try encode(value)
        case .transcript:
            return try LiveTranscriptArtifactCodec.decode(payload.data).encoded(generation: generation, limit: payloadLimit)
        }
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        try LiveArtifactEncoding.encode(value, limit: payloadLimit)
    }
    private func decode<T: Decodable>(_ bytes: Data, as: T.Type = T.self) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: bytes) }
        catch { throw LiveArtifactError.corruptArtifact }
    }

    private func requireSafeParents(_ url: URL) throws {
        guard url.isFileURL else { throw LiveArtifactError.unsafePath }
        var parent = url.deletingLastPathComponent().standardizedFileURL
        while parent.path != "/" {
            // macOS supplies these two system aliases in temporary URLs. Only
            // their fixed system destinations are allowed; task-owned links are
            // still rejected rather than silently following another recording.
            let systemDestination = parent.path == "/var" ? "private/var" : parent.path == "/tmp" ? "private/tmp" : nil
            if let systemDestination, let actual = try? fm.destinationOfSymbolicLink(atPath: parent.path),
               actual == systemDestination || actual == "/" + systemDestination {
                parent.deleteLastPathComponent(); continue
            }
            do {
                guard try fm.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType == .typeDirectory else { throw LiveArtifactError.unsafePath }
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { }
            parent.deleteLastPathComponent()
        }
    }
    private func read(_ url: URL, maximum: Int = maxArtifactBytes, contents: Bool = true) throws -> Data? {
        try requireSafeParents(url)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw LiveArtifactError.unsafePath
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw LiveArtifactError.unsafePath }
        guard contents else { return Data() }
        let maximum = min(maximum, payloadLimit)
        guard info.st_size >= 0 && info.st_size <= maximum else { throw LiveArtifactError.artifactTooLarge }
        let bytes = try handle.read(upToCount: maximum + 1) ?? Data()
        guard bytes.count <= maximum, bytes.count == info.st_size else { throw LiveArtifactError.verificationFailed }
        return bytes
    }
    private func createSessionDirectory() throws {
        try requireSafeParents(sessionURL.appendingPathComponent("probe"))
        try fm.createDirectory(at: sessionURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    /// Reuses the existing private atomic writer pattern: exclusive0600 temp,
    /// payload sync, rename and parent sync. The caller holds the ownership guard.
    private func writeVerified(_ data: Data, to url: URL) throws {
        try requireSafeParents(url)
        _ = try read(url)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".live-\(UUID())")
        let descriptor = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? fm.removeItem(at: temp) }
        try handle.write(contentsOf: data); try handle.synchronize()
        guard rename(temp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try synchronizeDirectory(url.deletingLastPathComponent())
        guard try read(url) == data else { throw LiveArtifactError.verificationFailed }
    }
    private func removeVerified(_ url: URL) throws {
        guard try read(url) != nil else { return }
        try fm.removeItem(at: url); try synchronizeDirectory(url.deletingLastPathComponent())
    }
    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
