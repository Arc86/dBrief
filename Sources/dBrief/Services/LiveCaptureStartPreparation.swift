import Foundation
import dBriefWire

/// One frozen recording's preflight. Owned cache copying invokes no CoreML,
/// downloader, current settings lookup or fallback routing decision.
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
        private var transferred = false
        private var nativeAssetsRetired = false

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
                pending = nil; transferred = true; return true
            }
        }
        func complete(_ value: PrivacyAttempt.Outcome, owner: UUID?) -> (LiveResourceLease?,PrivacyTrace.Completion?,PrivacyAttempt.Outcome,Bool)? {
            lock.withLock {
                guard self.owner == owner else { return nil }
                if outcome == nil { outcome = value }
                let lease = pending; pending = nil
                return (lease,completion,outcome!,!transferred)
            }
        }
        func retireNativeAssets(owner: UUID) -> Bool {
            lock.withLock {
                guard self.owner == owner, transferred, !nativeAssetsRetired else { return false }
                nativeAssetsRetired = true; return true
            }
        }
    }

    nonisolated let input: LiveSessionBegin
    nonisolated let ingress: LiveCaptureIngress
    nonisolated let resources: LiveModelResourcePolicy
    private nonisolated let state = State()
    private nonisolated let id = UUID()
    private nonisolated let vadAssets: LiveVADAssetPreparation?
    private nonisolated let asrAssets: LiveASRModelAssets?
    nonisolated let attribution: LiveCaptureAttributionOwner?
    private nonisolated let validASRBinding: Bool
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
         beginReceipt: @escaping @Sendable (PrivacyOperation,PrivacyTrace.Context) async -> PrivacyTrace.Token? = { await PrivacyTrace.begin($0,in: $1) },
         asrAssets: LiveASRModelAssets? = nil, vadAssets: LiveVADAssetPreparation? = nil, attribution: LiveCaptureAttributionOwner? = nil) {
        self.input = input; self.ingress = ingress; self.resources = resources
        self.privacyScope = privacyScope; self.runID = runID; self.request = request
        self.cacheCheck = cacheCheck; self.currentMemory = currentMemory
        self.context = context; self.beginReceipt = beginReceipt
        self.asrAssets = asrAssets; self.vadAssets = vadAssets; self.attribution = attribution
        validASRBinding = request.asr == input.configuration.identity &&
            (input.configuration.identity == nil ? asrAssets == nil : asrAssets?.configuration == input.configuration) &&
            (input.vad == nil ? vadAssets == nil : vadAssets?.configuration == input.vad) &&
            (request.attributionRequested ? (attribution?.metadata == input.diarization && attribution?.publication.identity == input.identity &&
                request.diarization == input.diarization?.configuration.identity && input.diarization != nil) : (attribution == nil && input.diarization == nil))
    }

    nonisolated func bind(to owner: UUID) -> Bool {
        validASRBinding && state.bind(owner) && (asrAssets?.bind(to: id) ?? true) && (vadAssets?.bind(to: id) ?? true) && (attribution?.bind(to: owner) ?? true)
    }

    /// Terminal reservation is synchronous; resource return and persistence are
    /// independent of cancellation-ignoring preflight and late token arrival.
    @discardableResult nonisolated func complete(_ outcome: PrivacyAttempt.Outcome, owner: UUID? = nil) -> Task<Void, Never>? {
        guard let (lease,completion,first,retirePendingAssets) = state.complete(outcome,owner: owner) else { return nil }
        let asrCleanup = retirePendingAssets ? asrAssets?.retire(owner: id) : nil
        let vadCleanup = retirePendingAssets ? vadAssets?.retire(owner: id) : nil
        if retirePendingAssets { attribution?.seal() }
        let resources = self.resources
        return Task {
            await asrCleanup?.value; await vadCleanup?.value
            if retirePendingAssets { await self.attribution?.joinAfterExit() }
            if let lease { await resources.release(lease) }
            await completion?.finish(first)
        }
    }

    func prepare(owner: UUID? = nil) async throws -> Prepared {
        guard validASRBinding, input.isValid, ingress.matches(input), privacyScope.recordingID == input.identity.recordingID,
              request.chunkMs == input.configuration.chunkMs, request.sourceCount == input.epochs.count,
              request.vad == input.vad,
              input.epochs.allSatisfy({ $0.engineRevision == request.modelRevision }),
              state.begin(owner), asrAssets?.bind(to: id) ?? true, vadAssets?.bind(to: id) ?? true else { throw LiveProtocolError.invalidConfiguration }
        var admitted: LiveResourceLease?
        do {
            try check(owner)
            try await resources.validateProfile(request); try check(owner)
            let context = await context(privacyScope,runID)
            try check(owner)
            guard matches(context) else { throw LiveProtocolError.invalidConfiguration }
            if let asrAssets { try await asrAssets.prepare(owner: id); try check(owner) }
            if let vadAssets {
                do { try await vadAssets.prepare(owner: id) }
                catch is CancellationError { throw CancellationError() }
                catch { vadAssets.markUnavailable(owner: id) }
                try check(owner)
            }
            try await cacheCheck(input); try check(owner)
            let token = await resources.measurementToken(); try check(owner)
            let measurement = try await currentMemory(); try check(owner)
            let lease = try await resources.admitNew(identity: input.identity,request: request,measurement: measurement,token: token)
            admitted = lease
            guard state.installLease(lease,owner: owner) else { throw CancellationError() }
            if let attribution {
                guard attribution.adopt(lease,owner: owner) else { throw LiveProtocolError.invalidConfiguration }
                if !lease.attributionEnabled { attribution.seal() }
                await attribution.retireUnstartedIfSealed()
            }
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
            await complete(PrivacyTrace.outcome(for: error),owner: owner)?.value
            // A sealed admission may have returned before it could install into
            // pending ownership. Exact receipts make repeated release harmless.
            if let admitted { await resources.release(admitted) }
            throw error
        }
    }

    func validatePreparedStart(_ prepared: Prepared, owner: UUID? = nil) async throws {
        guard matches(prepared,owner: owner) else { throw LiveProtocolError.invalidConfiguration }
        try check(owner)
        if let asrAssets { _ = try asrAssets.snapshot(owner: id).validateCurrentPath(); try check(owner) }
        try vadAssets?.validate(owner: id); try check(owner)
        await attribution?.retireUnstartedIfSealed()
        let token = await resources.measurementToken(); try check(owner)
        let measurement = try await currentMemory(); try check(owner)
        try await resources.validatePreparedStart(prepared.lease,measurement: measurement,token: token)
        try check(owner)
    }

    /// Called in the core's nonsuspending dispatch transition. Success moves
    /// cleanup authority out of pending state; only native shutdown returns it.
    nonisolated func claimTransfer(_ prepared: Prepared, owner: UUID) -> Bool {
        matches(prepared,owner: owner) && (asrAssets.map { (try? $0.snapshot(owner: id)) != nil } ?? true) &&
            ((try? vadAssets?.validate(owner: id)) != nil || vadAssets == nil) &&
            state.claim(prepared.lease,owner: owner,ingress: ingress)
    }

    /// Only the transferred exact core owner, after actual transport exit, can
    /// retire native assets. Privacy completion has no such authority.
    @discardableResult nonisolated func retireNativeAssets(owner: UUID) -> Task<Void,Never>? {
        guard state.retireNativeAssets(owner: owner) else { return nil }
        let asr = asrAssets?.retire(owner: id), vad = vadAssets?.retire(owner: id)
        guard asr != nil || vad != nil else { return nil }
        return Task { await asr?.value; await vad?.value }
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
