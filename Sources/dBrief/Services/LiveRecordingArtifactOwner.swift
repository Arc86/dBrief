import Foundation
import dBriefWire

/// Recording-owned, independent of every transcript window. One observer, one
/// timer and one drain replace per-event persistence tasks. Controls divide
/// latest-value intervals; admission happens synchronously on MainActor.
@MainActor @Observable final class LiveRecordingArtifactOwner {
    nonisolated static let reservationBytes = 32 * 1_024 * 1_024
    nonisolated static let evidenceLimit = 1 * 1_024 * 1_024
    private static let pendingValueLimit = 2 * 1_024 * 1_024
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
    private final class Interval {
        var revision: UInt64
        var legacy: [LiveLegacyTranscriptValue]?
        var legacyBytes: Int
        var captureClosed: Bool
        init(revision: UInt64, legacy: [LiveLegacyTranscriptValue]?, bytes: Int, closed: Bool) {
            self.revision = revision; self.legacy = legacy; legacyBytes = bytes; captureClosed = closed
        }
    }
    private enum Work { case checkpoint(Interval), bind(URL) }
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
    @ObservationIgnored var onFailure: ((String?) -> Void)?
    @ObservationIgnored var onLimit: (() -> Void)?
    @ObservationIgnored private var legacy: [LiveLegacyTranscriptValue] = []
    @ObservationIgnored private var legacyByID: [UUID: LiveLegacyTranscriptValue] = [:]
    private var legacyBytes = 0
    @ObservationIgnored private let pinCounter = LiveArtifactPinCounter()
    private var started = false
    private var retired = false
    private var nativeClosureDurable = false
    private(set) var captureClosed = false
    private(set) var acceptedRevision: UInt64 = 0
    private(set) var durableRevision: UInt64 = 0
    private(set) var failure: String?
    private(set) var growthRetired = false
    var isDurable: Bool {
        started && failure == nil && queue.isEmpty && drain == nil && durableRevision == acceptedRevision
            && (!captureClosed || !isNative || nativeClosureDurable)
    }
    var canEvict: Bool { captureClosed && pinCounter.count == 0 && isDurable }
    var pendingIntervals: Int { queue.filter { if case .checkpoint = $0 { true } else { false } }.count }

    init(identity: LiveSessionIdentity, store: LiveTranscriptStore, validity: RecordingDerivativeValidity,
         native: Bool, rootURL: URL, payloadReservation: LiveRecordingPayloadBudget.Lease,
         beforeStage: @escaping @Sendable (LiveArtifactStage) async throws -> Void,
         afterCheckpoint: @escaping @Sendable () async -> Void = {}) {
        self.identity = identity; self.store = store; self.validity = validity; isNative = native
        self.afterCheckpoint = afterCheckpoint
        writer = LiveSessionArtifactStore(identity: identity, rootURL: rootURL, validity: validity,
            payloadReservation: payloadReservation, payloadLimit: Self.envelopeLimit, queueByteLimit: Self.envelopeLimit, beforeStage: beforeStage)
    }
    func pin() -> Pin { Pin(self) }

