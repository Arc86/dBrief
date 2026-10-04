import Darwin
import Foundation
import dBriefWire

/// One actual delivery and finite coalesced byte blocks. Fragmentation never
/// spends an admission slot. Removed Data stays charged through awaited ingest.
final class LiveReadMailbox: @unchecked Sendable {
    static let maximumBytes = 128 * 1_024
    static let blockBytes = 16_384
    // Storage is immutable while any Receipt reference lives. Only destruction
    // clears it, after all readers/awaited delivery have relinquished ownership.
    final class Receipt: @unchecked Sendable {
        fileprivate let id: UUID
        private var storage: Data
        var data: Data { storage }
        private let owner: LiveReadMailbox
        fileprivate init(id: UUID, data: Data, owner: LiveReadMailbox) { self.id = id; self.storage = data; self.owner = owner }
        deinit {
            let bytes = storage.count
            storage = Data() // Destroy the actual payload BEFORE unlocking credit.
            owner.released(id, bytes: bytes)
        }
    }
    /// Trusted count-preserving allocator seam; absent in every app caller.
    private let testingReceiptData: (@Sendable (Data, LiveReadMailbox) -> Data)?
    init(testingReceiptData: (@Sendable (Data, LiveReadMailbox) -> Data)? = nil) { self.testingReceiptData = testingReceiptData }
    private let lock = NSLock()
    private var blocks: [Data] = []
    private var resident = 0
    private var inFlight: UUID?
    private var accepting = true
    var residentBytes: Int { lock.withLock { resident } }
    @discardableResult func offer(_ bytes: Data) -> Bool { lock.withLock {
        guard accepting, bytes.count <= Self.maximumBytes - resident else { return false }
        var cursor = 0
        while cursor < bytes.count {
            if blocks.last?.count == Self.blockBytes || blocks.isEmpty { blocks.append(Data()) }
            let n = min(Self.blockBytes - blocks[blocks.count - 1].count, bytes.count - cursor)
            blocks[blocks.count - 1].append(bytes[cursor..<(cursor + n)]); cursor += n
        }
        resident += bytes.count; return true
    } }
    func take() -> Receipt? { lock.withLock {
        guard inFlight == nil, !blocks.isEmpty else { return nil }
        let block = blocks.removeFirst(), data = testingReceiptData?(block, self) ?? block
        precondition(data.count == block.count)
        let receipt = Receipt(id: UUID(), data: data, owner: self); inFlight = receipt.id; return receipt
    } }
    private func released(_ id: UUID, bytes: Int) { lock.withLock {
        guard inFlight == id else { return }
        resident -= bytes; inFlight = nil
    } }
    func finish() { lock.withLock { accepting = false } }
    func discardQueued() { lock.withLock {
        accepting = false; resident -= blocks.reduce(0) { $0 + $1.count }; blocks.removeAll()
        // The actual in-flight receipt still owns its bytes until returned.
    } }
}

/// Lock before reading, so concurrent readable callbacks cannot reorder bytes.
/// Its private read descriptor is nonblocking; readiness races are idle, not EOF.
final class LiveOutputReadFilter: @unchecked Sendable {
    private let lock = NSLock()
    private var mux = LiveOutputDemultiplexer()
    init(_ handle: FileHandle) throws {
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw LiveProtocolError.unavailable }
    }
    enum Result { case idle, eof, delivered, overflow }
    func read(from handle: FileHandle, deliver: (Data) -> Bool) throws -> Result { try lock.withLock {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            if n > 0 {
                let mandatory = try mux.feed(Data(bytes.prefix(n))) // Current app has no optional sink.
                guard !mandatory.isEmpty else { return .idle }
                return deliver(mandatory) ? .delivered : .overflow // Handoff stays under the ordering lock.
            }
            if n == 0 { return .eof }
            if errno == EAGAIN { return .idle }
            if errno != EINTR { throw LiveProtocolError.unavailable }
        }
    } }
}
