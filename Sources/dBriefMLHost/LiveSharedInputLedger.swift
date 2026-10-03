import Foundation
import dBriefWire

struct LiveSharedPacketReceipt: Sendable, Equatable {
    let scope: LiveLaneScope
    let startSample: Int64
    let sampleEnd: Int64
    fileprivate let producerID: UUID
    fileprivate let id: UUID
    fileprivate init(scope: LiveLaneScope,start: Int64,end: Int64,producerID: UUID) {
        self.scope = scope; startSample = start; sampleEnd = end
        self.producerID = producerID; id = UUID()
    }
}
struct LiveSharedPacketToken: Sendable, Equatable {
    let scope: LiveLaneScope
    let startSample: Int64
    let sampleEnd: Int64
    fileprivate let producerID: UUID
    fileprivate let id = UUID()
    fileprivate init(_ receipt: LiveSharedPacketReceipt) {
        scope = receipt.scope; startSample = receipt.startSample; sampleEnd = receipt.sampleEnd
        producerID = receipt.producerID
    }
}
struct LiveSharedInputProgress: Sendable, Equatable {
    let scope: LiveLaneScope
    let admittedEnd: Int64, issuedEnd: Int64, returnedEnd: Int64
    let asrSubmittedEnd: Int64, asrAppendedEnd: Int64, asrConsumedEnd: Int64, lastASRFinishedEnd: Int64
    let vadProcessedEnd: Int64, consumedEnd: Int64
    let queuedSamples: Int64, inFlightSamples: Int64, heldSamples: Int64, pendingSamples: Int64, creditSamples: Int64
    let vadInputActive: Bool, sealed: Bool
}

/// Metadata only. The enclosing owner validates PCM and waits actual packet
/// Task.value before recording return. Native results and module status cannot
/// substitute for that proof. No method grants a wire ACK or allocation refund.
struct LiveSharedInputLedger: Sendable, Equatable {
    let scope: LiveLaneScope
    private let producerID = UUID()
    private let vadOwnerID: UUID
    private let pendingLimit: Int64
    private var admittedEnd: Int64 = 0, issuedEnd: Int64 = 0, returnedEnd: Int64 = 0
    private var asrSubmittedEnd: Int64 = 0, asrAppendedEnd: Int64 = 0, asrConsumedEnd: Int64 = 0
    private var lastASRFinishedEnd: Int64 = 0, vadProcessedEnd: Int64 = 0
    private var receipts: [LiveSharedPacketReceipt] = []
    private var current: LiveSharedPacketToken?
    private var vadInputActive = true, sealed = false