    func start() {
        guard !started, !retired else { return }
        started = true
        if isNative {
            observer = Task { [weak self, store] in
                do {
                    let changes = try await store.changes()
                    for await _ in changes {
                        guard !Task.isCancelled, let self, !self.retired else { return }
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
        guard !isNative, !captureClosed, !growthRetired, !retired else { throw LiveArtifactError.deleted }
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
        guard captureClosed, !retired else { throw LiveArtifactError.bindingPending }
        guard queue.filter({ if case .bind = $0 { true } else { false } }).count < 8 else { throw LiveArtifactError.queueFull }
        try checkpoint(urgent: false)
        queue.append(.bind(audioURL.standardizedFileURL))
        startDrain(urgent: true)
    }

    func retry() throws {
        try validity.withValidResult {}
        guard !retired else { throw LiveArtifactError.deleted }
        failure = nil; onFailure?(nil)
        startDrain(urgent: true)
    }

    /// Intended for a closed capture or an explicitly bounded lifecycle drain.
    /// This never participates in the hardware Stop latch.
    func flush() async throws {
        try validity.withValidResult {}
        if !started { start() }
        if failure == nil { try checkpoint(urgent: true) }
        await waitForSubmittedWrites()
        if failure != nil { throw LiveArtifactError.verificationFailed }
        guard isDurable else { throw LiveArtifactError.verificationFailed }
    }

    /// Retirement forbids new submissions but cannot cancel held physical IO.
    /// Cleanup can join the already submitted drain without new write authority.
    func waitForSubmittedWrites() async {
        while let task = drain { await task.value }
    }

    func legacyContext() throws -> TranscriptContextSnapshot {
        try validity.withValidResult {}
        guard !isNative, !retired else { throw LiveArtifactError.deleted }
        return try LiveTranscriptArtifact(identity: identity, revision: acceptedRevision, legacy: legacy,
            captureClosed: captureClosed).legacyContext()
    }

    func retire() {
        retired = true; observer?.cancel(); observer = nil; timer?.cancel(); timer = nil
        // A held physical write is still charged until its actual return. Its
        // shared validity rejects the effect after synchronous retirement.
    }

    private func requireCheckpointCapacity(bytes: Int) throws {
        let tail = queue.last.flatMap { if case .checkpoint(let value) = $0 { value } else { nil } }
        let pending = queue.reduce(0) { count, work in
            if case .checkpoint(let value) = work, value !== tail { return count + value.legacyBytes }
            return count
        }
        guard bytes <= Self.pendingValueLimit - pending else { throw LiveArtifactError.queueFull }
    }
    private func checkpoint(urgent: Bool) throws {
        guard !retired else { throw LiveArtifactError.deleted }
        try requireCheckpointCapacity(bytes: legacyBytes)
        guard acceptedRevision < .max else { throw LiveArtifactError.staleRevision }
        acceptedRevision += 1
        if let last = queue.last, case .checkpoint(let value) = last {
            value.revision = acceptedRevision; value.legacy = isNative ? nil : legacy
            value.legacyBytes = legacyBytes; value.captureClosed = captureClosed
        } else {
            queue.append(.checkpoint(.init(revision: acceptedRevision, legacy: isNative ? nil : legacy,
                bytes: legacyBytes, closed: captureClosed)))
        }
        startDrain(urgent: urgent)
    }

    private func startDrain(urgent: Bool) {
        guard started, !retired, failure == nil, drain == nil, !queue.isEmpty else { return }
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
        while !queue.isEmpty, !retired {
            do {
                switch queue[0] {
                case .checkpoint(let interval):
                    // No full checkpoint is requested while an earlier write
                    // is held. Notifications retain only a revision signal.
                    let revision = interval.revision, closed = interval.captureClosed, legacy = interval.legacy
                    let state = isNative ? await store.checkpointState() : nil
                    if isNative { await afterCheckpoint() }
                    if state?.growthRetired == true, !growthRetired {
                        growthRetired = true
                        onLimit?()
                    }
                    let value = LiveTranscriptArtifact(identity: identity, revision: revision, native: state?.checkpoint,
                        legacy: legacy, captureClosed: closed && (state?.isClosed ?? true))
                    _ = try LiveArtifactEncoding.estimatedBytes(value, limit: Self.envelopeLimit)
                    try await writer.saveTranscript(value)
                    durableRevision = revision
                    if interval.revision == revision {
                        queue.removeFirst()
                        if closed, state?.isClosed == true {
                            nativeClosureDurable = true; observer?.cancel(); observer = nil
                        }
                    }
                case .bind(let url):
                    try await writer.bind(to: url); queue.removeFirst()
                }
            } catch { report(error); break }
        }
        drain = nil
    }
    private func report(_ error: any Error) { failure = error.localizedDescription; onFailure?(failure) }
}
