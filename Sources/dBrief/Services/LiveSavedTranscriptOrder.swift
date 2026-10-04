import Foundation
import Darwin

/// One exact owned rich sidecar. Receipts contain no transcript content and
/// cannot cross an owner, path or newer verified save. Callers acquire the
/// RecordingResultMutation transaction before this lock, then validity locks.
final class LiveSavedTranscriptOrder: @unchecked Sendable {
    struct Receipt: Sendable {
        fileprivate let owner: UUID
        fileprivate let path: URL
        fileprivate let revision: UInt64
    }
    private let lock = NSLock()
    private let id = UUID()
    private var path: URL?
    private var revision: UInt64 = 0

    func read<T>(at url: URL, _ body: () throws -> T) throws -> (T, Receipt) {
        try lock.withLock {
            let target = try target(url)
            let value = try body()
            path = target
            return (value, .init(owner: id, path: target, revision: revision))
        }
    }
    func save(at url: URL, _ body: () throws -> Void) throws -> Receipt {
        try lock.withLock {
            let target = try target(url)
            guard revision < .max else { throw LiveArtifactError.staleRevision }
            try body() // Includes verification of the physical saved value.
            path = target; revision += 1
            return .init(owner: id, path: target, revision: revision)
        }
    }
    func withCurrent<T>(_ receipt: Receipt, _ body: () throws -> T) throws -> T {
        try lock.withLock {
            guard receipt.owner == id, receipt.path == path, receipt.revision == revision else { throw CancellationError() }
            return try body()
        }
    }
    private func target(_ url: URL) throws -> URL {
        // Foundation may preserve /tmp in one URL and /private/tmp in another.
        // Resolve the containing directory using its actual filesystem spelling;
        // the atomic writer replaces the final filename rather than its symlink.
        let directory = url.deletingLastPathComponent().path
        guard url.isFileURL, directory.utf8.count <= 4_096,
              let resolved = directory.withCString({ realpath($0, nil) }) else { throw CocoaError(.fileReadNoSuchFile) }
        defer { free(resolved) }
        let target = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent(url.lastPathComponent)
        guard target.absoluteString.utf8.count <= 4_096, path == nil || path == target else { throw LiveArtifactError.wrongOwner }
        return target
    }
}
