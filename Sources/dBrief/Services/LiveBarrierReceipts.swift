import Foundation
import dBriefWire

/// The command reply inbox may finish before the native barrier completes.
/// Keep the original request proof until both acceptance and publication.
struct LiveBarrierReceipts {
    static let limit = 128
    private struct Receipt {
        let barrier: LiveFinishBarrier
        var accepted = false
        var completed = false
    }
    private var receipts: [UUID: Receipt] = [:]
    var count: Int { receipts.count }

    mutating func reserve(_ id: UUID, barrier: LiveFinishBarrier) throws {
        guard receipts[id] == nil, receipts.count < Self.limit else { throw MLHostError.protocolViolation }
        receipts[id] = .init(barrier: barrier)
    }

    mutating func reply(_ id: UUID, value: LiveSessionReply) throws {
        guard var receipt = receipts[id], !receipt.accepted else { throw MLHostError.protocolViolation }
        if value == .accepted {
            receipt.accepted = true; receipts[id] = receipt
        } else {
            guard !receipt.completed else { throw MLHostError.protocolViolation }
            receipts[id] = nil
        }
    }

    mutating func complete(_ id: UUID, scope: LiveLaneScope, kind: LiveFinishBarrier.Kind, end: Int64) throws {
        guard var receipt = receipts[id], !receipt.completed,
              receipt.barrier.scope == scope, receipt.barrier.kind == kind,
              receipt.barrier.sampleEnd == end else { throw MLHostError.protocolViolation }
        receipt.completed = true; receipts[id] = receipt
    }

    func canPublish(_ id: UUID) -> Bool { receipts[id]?.accepted == true && receipts[id]?.completed == true }

    mutating func published(_ id: UUID) throws {
        guard canPublish(id) else { throw MLHostError.protocolViolation }
        receipts[id] = nil
    }

    mutating func retire(_ epochID: UUID) { receipts = receipts.filter { $0.value.barrier.scope.epochID != epochID } }
    mutating func removeAll() { receipts.removeAll() }
}
