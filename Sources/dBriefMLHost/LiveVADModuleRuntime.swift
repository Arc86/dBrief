import Foundation
import dBriefWire

enum LiveVADRuntimeError: Error, Equatable { case inactive, overlap, invalidSlice }
enum LiveVADRuntimePhase: Sendable, Equatable { case unknown, active, degraded, retired }
struct LiveVADRuntimeProgress: Sendable, Equatable {
    let scope: LiveLaneScope
    let phase: LiveVADRuntimePhase
    let contextID: UUID?
    let bufferedEnd: Int64
    let processedEnd: Int64
    let remainderSamples: Int
    let hasWork: Bool
    let completionClaimed: Bool
    let inputRetired: Bool
    let nativeFailureSeen: Bool
    let modelReadySeen: Bool
}
struct LiveVADRuntimeToken: Sendable, Equatable {
    let scope: LiveLaneScope
    fileprivate let id: UUID
    fileprivate init(scope: LiveLaneScope, id: UUID) { self.scope = scope; self.id = id }
}
enum LiveVADRuntimeAdmission: Sendable {
    case buffered(LiveVADRuntimeProgress), window(LiveVADRuntimeToken)
}
enum LiveVADRuntimeCompletion: Sendable {
    case processed(LiveVADModuleEvent, LiveVADBoundaryDecision)
    case degraded(LiveVADModuleEvent, LiveVADRuntimeRetirement)
}

/// Arbitrary SDK errors can own native input. Normalize inside the child body
/// so its cached result and PCM-free completion never retain such an error.
private enum LiveVADNativeWorkOutcome: Sendable {
    case completed(LiveVADWindowResult), failed
}

/// Await-only: cancellation of a waiter cannot cancel native input cleanup.
/// This proves only VAD-owned input, excluding the enclosing original packet.
final class LiveVADRuntimeRetirement: Sendable {
    let scope: LiveLaneScope
    fileprivate let id = UUID()
    fileprivate let workID: UUID?
    private let cleanup: Task<Void, Never>
    fileprivate init(scope: LiveLaneScope, workID: UUID?, window: LiveVADWindowSession?,
                     native: Task<LiveVADNativeWorkOutcome, Never>?, pool: LiveVADModelFactory?) {
        self.scope = scope; self.workID = workID
        cleanup = Task {
            defer { withExtendedLifetime(pool) {} }
            await window?.retire()
            if let native { _ = await native.value }
        }
    }
    func wait() async { await cleanup.value }
}
struct LiveVADRuntimeSeal: Sendable {
    let contextID: UUID?
    let processedEnd: Int64
    let firstSeal: Bool
    let receipt: LiveVADRuntimeRetirement
}

