import Foundation

/// Reservations follow the payload's actual lifetime, including retired tasks
/// and externally frozen owners. Removing a registry entry does not return it.
final class LiveRecordingPayloadBudget: @unchecked Sendable {
    final class Lease: @unchecked Sendable {
        private let budget: LiveRecordingPayloadBudget
        fileprivate init(_ budget: LiveRecordingPayloadBudget) { self.budget = budget }
        deinit { budget.release() }
    }
    private let lock = NSLock()
    private let ownerLimit: Int
    private var owners = 0
    private let reservation = LiveRecordingArtifactOwner.reservationBytes
    init(ownerLimit: Int) { self.ownerLimit = min(8, max(1, ownerLimit)) }
    var reservedBytes: Int { lock.withLock { owners * reservation } }
    var canReserve: Bool { lock.withLock { owners < ownerLimit && owners < 128 * 1_024 * 1_024 / reservation } }
    func reserve() throws -> Lease {
        try lock.withLock {
            guard owners < ownerLimit, owners < 128 * 1_024 * 1_024 / reservation else { throw LiveRecordingSessionRegistry.Failure.capacity }
            owners += 1; return Lease(self)
        }
    }
    private func release() { lock.withLock { owners -= 1 } }
}

final class LiveArtifactPinCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var pins = 0
    var count: Int { lock.withLock { pins } }
    func add() { lock.withLock { pins += 1 } }
    func remove() { lock.withLock { pins -= 1 } }
}
