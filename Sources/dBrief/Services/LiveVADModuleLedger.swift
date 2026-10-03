import Foundation
import dBriefWire

/// One owner per helper connection, retained across accepted outer epochs.
/// It validates portable metadata only. The connection establishes ordering;
/// actual native ownership/retirement and resource actions remain separate.
struct LiveVADModuleLedger: Sendable, Equatable {
    enum Phase: Sendable, Equatable { case unknown, preparing, active, degraded, retired }
    struct Status: Sendable, Equatable {
        var scope: LiveLaneScope
        var phase: Phase = .unknown
        var contextID: UUID?
        var processedEnd: Int64 = 0
        var nativeFailureSeen = false
        var modelReadySeen = false
    }

    let identity: LiveSessionIdentity
    let configuration: LiveVADIdentity
    private var sources: [LiveSource: Status]

    init(input: LiveSessionBegin) throws {
        guard input.isValid, let vad = input.vad else { throw LiveProtocolError.invalidConfiguration }
        identity = input.identity; configuration = vad.identity
        sources = Dictionary(uniqueKeysWithValues: input.epochs.map {
            ($0.source,Status(scope: .init(identity: input.identity,source: $0.source,epochID: $0.id)))
        })
    }

    func status(for source: LiveSource) -> Status? { sources[source] }
    /// Historical ready facts survive operational degradation/retirement.
    /// No allocation or job permit is changed by this predicate.
    var allModelsReady: Bool { sources.values.allSatisfy(\.modelReadySeen) }

    mutating func observe(scope: LiveLaneScope, event: LiveVADModuleEvent, admittedEnd: Int64) throws {
        guard var source = sources[scope.source], source.scope == scope else { throw LiveProtocolError.staleScope }
        guard event.identity.isValid, event.identity == configuration else { throw LiveProtocolError.invalidConfiguration }
        guard admittedEnd >= source.processedEnd else { throw LiveProtocolError.outOfOrder }
        // Mutate only a local value until every field and peer reservation has
        // been checked; rejection leaves both sources and sticky facts intact.
        switch event {
        case .preparing:
            guard source.phase == .unknown, !source.nativeFailureSeen else { throw LiveProtocolError.outOfOrder }
            source.phase = .preparing
        case .ready(_,let context,let origin):
            guard source.phase == .preparing, !source.nativeFailureSeen, origin == 0,
                  !sources.contains(where: { $0.key != scope.source && $0.value.contextID == context }) else {
                throw LiveProtocolError.outOfOrder
            }
            source.phase = .active; source.contextID = context; source.modelReadySeen = true
        case .processed(_,let context,let end):
            let next = source.processedEnd.addingReportingOverflow(Int64(LiveVADIdentity.windowSamples))
            guard source.phase == .active, !source.nativeFailureSeen, source.contextID == context,
                  !next.overflow, end == next.partialValue, end <= admittedEnd else { throw LiveProtocolError.outOfOrder }
            source.processedEnd = end
        case .degraded(_,let context,let end):
            guard source.phase != .degraded, source.canSeal(context: context,end: end) else { throw LiveProtocolError.outOfOrder }
            source.phase = .degraded; source.nativeFailureSeen = true
        case .retired(_,let context,let end):
            guard source.canSeal(context: context,end: end) else { throw LiveProtocolError.outOfOrder }
            source.phase = .retired
        }
        sources[scope.source] = source
    }

    /// Call only after existing transport accepts the replacement whose helper
    /// independently proved all-consumer retirement. Logical retired metadata
    /// is a necessary ordering condition, never that actual cleanup proof.
    mutating func installAcceptedReplacement(oldScope: LiveLaneScope, newScope: LiveLaneScope) throws {
        guard let old = sources[oldScope.source], old.scope == oldScope else { throw LiveProtocolError.staleScope }
        guard old.phase == .retired, newScope.identity == identity, newScope.source == oldScope.source,
              newScope.epochID != oldScope.epochID,
              !sources.contains(where: { $0.key != oldScope.source && $0.value.scope.epochID == newScope.epochID }) else {
            throw LiveProtocolError.outOfOrder
        }
        var next = Status(scope: newScope)
        next.nativeFailureSeen = old.nativeFailureSeen; next.modelReadySeen = old.modelReadySeen
        sources[oldScope.source] = next
    }
}

private extension LiveVADModuleLedger.Status {
    func canSeal(context: UUID?, end: Int64) -> Bool {
        switch phase {
        case .unknown, .preparing: context == nil && end == 0
        case .active, .degraded: context == contextID && end == processedEnd
        case .retired: false
        }
    }
}