/// One fixed pool per helper lifetime. Source input has separate continuity and
/// retirement; no model is unloaded/reloaded when a source fails or is replaced.
/// These private results neither sequence wire frames nor release common credit.
actor LiveVADModuleRuntime {
    private struct Work: Sendable {
        let token: LiveVADRuntimeToken
        let task: Task<LiveVADNativeWorkOutcome, Never>
        var claimed = false
    }
    private struct Source {
        let scope: LiveLaneScope
        var phase = LiveVADRuntimePhase.unknown
        var contextID: UUID?
        var window: LiveVADWindowSession?
        var policy: LiveVADBoundaryPolicy?
        var remainder: [Float] = []
        var bufferedEnd: Int64 = 0, processedEnd: Int64 = 0
        var work: Work?
        var retirement: LiveVADRuntimeRetirement?
        var inputRetired = false, nativeFailureSeen = false, modelReadySeen = false
        var progress: LiveVADRuntimeProgress {
            .init(scope: scope,phase: phase,contextID: contextID,bufferedEnd: bufferedEnd,processedEnd: processedEnd,
                remainderSamples: remainder.count,hasWork: work != nil,completionClaimed: work?.claimed == true,inputRetired: inputRetired,
                nativeFailureSeen: nativeFailureSeen,modelReadySeen: modelReadySeen)
        }
    }
    private let identity: LiveSessionIdentity
    private let configuration: LiveVADConfiguration
    private let factory: LiveVADModelFactory?
    private let testingBeforeCommit: @Sendable (LiveLaneScope) async -> Void
    private let testingBeforeResult: @Sendable (LiveLaneScope) async -> Void
    private var sources: [LiveSource: Source]

    init(input: LiveSessionBegin, factory: LiveVADModelFactory?,
         testingBeforeCommit: @escaping @Sendable (LiveLaneScope) async -> Void = { _ in },
         testingBeforeResult: @escaping @Sendable (LiveLaneScope) async -> Void = { _ in }) throws {
        guard input.isValid, let configuration = input.vad else { throw LiveProtocolError.invalidConfiguration }
        _ = try LiveVADNativeConfiguration(configuration)
        if let factory {
            guard Set(factory.handles.keys) == Set(input.epochs.map(\.source)),
                  factory.handles.values.allSatisfy({ $0.assets.configuration == configuration }) else {
                throw LiveProtocolError.invalidConfiguration
            }
        }
        identity = input.identity; self.configuration = configuration; self.factory = factory
        self.testingBeforeCommit = testingBeforeCommit
        self.testingBeforeResult = testingBeforeResult
        sources = Dictionary(uniqueKeysWithValues: input.epochs.map {
            var source = Source(scope: .init(identity: input.identity,source: $0.source,epochID: $0.id))
            source.nativeFailureSeen = factory == nil
            return ($0.source,source)
        })
    }

    private func source(_ scope: LiveLaneScope) throws -> Source {
        guard let source = sources[scope.source], source.scope == scope else { throw LiveProtocolError.staleScope }
        return source
    }
    func progress(scope: LiveLaneScope) throws -> LiveVADRuntimeProgress { try source(scope).progress }
    func activate(scope: LiveLaneScope) throws -> LiveVADModuleEvent {
        try Task.checkCancellation()
        var source = try source(scope)
        guard source.phase == .unknown else { throw LiveVADRuntimeError.inactive }
        if source.nativeFailureSeen {
            source.phase = .degraded; sources[scope.source] = source
            return .degraded(identity: configuration.identity,contextID: nil,sampleEnd: 0)
        }
        guard let predictor = factory?.handles[scope.source] else { throw LiveProtocolError.invalidConfiguration }
        let window = try LiveVADWindowSession(source: scope.source,predictor: predictor)
        let policy = try LiveVADBoundaryPolicy(identity: configuration.identity,source: scope.source,continuityID: window.continuityID)
        source.window = window; source.policy = policy; source.contextID = window.continuityID
        source.phase = .active; source.modelReadySeen = true; sources[scope.source] = source
        return .ready(identity: configuration.identity,contextID: window.continuityID,originSample: 0)
    }
    func sliceCapacity(scope: LiveLaneScope) throws -> Int {
        let source = try source(scope)
        guard source.phase == .active else { throw LiveVADRuntimeError.inactive }
        return source.work == nil ? min(3200,LiveVADIdentity.windowSamples-source.remainder.count) : 0
    }

    /// No suspension holds the assembled window in this frame. Its only VAD
    /// owner after return is the captured native task/window, not completion.
    func admitSlice(scope: LiveLaneScope, samples: [Float], startSample: Int64) throws -> LiveVADRuntimeAdmission {
        try Task.checkCancellation()
        var source = try source(scope)
        guard source.phase == .active else { throw LiveVADRuntimeError.inactive }
        guard source.work == nil else { throw LiveVADRuntimeError.overlap }
        let end = startSample.addingReportingOverflow(Int64(samples.count))
        let edge = source.processedEnd.addingReportingOverflow(Int64(LiveVADIdentity.windowSamples))
        guard startSample == source.bufferedEnd, (1...3200).contains(samples.count), samples.allSatisfy(\.isFinite),
              !end.overflow, !edge.overflow, end.partialValue <= edge.partialValue else { throw LiveVADRuntimeError.invalidSlice }
        source.remainder.append(contentsOf: samples); source.bufferedEnd = end.partialValue
        if source.remainder.count < LiveVADIdentity.windowSamples {
            sources[scope.source] = source; return .buffered(source.progress)
        }
        guard let window = source.window else { throw LiveVADRuntimeError.inactive }
        let fullWindow = source.remainder, origin = source.processedEnd, pool = factory
        source.remainder = []
        let token = LiveVADRuntimeToken(scope: scope,id: UUID())
        let task = Task {
            defer { withExtendedLifetime(pool) {} }
            do { return LiveVADNativeWorkOutcome.completed(try await window.process(samples: fullWindow,startSample: origin)) }
            catch { return LiveVADNativeWorkOutcome.failed }
        }
        source.work = .init(token: token,task: task); sources[scope.source] = source
        return .window(token)
    }

    private func claim(_ token: LiveVADRuntimeToken) throws -> Work {
        var source = try source(token.scope)
        guard source.phase == .active else { throw LiveVADRuntimeError.inactive }
        guard var work = source.work, work.token == token, !work.claimed else { throw LiveProtocolError.outOfOrder }
        if Task.isCancelled { cancelReservation(token); throw CancellationError() }
        work.claimed = true; source.work = work; sources[token.scope.source] = source
        return work
    }
    /// Work and result are PCM-free. One claim per token; the actual child
    /// return precedes either a synchronous whole-result commit or clean seal.
    func complete(_ token: LiveVADRuntimeToken) async throws -> LiveVADRuntimeCompletion {
        let work = try claim(token)
        return try await withTaskCancellationHandler {
            do {
                await testingBeforeResult(token.scope)
                let outcome = await work.task.value
                await testingBeforeCommit(token.scope)
                try Task.checkCancellation()
                switch outcome {
                case .completed(let result): return try accept(result,token: token)
                case .failed: return try degrade(token)
                }
            } catch {
                if Task.isCancelled { cancelReservation(token); throw CancellationError() }
                return try degrade(token)
            }
        } onCancel: {
            work.task.cancel()
            Task { await self.cancelReservation(token) }
        }
    }
    private func accept(_ result: LiveVADWindowResult, token: LiveVADRuntimeToken) throws -> LiveVADRuntimeCompletion {
        var source = try source(token.scope)
        guard source.phase == .active, source.work?.token == token else { throw LiveVADRuntimeError.inactive }
        guard var policy = source.policy else { throw LiveVADRuntimeError.inactive }
        let decision = try policy.observe(result)
        // Success linearizes here, without suspension after the final checks.
        source.policy = policy; source.processedEnd = result.sampleEnd; source.work = nil
        sources[token.scope.source] = source
        return .processed(.processed(identity: configuration.identity,contextID: result.continuityID,sampleEnd: result.sampleEnd),decision)
    }
    private func degrade(_ token: LiveVADRuntimeToken) throws -> LiveVADRuntimeCompletion {
        var source = try source(token.scope)
        guard source.phase == .active, source.work?.token == token else { throw LiveVADRuntimeError.inactive }
        source.phase = .degraded; source.nativeFailureSeen = true
        let receipt = retirement(for: &source); sources[token.scope.source] = source
        return .degraded(.degraded(identity: configuration.identity,contextID: source.contextID,sampleEnd: source.processedEnd),receipt)
    }
    private func cancelReservation(_ token: LiveVADRuntimeToken) {
        guard let source = sources[token.scope.source], source.scope == token.scope,
              source.phase == .active, source.work?.token == token else { return }
        _ = try? retireInput(scope: token.scope)
    }
    private func retirement(for source: inout Source) -> LiveVADRuntimeRetirement {
        source.remainder = []
        source.work?.task.cancel()
        if let receipt = source.retirement { return receipt }
        let receipt = LiveVADRuntimeRetirement(scope: source.scope,workID: source.work?.token.id,
            window: source.window,native: source.work?.task,pool: factory)
        source.retirement = receipt; return receipt
    }
    func retireInput(scope: LiveLaneScope) throws -> LiveVADRuntimeSeal {
        var source = try source(scope)
        let first = source.phase != .retired
        source.phase = .retired
        let receipt = retirement(for: &source); sources[scope.source] = source
        return .init(contextID: source.contextID,processedEnd: source.processedEnd,firstSeal: first,receipt: receipt)
    }
    func settleRetirement(_ receipt: LiveVADRuntimeRetirement) async throws {
        guard try source(receipt.scope).retirement === receipt else { throw LiveProtocolError.staleScope }
        await receipt.wait() // Cancellation never substitutes for actual return.
        var source = try source(receipt.scope)
        guard source.retirement === receipt else { throw LiveProtocolError.staleScope }
        if source.inputRetired { return }
        if let work = source.work {
            guard work.token.id == receipt.workID else { throw LiveProtocolError.staleScope }
        }
        source.window = nil; source.policy = nil; source.work = nil; source.remainder = []
        source.bufferedEnd = source.processedEnd; source.inputRetired = true
        sources[receipt.scope.source] = source
    }
    /// The enclosing owner must separately join actual ASR/original-packet
    /// Work before accepting a wire replacement; this checks VAD input only.
    func installAfterRetirement(oldScope: LiveLaneScope, newScope: LiveLaneScope) throws {
        let old = try source(oldScope)
        guard old.phase == .retired, old.inputRetired else { throw LiveProtocolError.unavailable }
        guard newScope.identity == identity, newScope.source == oldScope.source, newScope.epochID != oldScope.epochID,
              !sources.contains(where: { $0.key != oldScope.source && $0.value.scope.epochID == newScope.epochID }) else {
            throw LiveProtocolError.outOfOrder
        }
        var next = Source(scope: newScope)
        next.nativeFailureSeen = old.nativeFailureSeen; next.modelReadySeen = old.modelReadySeen
        sources[oldScope.source] = next
    }
}
