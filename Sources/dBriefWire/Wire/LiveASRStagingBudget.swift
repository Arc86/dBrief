import Darwin
import Foundation

/// All copies and retained roots share this finite owner. Logical cancellation
/// never returns a worker permit; physical cleanup alone returns root bytes.
public final class LiveASRStagingBudget: @unchecked Sendable {
    public static let shared = LiveASRStagingBudget()
    public struct Usage: Sendable { public let workers: Int; public let roots: Int; public let bytes: UInt64 }
    enum RootKind: Sendable { case mandatory, diarization }
    private struct Receipt { let kind: RootKind; var worker = true; var deleted = false; var bytes: UInt64 = 0 }
    private let lock = NSLock()
    private var receipts: [UUID:Receipt] = [:]
    private let headroom: UInt64
    private let availableBytes: @Sendable (Int32) throws -> UInt64
    package init(recordingHeadroomBytes: UInt64 = 1 << 30) {
        headroom = max(1 << 30,recordingHeadroomBytes); availableBytes = Self.diskBytes
    }
    package init(recordingHeadroomBytes: UInt64 = 1 << 30, availableBytes: @escaping @Sendable (Int32) throws -> UInt64) {
        headroom = max(1 << 30,recordingHeadroomBytes); self.availableBytes = availableBytes
    }
    public var usage: Usage {
        lock.withLock { .init(workers: receipts.values.filter(\.worker).count,roots: receipts.values.filter { !$0.deleted }.count,
                             bytes: receipts.values.reduce(0) { $0 + $1.bytes }) }
    }
    func beginWorker(kind: RootKind = .mandatory) throws -> UUID {
        try lock.withLock {
            guard !receipts.values.contains(where: \.worker), receipts.values.filter({ !$0.deleted && $0.kind == kind }).count < (kind == .mandatory ? 2 : 1) else { throw LiveASRAssetError.busy }
            let id = UUID(); receipts[id] = Receipt(kind: kind); return id
        }
    }
    func allocate(_ id: UUID, bytes: UInt64, parent: Int32) throws {
        try lock.withLock {
            guard receipts[id]?.worker == true, receipts[id]?.bytes == 0, bytes > 0 else { throw LiveASRAssetError.invalidAsset }
            let other = receipts.values.reduce(UInt64(0)) { $0 + $1.bytes }
            let sum = other.addingReportingOverflow(bytes)
            guard !sum.overflow, sum.partialValue <= 8 * 1_073_741_824 else { throw LiveASRAssetError.busy }
            try checkDisk(required: sum.partialValue,parent: parent)
            receipts[id]?.bytes = bytes
        }
    }
    func checkDisk(_ id: UUID, parent: Int32) throws {
        try lock.withLock {
            guard receipts[id]?.worker == true, receipts[id]?.deleted == false else { throw LiveASRAssetError.invalidAsset }
            try checkDisk(required: receipts.values.reduce(0) { $0 + $1.bytes },parent: parent)
        }
    }
    private func checkDisk(required: UInt64, parent: Int32) throws {
        let sum = required.addingReportingOverflow(headroom)
        guard !sum.overflow, try availableBytes(parent) >= sum.partialValue else { throw LiveASRAssetError.insufficientDisk }
    }
    func finishWorker(_ id: UUID) {
        lock.withLock { receipts[id]?.worker = false; if receipts[id]?.deleted == true { receipts.removeValue(forKey: id) } }
    }
    func rootDeleted(_ id: UUID, proven: Bool) {
        guard proven else { return } // Finite orphan charge survives a lost pathname.
        lock.withLock {
            receipts[id]?.deleted = true; receipts[id]?.bytes = 0
            if receipts[id]?.worker == false { receipts.removeValue(forKey: id) }
        }
    }
    private static func diskBytes(_ fd: Int32) throws -> UInt64 {
        var info = statfs()
        guard fstatfs(fd,&info) == 0, info.f_bsize > 0 else { throw LiveASRAssetError.invalidAsset }
        let value = UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_bsize))
        guard !value.overflow else { throw LiveASRAssetError.insufficientDisk }
        return value.partialValue
    }
}
