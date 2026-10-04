import Foundation

/// Filter before mandatory raw handoff. Untagged bytes keep their exact frame
/// order/fragmentation; no whole mandatory frame or optional backlog is retained.
public struct LiveOutputDemultiplexer: Sendable {
    public static let maximumOptionalBodyBytes = 508
    private var header = Data()
    private var optionalBody = Data()
    private var remaining = 0
    private var isOptional = false
    public var retainedBytes: Int { header.count + optionalBody.count }
    public init() {}
    public mutating func feed(_ input: Data, optional: (Data) -> Void = { _ in }) throws -> Data {
        guard input.count <= 16_384 else { throw LiveProtocolError.oversizedFrame }
        var result = Data(), cursor = 0
        while cursor < input.count {
            if remaining == 0 {
                let n = min(4 - header.count, input.count - cursor)
                header.append(input[cursor..<(cursor + n)]); cursor += n
                if header.count < 4 { continue }
                let raw = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                isOptional = raw & 0x8000_0000 != 0; remaining = Int(raw & 0x7fff_ffff)
                guard remaining > 0, remaining <= (isOptional ? Self.maximumOptionalBodyBytes : LiveFrameReader.maximumFrameBytes) else { throw LiveProtocolError.oversizedFrame }
                if !isOptional { result.append(header) }; header.removeAll(keepingCapacity: true)
            }
            let n = min(remaining, input.count - cursor)
            if isOptional { optionalBody.append(input[cursor..<(cursor + n)]) }
            else { result.append(input[cursor..<(cursor + n)]) }
            remaining -= n; cursor += n
            if remaining == 0, isOptional { optional(optionalBody); optionalBody.removeAll(keepingCapacity: true) }
        }
        return result
    }
    public static func tag(_ body: Data) throws -> Data {
        guard !body.isEmpty, body.count <= maximumOptionalBodyBytes else { throw LiveProtocolError.oversizedFrame }
        var framed = FrameCodec.encode(body); framed[0] |= 0x80; return framed
    }
}
