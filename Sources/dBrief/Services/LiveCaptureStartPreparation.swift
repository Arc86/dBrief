import Foundation
import dBriefWire

/// One frozen recording's model-free preflight. It never downloads/loads a
/// model, consults current settings, or makes a fallback routing decision.
actor LiveCaptureStartPreparation {
    struct Prepared: Sendable {
        let input: LiveSessionBegin
        let lease: LiveResourceLease
        fileprivate let preparationID: UUID
        fileprivate let owner: UUID?
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var owner: UUID?
        private var bound = false
        private var used = false
        private var pending: LiveResourceLease?
        private var outcome: PrivacyAttempt.Outcome?
        private var completion: PrivacyTrace.Completion?

        func bind(_ owner: UUID) -> Bool {
            lock.withLock {
                guard !bound, !used, outcome == nil else { return false }
                bound = true; self.owner = owner; return true
            }
        }
        func begin(_ owner: UUID?) -> Bool {
            lock.withLock {
                guard self.owner == owner, !used, outcome == nil else { return false }
                used = true; return true
            }
        }
        func active(_ owner: UUID?) -> Bool { lock.withLock { self.owner == owner && outcome == nil } }
        func installLease(_ lease: LiveResourceLease, owner: UUID?) -> Bool {
            lock.withLock {
                guard self.owner == owner, outcome == nil, pending == nil else { return false }
                pending = lease; return true
            }
        }
        func installToken(_ token: PrivacyTrace.Token?, owner: UUID?) {
            let action = lock.withLock { () -> (PrivacyTrace.Completion,PrivacyAttempt.Outcome?)? in
                guard self.owner == owner, completion == nil else { return nil }
                let completion = PrivacyTrace.Completion(token: token)
                self.completion = completion
                return (completion,outcome)
            }
            if let (completion,outcome) = action, let outcome { completion.record(outcome) }
        }
        func claim(_ lease: LiveResourceLease, owner: UUID, ingress: LiveCaptureIngress) -> Bool {
            lock.withLock {
                guard self.owner == owner, outcome == nil, pending == lease,
                      ingress.claimNativeBegin(owner: owner) else { return false }
                // State -> ingress is the only nested lock order. Stop releases
                // its ingress lock before delivering any core/receipt control.
                pending = nil; return true
            }
        }
        func complete(_ value: PrivacyAttempt.Outcome, owner: UUID?) -> (LiveResourceLease?,PrivacyTrace.Completion?,PrivacyAttempt.Outcome)? {
            lock.withLock {
                guard self.owner == owner else { return nil }
                if outcome == nil { outcome = value }
                let lease = pending; pending = nil
                return (lease,completion,outcome!)
            }
        }
    }

    nonisolated let input: LiveSessionBegin
    nonisolated let ingress: LiveCaptureIngress
    nonisolated let resources: LiveModelResourcePolicy
    private nonisolated let state = State()
    private nonisolated let id = UUID()
    private let privacyScope: RecordingPrivacyScope
    private let runID: UUID
    private let request: LiveResourceRequest
    private let cacheCheck: @Sendable (LiveSessionBegin) async throws -> Void
    private let currentMemory: @Sendable () async throws -> LiveResourceMeasurement
    private let context: @Sendable (RecordingPrivacyScope,UUID) async -> PrivacyTrace.Context
    private let beginReceipt: @Sendable (PrivacyOperation,PrivacyTrace.Context) async -> PrivacyTrace.Token?

    init(input: LiveSessionBegin, ingress: LiveCaptureIngress, resources: LiveModelResourcePolicy,
         privacyScope: RecordingPrivacyScope, runID: UUID, request: LiveResourceRequest,
         cacheCheck: @escaping @Sendable (LiveSessionBegin) async throws -> Void,
         currentMemory: @escaping @Sendable () async throws -> LiveResourceMeasurement,
         context: @escaping @Sendable (RecordingPrivacyScope,UUID) async -> PrivacyTrace.Context = { await $0.context(runID: $1) },
         beginReceipt: @escaping @Sendable (PrivacyOperation,PrivacyTrace.Context) async -> PrivacyTrace.Token? = { await PrivacyTrace.begin($0,in: $1) }) {
        self.input = input; self.ingress = ingress; self.resources = resources
        self.privacyScope = privacyScope; self.runID = runID; self.request = request
        self.cacheCheck = cacheCheck; self.currentMemory = currentMemory
        self.context = context; self.beginReceipt = beginReceipt
    }

    nonisolated func bind(to owner: UUID) -> Bool { state.bind(owner) }

    /// Terminal reservation is synchronous; resource return and persistence are
    /// independent of cancellation-ignoring preflight and late token arrival.
    @discardableResult nonisolated func complete(_ outcome: PrivacyAttempt.Outcome, owner: UUID? = nil) -> Task<Void, Never>? {
        guard let (lease,completion,first) = state.complete(outcome,owner: owner) else { return nil }
        let resources = self.resources
        return Task {
            if let lease { await resources.release(lease) }
            await completion?.finish(first)
        }
    }

    func prepare(owner: UUID? = nil) async throws -> Prepared {
        guard input.isValid, ingress.matches(input), privacyScope.recordingID == input.identity.recordingID,
              request.chunkMs == input.configuration.chunkMs, request.sourceCount == input.epochs.count,
              request.vad == input.vad, !request.attributionRequested,
              input.epochs.allSatisfy({ $0.engineRevision == request.modelRevision }),
              state.begin(owner) else { throw LiveProtocolError.invalidConfiguration }
        var admitted: LiveResourceLease?
        do {
            try check(owner)
            let context = await context(privacyScope,runID)
            try check(owner)
            guard matches(context) else { throw LiveProtocolError.invalidConfiguration }
            try await cacheCheck(input); try check(owner)
            let token = await resources.measurementToken(); try check(owner)
            let measurement = try await currentMemory(); try check(owner)
            let lease = try await resources.admitNew(identity: input.identity,request: request,measurement: measurement,token: token)
            admitted = lease
            guard state.installLease(lease,owner: owner) else { throw CancellationError() }
            try check(owner)
            let operation = PrivacyOperation(stage: .liveTranscription,data: [.recordingAudio,.metadata],destination: .local(provider: .fluidAudio))
            let receipt = await beginReceipt(operation,context)
            if let receipt, !matches(receipt.context) { throw LiveProtocolError.invalidConfiguration }
            state.installToken(receipt,owner: owner)
            try check(owner)
            let result = Prepared(input: input,lease: lease,preparationID: id,owner: owner)
            try await validatePreparedStart(result,owner: owner)
            return result
        } catch {
            complete(PrivacyTrace.outcome(for: error),owner: owner)
            // A sealed admission may have returned before it could install into
            // pending ownership. Exact receipts make repeated release harmless.
            if let admitted { await resources.release(admitted) }
            throw error
        }
    }

    func validatePreparedStart(_ prepared: Prepared, owner: UUID? = nil) async throws {
        guard matches(prepared,owner: owner) else { throw LiveProtocolError.invalidConfiguration }
        try check(owner)
        let token = await resources.measurementToken(); try check(owner)
        let measurement = try await currentMemory(); try check(owner)
        try await resources.validatePreparedStart(prepared.lease,measurement: measurement,token: token)
        try check(owner)
    }

    /// Called in the core's nonsuspending dispatch transition. Success moves
    /// cleanup authority out of pending state; only native shutdown returns it.
    nonisolated func claimTransfer(_ prepared: Prepared, owner: UUID) -> Bool {
        matches(prepared,owner: owner) && state.claim(prepared.lease,owner: owner,ingress: ingress)
    }

    private nonisolated func matches(_ prepared: Prepared, owner: UUID?) -> Bool {
        prepared.preparationID == id && prepared.owner == owner && prepared.input == input && prepared.lease.identity == input.identity
    }
    private func matches(_ context: PrivacyTrace.Context) -> Bool {
        context.recordingID == privacyScope.recordingID && context.runID == runID &&
            context.receiptURL == privacyScope.pendingReceiptURL && context.store === privacyScope.store
    }
    private func check(_ owner: UUID?) throws {
        try Task.checkCancellation()
        guard state.active(owner), ingress.nativeStartAvailable else { throw CancellationError() }
    }
}
