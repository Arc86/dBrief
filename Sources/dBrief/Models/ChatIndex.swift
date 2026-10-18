import CryptoKit
import Foundation
import dBriefWire

/// Per-recording embedding index for transcript chat. Keyed by a hash of the
/// window text, so renaming a speaker or editing a segment rebuilds it.
/// An index with no vectors (`dims == 0`) is the in-memory BM25-only fallback
/// used when embedding fails; it is never persisted.
struct ChatIndex: Codable, Sendable {
    static let currentVersion = 1
    var version: Int
    var model: String
    var contentHash: String
    var windows: [TranscriptWindow]
    var vectorData: Data
    var dims: Int

    init(windows: [TranscriptWindow], vectors: [[Float]], model: String) {
        self.version = Self.currentVersion
        self.model = model
        self.windows = windows
        self.contentHash = Self.contentHash(of: windows)
        self.dims = vectors.first?.count ?? 0
        self.vectorData = vectors.flatMap { $0 }.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// True when the binary payload is exactly `windows.count × dims` Float32s.
    var hasConsistentVectorData: Bool {
        vectorData.count == windows.count * dims * MemoryLayout<Float>.size
    }

    var vectors: [[Float]] {
        guard dims > 0, hasConsistentVectorData else { return [] }
        let flat = vectorData.withUnsafeBytes { raw in
            (0..<(raw.count / 4)).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
        return stride(from: 0, to: flat.count, by: dims).map { Array(flat[$0..<$0 + dims]) }
    }

    static func contentHash(of windows: [TranscriptWindow]) -> String {
        let joined = windows.map(\.text).joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func isValid(for windows: [TranscriptWindow], model: String) -> Bool {
        version == Self.currentVersion && self.model == model && hasConsistentVectorData
            && contentHash == Self.contentHash(of: windows)
    }
}
