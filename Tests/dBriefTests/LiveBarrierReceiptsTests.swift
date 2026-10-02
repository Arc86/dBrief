import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite struct LiveBarrierReceiptsTests {
    private func barrier(epoch: UUID = UUID(), source: LiveSource = .microphone) -> LiveFinishBarrier {
        .init(scope: .init(identity: .init(recordingID: UUID(),captureSessionID: UUID()),source: source,epochID: epoch),nextPacketSequence: 3,sampleEnd: 4800,kind: .pause)
    }

    @Test func completionRequiresTheOriginalRequestAndEveryAvailableScopeField() throws {
        var ledger = LiveBarrierReceipts()
        let id = UUID(), original = barrier()
        try ledger.reserve(id,barrier: original)
        try ledger.reply(id,value: .accepted)
        let foreignIdentity = LiveLaneScope(identity: .init(recordingID: UUID(),captureSessionID: original.scope.identity.captureSessionID),source: .microphone,epochID: original.scope.epochID)
        let foreignSource = LiveLaneScope(identity: original.scope.identity,source: .system,epochID: original.scope.epochID)
        let foreignEpoch = LiveLaneScope(identity: original.scope.identity,source: .microphone,epochID: UUID())
        for scope in [foreignIdentity,foreignSource,foreignEpoch] {
            #expect(throws: MLHostError.protocolViolation) { try ledger.complete(id,scope: scope,kind: .pause,end: 4800) }
        }
        #expect(throws: MLHostError.protocolViolation) { try ledger.complete(UUID(),scope: original.scope,kind: .pause,end: 4800) }
        #expect(throws: MLHostError.protocolViolation) { try ledger.complete(id,scope: original.scope,kind: .finish,end: 4800) }
        #expect(throws: MLHostError.protocolViolation) { try ledger.complete(id,scope: original.scope,kind: .pause,end: 4801) }
        try ledger.complete(id,scope: original.scope,kind: .pause,end: 4800)
        #expect(ledger.canPublish(id))
        try ledger.published(id)
        #expect(ledger.count == 0)
        #expect(throws: MLHostError.protocolViolation) { try ledger.complete(id,scope: original.scope,kind: .pause,end: 4800) }
    }

    @Test func completionBeforeAcceptanceCannotPublishOrBeDuplicated() throws {
        var ledger = LiveBarrierReceipts()
        let id = UUID(), original = barrier()
        try ledger.reserve(id,barrier: original)
        try ledger.complete(id,scope: original.scope,kind: .pause,end: 4800)
        #expect(!ledger.canPublish(id))
        #expect(throws: MLHostError.protocolViolation) { try ledger.published(id) }
        #expect(throws: MLHostError.protocolViolation) { try ledger.complete(id,scope: original.scope,kind: .pause,end: 4800) }
        #expect(throws: MLHostError.protocolViolation) { try ledger.reply(id,value: .rejected(.unavailable)) }
        try ledger.reply(id,value: .accepted)
        #expect(ledger.canPublish(id))
        try ledger.published(id)
    }

    @Test func rejectionAndPreviousCompletionCannotClaimAnIdenticalLaterBarrier() throws {
        var ledger = LiveBarrierReceipts()
        let rejected = UUID(), completed = UUID(), next = UUID(), original = barrier()
        try ledger.reserve(rejected,barrier: original)
        try ledger.reply(rejected,value: .rejected(.outOfOrder))
        try ledger.reserve(completed,barrier: original)
        try ledger.reply(completed,value: .accepted)
        try ledger.complete(completed,scope: original.scope,kind: .pause,end: 4800)
        try ledger.published(completed)
        try ledger.reserve(next,barrier: original)
        try ledger.reply(next,value: .accepted)
        for stale in [rejected,completed] {
            #expect(throws: MLHostError.protocolViolation) { try ledger.complete(stale,scope: original.scope,kind: .pause,end: 4800) }
        }
        #expect(!ledger.canPublish(next) && ledger.count == 1)
    }

    @Test func receiptLimitAndRetirementPreserveTheOtherEpoch() throws {
        var ledger = LiveBarrierReceipts()
        let old = barrier(), other = barrier(source: .system), otherID = UUID()
        try ledger.reserve(otherID,barrier: other)
        try ledger.reply(otherID,value: .accepted)
        for _ in 1..<LiveBarrierReceipts.limit { try ledger.reserve(UUID(),barrier: old) }
        #expect(ledger.count == 128)
        #expect(throws: MLHostError.protocolViolation) { try ledger.reserve(UUID(),barrier: old) }
        ledger.retire(old.scope.epochID)
        #expect(ledger.count == 1)
        try ledger.complete(otherID,scope: other.scope,kind: .pause,end: 4800)
        #expect(ledger.canPublish(otherID))
        try ledger.published(otherID)
        #expect(ledger.count == 0)
    }
}
