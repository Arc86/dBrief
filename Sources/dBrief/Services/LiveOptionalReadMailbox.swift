import Foundation
import dBriefWire

/// Optional whole bodies have separate credit, one actual delivery and one wake.
/// Disabled/default traffic is dropped before either mandatory or optional decode.
final class LiveOptionalReadMailbox: @unchecked Sendable {
    static let maximumBytes = 4096
    static let maximumFrames = 8
    enum Offer { case ignored, accepted, overflow }
    private enum Mode { case disabled, active, sealed }
    final class Receipt: @unchecked Sendable {
        fileprivate let id: UUID
        private var storage: Data
        var data: Data { storage }
        private let owner: LiveOptionalReadMailbox
        fileprivate init(id: UUID, data: Data, owner: LiveOptionalReadMailbox) { self.id = id; storage = data; self.owner = owner }
        deinit {
            let n = storage.count; storage = Data()
            owner.released(id, bytes: n) // Actual backing dies before credit returns.
        }
    }
    private let lock = NSLock()
    private var mode = Mode.disabled
    private var frames: [Data] = []
    private var bytes = 0, count = 0
    private var inFlight: UUID?
    let wakes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let testingReceiptData: (@Sendable (Data, LiveOptionalReadMailbox) -> Data)?
    init(testingReceiptData: (@Sendable (Data, LiveOptionalReadMailbox) -> Data)? = nil) {
        self.testingReceiptData = testingReceiptData
        (wakes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    var residentBytes: Int { lock.withLock { bytes } }
    var residentFrames: Int { lock.withLock { count } }
    func activate() -> Bool { lock.withLock {
        guard mode == .disabled else { return false }; mode = .active; return true
    } }
    @discardableResult func offer(_ body: Data) -> Offer {
        let result: Offer = lock.withLock {
            guard mode == .active else { return .ignored }
            guard !body.isEmpty, body.count <= LiveOutputDemultiplexer.maximumOptionalBodyBytes,
                  count < Self.maximumFrames, body.count <= Self.maximumBytes - bytes else {
                mode = .sealed; return .overflow
            }
            frames.append(body); bytes += body.count; count += 1; return .accepted
        }
        if result == .accepted { continuation.yield(()) }
        return result
    }
    func take() -> Receipt? { lock.withLock {
        guard inFlight == nil, !frames.isEmpty else { return nil }
        let body = frames.removeFirst(), data = testingReceiptData?(body, self) ?? body
        precondition(data.count == body.count)
        let receipt = Receipt(id: UUID(), data: data, owner: self); inFlight = receipt.id; return receipt
    } }
    private func released(_ id: UUID, bytes n: Int) { lock.withLock {
        guard inFlight == id else { return }; bytes -= n; count -= 1; inFlight = nil
    } }
    func discardQueued() { lock.withLock {
        mode = .sealed; bytes -= frames.reduce(0) { $0 + $1.count }; count -= frames.count; frames.removeAll()
    } }
    func finish() { discardQueued(); continuation.finish() }
}

/// Separate pipe consumers cannot infer accepted authority from byte ordering.
/// Only the mandatory reply promotes a tentative exact epoch. One optional raw
/// delivery may wait here, keeping its receipt charged outside the ASR actor.
final class LiveOptionalEpochAuthority: @unchecked Sendable {
    private enum State { case candidate, accepted, rejected }
    private struct Entry { let epoch: LiveEpoch; var state: State; var waiter: CheckedContinuation<Bool, Never>? }
    let identity: LiveSessionIdentity
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var closed = false
    private var currentEpochID: UUID?
    init(_ input: LiveSessionBegin) {
        identity = input.identity
        for epoch in input.epochs where epoch.source == .system {
            entries[epoch.id] = .init(epoch: epoch, state: .accepted); currentEpochID = epoch.id
        }
    }
    var isOpen: Bool { lock.withLock { !closed } }
    func isCurrent(_ epoch: UUID) -> Bool { lock.withLock { !closed && currentEpochID == epoch && entries[epoch]?.state == .accepted } }
    var awaitingCount: Int { lock.withLock { entries.values.filter { $0.waiter != nil }.count } }
    func reserve(_ epoch: LiveEpoch) -> Bool { lock.withLock {
        guard !closed, epoch.source == .system, entries[epoch.id] == nil, entries.count < 64 else { return false }
        entries[epoch.id] = .init(epoch: epoch, state: .candidate); return true
    } }
    func resolve(_ epoch: UUID, accepted: Bool) {
        let waiter = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard !closed, entries[epoch]?.state == .candidate else { return nil }
            let waiter = entries[epoch]?.waiter
            entries[epoch]?.waiter = nil; entries[epoch]?.state = accepted ? .accepted : .rejected
            if accepted { currentEpochID = epoch }
            return waiter
        }
        waiter?.resume(returning: accepted)
    }
    func accepted(_ epoch: UUID) -> Bool { lock.withLock { !closed && entries[epoch]?.state == .accepted } }
    func awaitAcceptance(_ epoch: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            let immediate: Bool? = lock.withLock {
                guard !closed, var entry = entries[epoch] else { return false }
                switch entry.state {
                case .accepted: return true
                case .rejected: return false
                case .candidate:
                    guard entry.waiter == nil else { return false }
                    entry.waiter = continuation; entries[epoch] = entry; return nil
                }
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }
    func close() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
            closed = true; let all = entries.values.compactMap(\.waiter)
            for id in entries.keys { entries[id]?.waiter = nil }; return all
        }
        for waiter in waiters { waiter.resume(returning: false) }
    }
}
