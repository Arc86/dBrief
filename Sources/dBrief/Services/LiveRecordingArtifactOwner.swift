import Foundation
import dBriefWire

/// Recording-owned, independent of every transcript window. One observer, one
/// timer and one drain replace per-event persistence tasks. Controls divide
/// latest-value intervals; admission happens synchronously on MainActor.
@MainActor @Observable final class LiveRecordingArtifactOwner {
    nonisolated static let reservationBytes = 32 * 1_024 * 1_024
    nonisolated static let evidenceLimit = 1 * 1_024 * 1_024
    nonisolated static let chatHistoryLimit = 512 * 1_024
    nonisolated static let chatHeaderReserve = 2_048
    nonisolated static let finalPublicationLimit = 256 * 1_024
    private static let pendingValueLimit = 3 * 1_024 * 1_024
    private static let envelopeLimit = 3 * 1_024 * 1_024
    final class Pin: @unchecked Sendable {
        private let lock = NSLock()
        private var owner: LiveRecordingArtifactOwner?
        private let counter: LiveArtifactPinCounter
        @MainActor fileprivate init(_ owner: LiveRecordingArtifactOwner) {
            self.owner = owner; counter = owner.pinCounter; counter.add()
        }
        func release() { lock.withLock { if owner != nil { counter.remove(); owner = nil } } }
        deinit { release() }
    }
    final class ChatRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var pin: Pin?
        private let counter: LiveArtifactPinCounter
        @MainActor fileprivate init(_ owner: LiveRecordingArtifactOwner) {
            pin = owner.pin(); counter = owner.chatRequests; counter.add()
        }
        func release() {
            lock.withLock { if let pin { counter.remove(); pin.release(); self.pin = nil } }
        }
        deinit { release() }
    }
    private final class Interval {
        var revision: UInt64
        var legacy: [LiveLegacyTranscriptValue]?
        var legacyBytes: Int
        var captureClosed: Bool
        var hasTranscript = true
        var finalPublication: LiveAppFinalPublication?
        var finalBytes = 0
        var chat: ChatHistory?
        var chatBytes = 0
        init(revision: UInt64, legacy: [LiveLegacyTranscriptValue]?, bytes: Int, closed: Bool) {
            self.revision = revision; self.legacy = legacy; legacyBytes = bytes; captureClosed = closed
        }
    }
    private final class Delete {
        let continuation: CheckedContinuation<LiveSessionArtifactStore.DeletionReceipt, any Error>
        var executing = false
        init(_ continuation: CheckedContinuation<LiveSessionArtifactStore.DeletionReceipt, any Error>) { self.continuation = continuation }
    }
    private enum Work { case checkpoint(Interval), clear(ChatHistory, Int), bind(URL), delete(Delete) }
    let identity: LiveSessionIdentity
    let writer: LiveSessionArtifactStore
    let isNative: Bool
    private let store: LiveTranscriptStore
    private let validity: RecordingDerivativeValidity
    private let afterCheckpoint: @Sendable () async -> Void
    @ObservationIgnored private var queue: [Work] = []
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var drain: Task<Void, Never>?
    @ObservationIgnored private var chatLoad: Task<ChatHistory?, any Error>?
    @ObservationIgnored private var chatLoadID: UUID?
    @ObservationIgnored private var currentChat: ChatHistory?
    @ObservationIgnored private var retryWriter = false
    @ObservationIgnored var onFailure: ((String?) -> Void)?
    @ObservationIgnored var onLimit: (() -> Void)?
    @ObservationIgnored private var legacy: [LiveLegacyTranscriptValue] = []
    @ObservationIgnored private var legacyByID: [UUID: LiveLegacyTranscriptValue] = [:]
    @ObservationIgnored private var finalPublication: LiveAppFinalPublication?
    private var nativeFinalAnchor: (id: UUID, revision: UInt64)?
    private var finalCommitted = false
    private var needsTextOnlyFallback = false
    private var legacyBytes = 0
    @ObservationIgnored private let pinCounter = LiveArtifactPinCounter()
    @ObservationIgnored private let chatRequests = LiveArtifactPinCounter()
    @ObservationIgnored private weak var chatService: TranscriptChatService?
    private var started = false
    var persistenceStarted: Bool { started }
    private var retired = false
    private(set) var deletionPending = false
    private(set) var admittedAudioURL: URL?
    private var nativeClosureDurable = false
    private var hydratedReadOnly = false
    private var recoveredOwner = false
    private var sourceUnavailable = false
    private(set) var captureClosed = false
    private(set) var acceptedRevision: UInt64 = 0
    private(set) var durableRevision: UInt64 = 0
    private(set) var acceptedChatRevision: UInt64 = 0
    private(set) var durableChatRevision: UInt64 = 0
    private(set) var chatReady = false
    private(set) var failure: String?
    private(set) var growthRetired = false
    var isDurable: Bool {
        started && !deletionPending && failure == nil && queue.isEmpty && drain == nil && durableRevision == acceptedRevision
            && durableChatRevision == acceptedChatRevision && chatLoad == nil
            && (!captureClosed || !isNative || nativeClosureDurable || hydratedReadOnly)
    }
    var canEvict: Bool { captureClosed && pinCounter.count == 0 && isDurable }
    var isRecoveredOwner: Bool { recoveredOwner }
    var pendingIntervals: Int { queue.filter { if case .checkpoint = $0 { true } else { false } }.count }

    init(identity: LiveSessionIdentity, store: LiveTranscriptStore, validity: RecordingDerivativeValidity,
         native: Bool, rootURL: URL, payloadReservation: LiveRecordingPayloadBudget.Lease,
         beforeStage: @escaping @Sendable (LiveArtifactStage) async throws -> Void,
         afterCheckpoint: @escaping @Sendable () async -> Void = {}, recoveredWriter: LiveSessionArtifactStore? = nil) {
        self.identity = identity; self.store = store; self.validity = validity; isNative = native
        self.afterCheckpoint = afterCheckpoint
        writer = recoveredWriter ?? LiveSessionArtifactStore(identity: identity, rootURL: rootURL, validity: validity,
            payloadReservation: payloadReservation, payloadLimit: Self.envelopeLimit, queueByteLimit: Self.envelopeLimit,
            chatPayloadLimit: Self.chatHistoryLimit, beforeStage: beforeStage)
    }
    /// The recovered writer already verified the persisted prefix. Hydration
    /// starts no observer and writes no closure or schema migration.
    func hydrate(_ restored: LiveSessionArtifactStore.Restored) throws {
        guard !started, !restored.deleted, (restored.transcriptValue?.identity ?? identity) == identity else { throw LiveArtifactError.wrongOwner }
        if let value = restored.transcriptValue {
            _ = try value.encoded(generation: nil, limit: Self.envelopeLimit)
            acceptedRevision = value.revision; durableRevision = value.revision
        }
        if let chat = restored.chat { _ = try LiveArtifactEncoding.estimatedBytes(chat, limit: Self.chatHistoryLimit) }
        legacy = restored.appTranscript?.legacy ?? []
        legacyBytes = try LiveArtifactEncoding.estimatedBytes(legacy, limit: Self.envelopeLimit) * 2
        legacyByID = Dictionary(uniqueKeysWithValues: legacy.map { ($0.id, $0) })
        sourceUnavailable = restored.transcriptValue == nil || restored.appTranscript?.sourceUnavailable == true
        finalPublication = restored.appTranscript?.finalPublication
        nativeFinalAnchor = restored.transcript?.finalPublication.map { ($0.id, $0.revision) }
        finalCommitted = finalPublication != nil || nativeFinalAnchor != nil
        needsTextOnlyFallback = finalPublication?.fallbackText != nil && finalPublication?.segments.isEmpty == true
        currentChat = restored.chat; chatReady = true
        acceptedChatRevision = restored.chat?.revision ?? 0; durableChatRevision = acceptedChatRevision
        admittedAudioURL = restored.audioURL
        started = true; captureClosed = true; hydratedReadOnly = true; recoveredOwner = true
    }
    func pin() -> Pin { Pin(self) }
    func attachChatService(_ service: TranscriptChatService) -> Bool {
        guard !retired, !deletionPending, (try? validity.withValidResult {}) != nil,
              chatService == nil || chatService === service else { return false }
        chatService = service; return true
    }
    func beginChatRequest() throws -> ChatRequest {
        try validity.withValidResult {}
        guard !retired, !deletionPending else { throw LiveArtifactError.deleted }
        guard chatRequests.count == 0 else { throw LiveArtifactError.queueFull }
        return ChatRequest(self)
    }

    /// Initialization is shared, but subsequent callers get the latest owned
    /// history rather than replaying an obsolete initial load task result.
    func loadChat() async throws -> ChatHistory? {
        try validity.withValidResult {}
        guard !retired, !deletionPending else { throw LiveArtifactError.deleted }
        if chatReady { return currentChat }
        let task: Task<ChatHistory?, any Error>
        let loadID: UUID
        if let chatLoad, let chatLoadID { task = chatLoad; loadID = chatLoadID }
        else {
            loadID = UUID()
            let pin = pin(), writer = writer
            task = Task {
                defer { pin.release() }
                let restored = try await writer.recover()
                guard !restored.deleted else { throw LiveArtifactError.deleted }
                if let history = restored.chat {
                    _ = try LiveArtifactEncoding.estimatedBytes(history, limit: Self.chatHistoryLimit)
                }
                return restored.chat
            }
            chatLoad = task; chatLoadID = loadID
        }
        do {
            let history = try await task.value
            try validity.withValidResult {}
            guard !retired else { throw LiveArtifactError.deleted }
            if !chatReady {
                currentChat = history
                acceptedChatRevision = history?.revision ?? 0; durableChatRevision = acceptedChatRevision
                chatReady = true
            }
            if chatLoadID == loadID { chatLoad = nil; chatLoadID = nil }
            return currentChat
        } catch {
            if chatLoadID == loadID { chatLoad = nil; chatLoadID = nil }
            throw error
        }
    }

    /// Includes worst-case bound-header space; callers can reserve terminal
    /// metadata once and charge response text incrementally before publication.
    func remainingChatBytes(_ history: ChatHistory) throws -> Int {
        let value = normalizedChat(history, revision: acceptedChatRevision)
        return Self.chatHistoryLimit - Self.chatHeaderReserve
            - (try LiveArtifactEncoding.estimatedBytes(value, limit: Self.chatHistoryLimit - Self.chatHeaderReserve))
    }

    @discardableResult
    func saveChat(_ history: ChatHistory, urgent: Bool) throws -> UInt64 {
        try requireChatAdmission()
        guard acceptedChatRevision < .max else { throw LiveArtifactError.staleRevision }
        let value = normalizedChat(history, revision: acceptedChatRevision + 1)
        _ = try LiveArtifactEncoding.estimatedBytes(value, limit: Self.chatHistoryLimit - Self.chatHeaderReserve)
        // Reserve the whole admitted response slot up front. Later streaming
        // growth cannot lose capacity to controls accepted after Send.
        let bytes = Self.chatHistoryLimit * 2
        let tail = tailInterval
        try requireCapacity(legacyBytes: tail?.legacyBytes ?? 0, chatBytes: bytes)
        acceptedChatRevision += 1; currentChat = value
        let interval: Interval
        if let tail { interval = tail }
        else {
            interval = .init(revision: 0, legacy: nil, bytes: 0, closed: captureClosed)
            interval.hasTranscript = false; queue.append(.checkpoint(interval))
        }
        interval.chat = value; interval.chatBytes = bytes
        startDrain(urgent: urgent)
        return acceptedChatRevision
    }

    @discardableResult
    func clearChat() throws -> UInt64 {
        try requireChatAdmission()
        guard controlCount < 8 else { throw LiveArtifactError.queueFull }
        guard acceptedChatRevision < .max else { throw LiveArtifactError.staleRevision }
        let value = normalizedChat(.init(messages: []), revision: acceptedChatRevision + 1)
        let bytes = try LiveArtifactEncoding.estimatedBytes(value, limit: Self.chatHistoryLimit) * 2
        guard bytes <= 4_096 else { throw LiveArtifactError.artifactTooLarge }
        acceptedChatRevision += 1; currentChat = value
        queue.append(.clear(value, bytes)); startDrain(urgent: true)
        return acceptedChatRevision
    }

    private func normalizedChat(_ history: ChatHistory, revision: UInt64) -> ChatHistory {
        var value = history
        value.version = ChatHistory.currentVersion; value.identity = identity
        value.revision = revision; value.bindingGeneration = nil
        return value
    }
    private func requireChatAdmission() throws {
        try validity.withValidResult {}
        guard !retired, !deletionPending else { throw LiveArtifactError.deleted }
        guard chatReady else { throw LiveArtifactError.bindingPending }
    }

    func start() {
        guard !started, !retired else { return }
        started = true
        if isNative {
            observer = Task { [weak self, store] in
                do {
                    let changes = try await store.changes()
                    for await _ in changes {
                        guard !Task.isCancelled, let self, !self.retired else { return }
                        if self.deletionPending { continue }
                        try self.checkpoint(urgent: self.captureClosed)
                    }
                } catch { self?.report(error) }
            }
        } else {
            do { try checkpoint(urgent: false) } catch { report(error) }
        }
    }

    func appendLegacy(_ values: [LiveTranscriptSegment]) throws {
        try validity.withValidResult {}
        guard !isNative, !captureClosed, !growthRetired, !retired, !deletionPending else { throw LiveArtifactError.deleted }
        guard values.count <= 4_096 else { throw LiveArtifactError.artifactTooLarge }
        var unique: [UUID: LiveLegacyTranscriptValue] = [:], added: [LiveLegacyTranscriptValue] = []
        for segment in values {
            let value = LiveLegacyTranscriptValue(segment)
            guard value.text.utf8.count <= 65_536, (value.speaker?.utf8.count ?? 0) <= 256 else { throw LiveArtifactError.artifactTooLarge }
            if let prior = legacyByID[value.id] ?? unique[value.id] {
                guard prior == value else { throw LiveArtifactError.revisionConflict }
            } else { unique[value.id] = value; added.append(value) }
        }
        guard !added.isEmpty else { return }
        // Double charge covers the identity lookup and ordered source value.
        let cost: Int
        do { cost = try LiveArtifactEncoding.estimatedBytes(added, limit: Self.evidenceLimit / 2) * 2 }
        catch { growthRetired = true; onLimit?(); throw error }
        guard cost <= Self.evidenceLimit - legacyBytes else {
            growthRetired = true; onLimit?(); throw LiveArtifactError.artifactTooLarge
        }
        try requireCheckpointCapacity(bytes: legacyBytes + cost)
        guard acceptedRevision < .max else { throw LiveArtifactError.staleRevision }
        legacy.append(contentsOf: added); legacyByID.merge(unique, uniquingKeysWith: { old, _ in old }); legacyBytes += cost
        try checkpoint(urgent: false)
    }

    func closeCapture() {
        guard !captureClosed else { return }
        captureClosed = true
        do { try checkpoint(urgent: true) } catch { report(error) }
    }

    func bind(to audioURL: URL) throws {
        try validity.withValidResult {}
        guard captureClosed, !retired, !deletionPending else { throw LiveArtifactError.bindingPending }
        guard controlCount < 8 else { throw LiveArtifactError.queueFull }
        _ = try LiveArtifactEncoding.estimatedBytes(audioURL, limit: 4_096)
        if !recoveredOwner { try checkpoint(urgent: false) }
        queue.append(.bind(audioURL.standardizedFileURL))
        admittedAudioURL = audioURL
        startDrain(urgent: true)
    }

    func retry() throws {
        try validity.withValidResult {}
        guard !retired, !deletionPending else { throw LiveArtifactError.deleted }
        retryWriter = true; failure = nil; onFailure?(nil)
        startDrain(urgent: true)
    }

    /// One admitted control follows earlier writes/Bind. Caller cancellation
    /// does not abandon a physical intent or its verified return value.
    func commitDeletionIntent() async throws -> LiveSessionArtifactStore.DeletionReceipt {
        try validity.withValidResult {}
        guard started, captureClosed, !retired, !deletionPending else { throw LiveArtifactError.deleted }
        guard controlCount < 8 else { throw LiveArtifactError.queueFull }
        guard failure == nil else { throw LiveArtifactError.verificationFailed }
        let pin = pin(); defer { pin.release() }
        deletionPending = true
        return try await withCheckedThrowingContinuation { continuation in
            queue.append(.delete(Delete(continuation)))
            startDrain(urgent: true)
        }
    }

    /// Intended for a closed capture or an explicitly bounded lifecycle drain.
    /// This never participates in the hardware Stop latch.
    func flush() async throws {
        try validity.withValidResult {}
        if !started { start() }
        if failure == nil, !recoveredOwner { try checkpoint(urgent: true) }
        if failure == nil { startDrain(urgent: true) }
        await waitForSubmittedWrites()
        if failure != nil { throw LiveArtifactError.verificationFailed }
        guard isDurable else { throw LiveArtifactError.verificationFailed }
    }

    /// Retirement forbids new submissions but cannot cancel held physical IO.
    /// Cleanup can join the already submitted drain without new write authority.
    func waitForSubmittedWrites() async {
        while let task = drain { await task.value }
        if let task = chatLoad { _ = try? await task.value }
    }

    func legacyContext() throws -> TranscriptContextSnapshot {
        try validity.withValidResult {}
        guard !isNative, !retired else { throw LiveArtifactError.deleted }
        guard !sourceUnavailable else { throw LiveArtifactError.missingEvidence }
        return try LiveTranscriptArtifact(identity: identity, revision: acceptedRevision, legacy: legacy,
            captureClosed: captureClosed).legacyContext()
    }

    func finalContext() throws -> TranscriptContextSnapshot? {
        try validity.withValidResult {}
        guard !retired else { throw LiveArtifactError.deleted }
        return finalPublication?.context(identity: identity)
    }

    /// Called only after the raw transcript and processing checkpoint commit.
    /// Later resume of that generation must not replace saved rich user edits.
    func publishFinal(_ result: TranscriptionResult) throws {
        try validity.withValidResult {}
        guard captureClosed, !retired, !deletionPending else { throw LiveArtifactError.bindingPending }
        finalCommitted = true
        guard finalPublication == nil, nativeFinalAnchor == nil else { return }
        needsTextOnlyFallback = result.segments.isEmpty && !result.text.isEmpty
        var text = result.text
        if text.isEmpty {
            var remaining = Self.finalPublicationLimit / 6
            for segment in result.segments {
                guard segment.text.utf8.count < remaining else { throw LiveArtifactError.artifactTooLarge }
                remaining -= segment.text.utf8.count + 1
            }
            for (index, segment) in result.segments.enumerated() {
                if index > 0 { text.append("\n") }
                text.append(segment.text)
            }
        }
        try publishFinal(transcript: .init(segments: []), fallbackText: text)
    }

    /// Saved rich facts become one atomic revision; existing answers retain
    /// their frozen publication and the original derivative validity token.
    func publishSavedFinal(_ transcript: RichTranscript) throws {
        try validity.withValidResult {}
        guard finalCommitted else { throw LiveArtifactError.bindingPending }
        let needsFallback = transcript.segments.isEmpty && needsTextOnlyFallback
        guard !needsFallback || finalPublication?.fallbackText != nil else { throw LiveArtifactError.artifactTooLarge }
        try publishFinal(transcript: transcript, fallbackText: needsFallback ? finalPublication?.fallbackText : nil)
        if !transcript.segments.isEmpty { needsTextOnlyFallback = false }
    }

    private func publishFinal(transcript: RichTranscript, fallbackText: String?) throws {
        guard captureClosed, !retired, !deletionPending else { throw LiveArtifactError.bindingPending }
        let priorRevision = max(finalPublication?.revision ?? 0, nativeFinalAnchor?.revision ?? 0)
        guard acceptedRevision < .max, priorRevision < .max else { throw LiveArtifactError.staleRevision }
        let value = try LiveAppFinalPublication.bounded(id: finalPublication?.id ?? nativeFinalAnchor?.id ?? UUID(),
            revision: priorRevision + 1, transcript: transcript, fallbackText: fallbackText,
            limit: Self.finalPublicationLimit)
        if let old = finalPublication, old.segments == value.segments,
           old.speakerLabels == value.speakerLabels, old.fallbackText == value.fallbackText { return }
        try requireCapacity(legacyBytes: legacyBytes, chatBytes: tailInterval?.chatBytes ?? 0,
            finalBytes: Self.finalPublicationLimit)
        finalPublication = value
        try checkpoint(urgent: true)
    }

    func retire() {
        retired = true; observer?.cancel(); observer = nil; timer?.cancel(); timer = nil
        chatService?.invalidateForReprocessing()
        settleQueuedDeletion(LiveArtifactError.deleted)
        // A held physical write is still charged until its actual return. Its
        // shared validity rejects the effect after synchronous retirement.
    }

    private var tailInterval: Interval? { queue.last.flatMap { if case .checkpoint(let value) = $0 { value } else { nil } } }
    private var controlCount: Int { queue.filter { if case .checkpoint = $0 { false } else { true } }.count }
    private func requireCapacity(legacyBytes: Int, chatBytes: Int, finalBytes: Int? = nil, replacingTail: Bool = true) throws {
        let tail = replacingTail ? tailInterval : nil
        let pending = queue.reduce(0) { count, work in
            switch work {
            case .checkpoint(let value): return count + (value === tail ? 0 : value.legacyBytes + value.chatBytes + value.finalBytes)
            case .clear: return count // Separately reserved: at most 8 × 4KiB.
            case .bind, .delete: return count
            }
        }
        guard legacyBytes + chatBytes + (finalBytes ?? tail?.finalBytes ?? 0) <= Self.pendingValueLimit - pending else { throw LiveArtifactError.queueFull }
    }
    private func requireCheckpointCapacity(bytes: Int) throws {
        try requireCapacity(legacyBytes: bytes, chatBytes: tailInterval?.chatBytes ?? 0,
            finalBytes: finalPublication == nil ? 0 : Self.finalPublicationLimit)
    }
    private func checkpoint(urgent: Bool) throws {
        guard !retired, !deletionPending else { throw LiveArtifactError.deleted }
        try requireCheckpointCapacity(bytes: legacyBytes)
        guard acceptedRevision < .max else { throw LiveArtifactError.staleRevision }
        acceptedRevision += 1
        hydratedReadOnly = false
        if let last = queue.last, case .checkpoint(let value) = last {
            value.hasTranscript = true
            value.revision = acceptedRevision; value.legacy = isNative ? nil : legacy
            value.legacyBytes = legacyBytes; value.captureClosed = captureClosed
            value.finalPublication = finalPublication; value.finalBytes = finalPublication == nil ? 0 : Self.finalPublicationLimit
        } else {
            queue.append(.checkpoint(.init(revision: acceptedRevision, legacy: isNative ? nil : legacy,
                bytes: legacyBytes, closed: captureClosed)))
            tailInterval?.finalPublication = finalPublication
            tailInterval?.finalBytes = finalPublication == nil ? 0 : Self.finalPublicationLimit
        }
        startDrain(urgent: urgent)
    }

    private func startDrain(urgent: Bool) {
        guard started, !retired, failure == nil, drain == nil, !queue.isEmpty || retryWriter else { return }
        if urgent {
            timer?.cancel(); timer = nil
            drain = Task { [weak self] in await self?.drainQueue() }
        } else if timer == nil {
            timer = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self else { return }; self.timer = nil; self.startDrain(urgent: true)
            }
        }
    }

    private func drainQueue() async {
        if retryWriter {
            do { try await writer.retry(); retryWriter = false }
            catch { report(error); settleQueuedDeletion(error); drain = nil; return }
        }
        while !queue.isEmpty, !retired {
            do {
                switch queue[0] {
                case .checkpoint(let interval):
                    // No full checkpoint is requested while an earlier write
                    // is held. Notifications retain only a revision signal.
                    let hasTranscript = interval.hasTranscript, revision = interval.revision
                    let closed = interval.captureClosed, legacy = interval.legacy, chat = interval.chat
                    let publication = interval.finalPublication
                    if hasTranscript {
                        let state = isNative ? await store.checkpointState() : nil
                        if isNative { await afterCheckpoint() }
                        if state?.growthRetired == true, !growthRetired { growthRetired = true; onLimit?() }
                        let value = LiveTranscriptArtifact(identity: identity, revision: revision, native: state?.checkpoint,
                            legacy: sourceUnavailable ? nil : legacy, captureClosed: closed && (publication != nil || (state?.isClosed ?? true)),
                            finalPublication: publication, sourceUnavailable: sourceUnavailable ? true : nil)
                        _ = try LiveArtifactEncoding.estimatedBytes(value, limit: Self.envelopeLimit)
                        try await writer.saveTranscript(value)
                        durableRevision = revision
                        if interval.revision == revision {
                            interval.hasTranscript = false; interval.legacy = nil; interval.legacyBytes = 0
                            interval.finalPublication = nil; interval.finalBytes = 0
                            if closed, state?.isClosed == true {
                                nativeClosureDurable = true; observer?.cancel(); observer = nil
                            }
                        }
                    }
                    if let chat, let revision = chat.revision {
                        try await writer.saveChat(chat, revision: revision); durableChatRevision = revision
                        if interval.chat?.revision == revision { interval.chat = nil; interval.chatBytes = 0 }
                    }
                    if !interval.hasTranscript && interval.chat == nil { queue.removeFirst() }
                case .clear(let history, _):
                    let revision = history.revision!
                    try await writer.clearChat(revision: revision); durableChatRevision = revision; queue.removeFirst()
                case .bind(let url):
                    try await writer.bind(to: url); queue.removeFirst()
                case .delete(let request):
                    request.executing = true
                    do {
                        // A prior load was admitted outside this queue. Join it
                        // before intent, so recover cannot run deletion cleanup.
                        if let task = chatLoad { _ = try await task.value }
                        let receipt = try await writer.commitDeletionIntent()
                        queue.removeFirst()
                        request.continuation.resume(returning: receipt)
                    } catch {
                        queue.removeFirst(); deletionPending = false
                        // Notifications coalesced while Delete was pending may
                        // include actual native closure. Catch up after failure.
                        if isNative, !hydratedReadOnly { do { try checkpoint(urgent: true) } catch { report(error) } }
                        request.continuation.resume(throwing: error)
                    }
                }
            } catch { report(error); settleQueuedDeletion(error); break }
        }
        drain = nil
    }
    private func settleQueuedDeletion(_ error: any Error) {
        queue.removeAll { work in
            guard case .delete(let request) = work, !request.executing else { return false }
            request.continuation.resume(throwing: error); deletionPending = false; return true
        }
    }
    private func report(_ error: any Error) { failure = error.localizedDescription; onFailure?(failure) }
}