    init(scope: LiveLaneScope,configuration: LiveASRConfiguration,vadOwnerID: UUID) throws {
        guard scope.source.isCaptureSource, configuration.isValid else { throw LiveProtocolError.invalidConfiguration }
        self.scope = scope; self.vadOwnerID = vadOwnerID; pendingLimit = Int64(configuration.pendingSampleLimit)
    }
    var progress: LiveSharedInputProgress {
        let consumed = min(asrConsumedEnd,returnedEnd,vadInputActive ? vadProcessedEnd : returnedEnd)
        let queued = admittedEnd-issuedEnd, flight = issuedEnd-returnedEnd, held = returnedEnd-consumed
        let pending = admittedEnd-consumed
        return .init(scope: scope,admittedEnd: admittedEnd,issuedEnd: issuedEnd,returnedEnd: returnedEnd,
            asrSubmittedEnd: asrSubmittedEnd,asrAppendedEnd: asrAppendedEnd,asrConsumedEnd: asrConsumedEnd,
            lastASRFinishedEnd: lastASRFinishedEnd,vadProcessedEnd: vadProcessedEnd,consumedEnd: consumed,
            queuedSamples: queued,inFlightSamples: flight,heldSamples: held,pendingSamples: pending,
            creditSamples: sealed ? 0 : pendingLimit-pending,vadInputActive: vadInputActive,sealed: sealed)
    }
    private func checkScope(_ scope: LiveLaneScope) throws {
        guard scope == self.scope else { throw LiveProtocolError.staleScope }
    }
    private func checkActive(_ scope: LiveLaneScope) throws {
        try checkScope(scope)
        guard !sealed else { throw LiveProtocolError.closed }
    }
    private func checkToken(_ token: LiveSharedPacketToken,active: Bool = true) throws {
        if active { try checkActive(token.scope) } else { try checkScope(token.scope) }
        guard token.producerID == producerID, current == token else { throw LiveProtocolError.outOfOrder }
    }
    mutating func admit(scope: LiveLaneScope,startSample: Int64,sampleCount: Int) throws -> LiveSharedPacketReceipt {
        try checkActive(scope)
        let end = startSample.addingReportingOverflow(Int64(sampleCount))
        guard (1...3200).contains(sampleCount), startSample == admittedEnd, !end.overflow else { throw LiveProtocolError.invalidPacket }
        guard receipts.count < 64, progress.pendingSamples+Int64(sampleCount) <= pendingLimit else { throw LiveProtocolError.unavailable }
        let receipt = LiveSharedPacketReceipt(scope: scope,start: startSample,end: end.partialValue,producerID: producerID)
        receipts.append(receipt); admittedEnd = end.partialValue
        return receipt
    }
    mutating func startPacket(_ receipt: LiveSharedPacketReceipt,startSample: Int64,sampleCount: Int) throws -> LiveSharedPacketToken {
        try checkActive(receipt.scope)
        let end = startSample.addingReportingOverflow(Int64(sampleCount))
        guard current == nil, receipt.producerID == producerID, receipts.first == receipt,
              (1...3200).contains(sampleCount), !end.overflow, startSample == receipt.startSample,
              end.partialValue == receipt.sampleEnd, startSample == issuedEnd, issuedEnd == returnedEnd else {
            throw LiveProtocolError.outOfOrder
        }
        let token = LiveSharedPacketToken(receipt)
        receipts.removeFirst(); issuedEnd = receipt.sampleEnd; current = token
        return token
    }
    /// Called immediately before native append to bound partial callbacks.
    mutating func submitSlice(_ token: LiveSharedPacketToken,range: Range<Int64>) throws {
        try checkToken(token)
        guard asrSubmittedEnd == asrAppendedEnd, !range.isEmpty, range.lowerBound == asrAppendedEnd,
              range.lowerBound >= token.startSample, range.upperBound <= token.sampleEnd,
              range.upperBound-range.lowerBound <= 3200 else { throw LiveProtocolError.outOfOrder }
        asrSubmittedEnd = range.upperBound
    }
    mutating func recordASRAppend(_ token: LiveSharedPacketToken,processedEnd: Int64,consumedEnd: Int64) throws {
        try checkToken(token)
        guard asrSubmittedEnd > asrAppendedEnd, processedEnd == asrSubmittedEnd,
              consumedEnd >= asrConsumedEnd, consumedEnd <= processedEnd else { throw LiveProtocolError.outOfOrder }
        asrAppendedEnd = processedEnd; asrConsumedEnd = consumedEnd
    }
    /// Successful finish releases ASR input, independently of VAD and packet.
    mutating func recordASRFlush(scope: LiveLaneScope,sampleEnd: Int64) throws {
        try checkActive(scope)
        guard asrSubmittedEnd == asrAppendedEnd, sampleEnd == asrAppendedEnd,
              sampleEnd > lastASRFinishedEnd else { throw LiveProtocolError.outOfOrder }
        lastASRFinishedEnd = sampleEnd; asrConsumedEnd = sampleEnd
    }
    mutating func recordVADProcessed(_ token: LiveSharedPacketToken,sampleEnd: Int64) throws {
        try checkToken(token)
        let next = vadProcessedEnd.addingReportingOverflow(Int64(LiveVADIdentity.windowSamples))
        guard vadInputActive, !next.overflow, sampleEnd == next.partialValue,
              sampleEnd > token.startSample, sampleEnd <= token.sampleEnd,
              sampleEnd <= asrAppendedEnd else { throw LiveProtocolError.outOfOrder }
        vadProcessedEnd = sampleEnd
    }
    /// Omit only an actually retired failed consumer from this fixed runtime.
    /// A clean input cut remains a separate all-consumer retirement operation.
    mutating func recordFailedVADRetirement(_ proof: LiveVADInputRetiredProof) throws {
        try checkActive(proof.scope)
        guard vadInputActive, proof.runtimeOwnerID == vadOwnerID, proof.nativeFailureSeen,
              proof.processedEnd == vadProcessedEnd else { throw LiveProtocolError.outOfOrder }
        vadInputActive = false
    }
    /// Sole caller is the owner after matching outer Work.task.value. This
    /// token carries no actual-return authority by itself.
    mutating func recordActualPacketReturn(_ token: LiveSharedPacketToken) throws {
        try checkToken(token,active: false)
        guard sealed || (asrSubmittedEnd == token.sampleEnd && asrAppendedEnd == token.sampleEnd) else {
            throw LiveProtocolError.outOfOrder
        }
        returnedEnd = token.sampleEnd; current = nil
    }
    mutating func seal(scope: LiveLaneScope) throws {
        try checkScope(scope); sealed = true
    }
}

/// PCM-free cursor; the enclosing task owns the whole original array until
/// actual return and performs any native boundary finish before the next slice.
struct LivePacketSliceCursor: Sendable, Equatable {
    let token: LiveSharedPacketToken
    private(set) var nextSample: Int64
    private var proposed: Range<Int64>?
    init(token: LiveSharedPacketToken) { self.token = token; nextSample = token.startSample }
    var isComplete: Bool { nextSample == token.sampleEnd }
    mutating func nextRange(vadCapacity: Int) throws -> Range<Int64> {
        guard proposed == nil, !isComplete, (1...3200).contains(vadCapacity) else { throw LiveProtocolError.outOfOrder }
        let end = nextSample+min(Int64(vadCapacity),token.sampleEnd-nextSample)
        let range = nextSample..<end; proposed = range; return range
    }
    mutating func commit(_ range: Range<Int64>) throws {
        guard proposed == range else { throw LiveProtocolError.outOfOrder }
        nextSample = range.upperBound; proposed = nil
    }
}
