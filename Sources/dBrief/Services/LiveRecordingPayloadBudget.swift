import Foundation

/// Reservations follow the payload's actual lifetime, including retired tasks
/// and externally frozen owners. Removing a registry entry does not return it.
final class LiveRecordingPayloadBudget: @unchecked Sendable {
    final class Lease: @unchecked Sendable {
        private let budget: LiveRecordingPayloadBudget
        private let bytes: Int
        private let owner: Bool
        fileprivate init(_ budget: LiveRecordingPayloadBudget, bytes: Int, owner: Bool) {
            self.budget = budget; self.bytes = bytes; self.owner = owner
        }
        deinit { budget.release(bytes: bytes, owner: owner) }
    }
    private let lock = NSLock()
    private let ownerLimit: Int
    private var owners = 0
    private var bytes = 0
    private let reservation = LiveRecordingArtifactOwner.reservationBytes
    private let limit = 128 * 1_024 * 1_024
    init(ownerLimit: Int) { self.ownerLimit = min(8, max(1, ownerLimit)) }
    var reservedBytes: Int { lock.withLock { bytes } }
    var canReserve: Bool { lock.withLock { owners < ownerLimit && bytes <= limit - reservation } }
    func reserve() throws -> Lease {
        try lock.withLock {
            guard owners < ownerLimit, bytes <= limit - reservation else { throw LiveRecordingSessionRegistry.Failure.capacity }
            owners += 1; bytes += reservation; return Lease(self, bytes: reservation, owner: true)
        }
    }
    func reserveMaintenance() throws -> Lease {
        try lock.withLock {
            let charge = 3 * RecordingDeletionAuthority.ticketLimit + RecordingDeletionAuthority.inspectionAllowance
            guard bytes <= limit - charge else { throw LiveRecordingSessionRegistry.Failure.capacity }
            bytes += charge; return Lease(self, bytes: charge, owner: false)
        }
    }
    private func release(bytes charge: Int, owner: Bool) {
        lock.withLock { bytes -= charge; if owner { owners -= 1 } }
    }
}

final class LiveArtifactPinCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var pins = 0
    var count: Int { lock.withLock { pins } }
    func add() { lock.withLock { pins += 1 } }
    func remove() { lock.withLock { pins -= 1 } }
}
