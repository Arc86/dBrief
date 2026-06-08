import Foundation

public enum FrameCodec {
    /// 4-byte big-endian length prefix followed by the payload bytes.
    public static func encode(_ payload: Data) -> Data {
        var out = Data(capacity: 4 + payload.count)
        var be = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}

/// Accumulates raw bytes and yields complete frames as they arrive.
/// Handles partial reads and length prefixes split across reads.
public struct FrameReader {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: some DataProtocol) {
        buffer.append(contentsOf: data)
    }

    /// Returns every complete frame currently buffered, consuming their bytes.
    public mutating func drainFrames() -> [Data] {
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let total = 4 + Int(length)
            guard buffer.count >= total else { break }
            let payload = buffer.subdata(in: 4..<total)
            frames.append(payload)
            buffer.removeSubrange(0..<total)
        }
        return frames
    }
}
