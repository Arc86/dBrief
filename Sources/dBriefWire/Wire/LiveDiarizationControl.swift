import Foundation

/// Frozen metadata only. Begin does not start optional copying or native loading.
public struct LiveDiarizationBegin: Codable, Sendable, Equatable {
    public let ownerID: UUID
    public let configuration: LiveDiarizationConfiguration
    public init(ownerID: UUID, configuration: LiveDiarizationConfiguration) {
        self.ownerID = ownerID; self.configuration = configuration
    }
}

/// Closed, path-free late controls fit the actual outer FIFO atomic bound.
public struct LiveDiarizationControl: Codable, Sendable, Equatable {
    public enum Payload: Sendable, Equatable {
        case prepare(epochID: UUID)
        case acknowledge(contextID: UUID)
        case acknowledgePosterior(contextID: UUID, sequence: UInt64)
        case retire
    }
    public let identity: LiveSessionIdentity
    public let ownerID: UUID
    public let payload: Payload
    public init(identity: LiveSessionIdentity, ownerID: UUID, payload: Payload) {
        self.identity = identity; self.ownerID = ownerID; self.payload = payload
    }
    public func encode(to encoder: any Encoder) throws {
        let kind: UInt8
        switch payload { case .prepare: kind = 0; case .acknowledge: kind = 1; case .acknowledgePosterior: kind = 2; case .retire: kind = 3 }
        var bytes = Data([1, kind])
        bytes.dcUUID(identity.recordingID); bytes.dcUUID(identity.captureSessionID); bytes.dcUUID(ownerID)
        switch payload {
        case .prepare(let epoch), .acknowledge(let epoch): bytes.dcUUID(epoch)
        case .acknowledgePosterior(let context, let sequence):
            guard sequence < .max else { throw LiveProtocolError.invalidPacket }
            bytes.dcUUID(context); var value = sequence.littleEndian
            Swift.withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
        case .retire: break
        }
        var container = encoder.singleValueContainer(); try container.encode(bytes)
    }
    public init(from decoder: any Decoder) throws {
        let bytes = try decoder.singleValueContainer().decode(Data.self)
        guard bytes.count <= 74 else { throw LiveProtocolError.oversizedFrame }
        var reader = DCreader(bytes: bytes)
        guard try reader.byte() == 1 else { throw LiveProtocolError.invalidPacket }
        let kind = try reader.byte(), recording = try reader.uuid(), capture = try reader.uuid()
        ownerID = try reader.uuid(); identity = .init(recordingID: recording, captureSessionID: capture)
        switch kind {
        case 0: payload = .prepare(epochID: try reader.uuid())
        case 1: payload = .acknowledge(contextID: try reader.uuid())
        case 2:
            let context = try reader.uuid(), sequence = try reader.sequence()
            guard sequence < .max else { throw LiveProtocolError.invalidPacket }
            payload = .acknowledgePosterior(contextID: context, sequence: sequence)
        case 3: payload = .retire
        default: throw LiveProtocolError.invalidPacket
        }
        guard reader.offset == bytes.count else { throw LiveProtocolError.invalidPacket }
    }
}
private extension Data {
    mutating func dcUUID(_ value: UUID) { var v = value.uuid; Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) } }
}
private struct DCreader {
    let bytes: Data
    var offset = 0
    mutating func take(_ count: Int) throws -> Data {
        guard offset <= bytes.count - count else { throw LiveProtocolError.invalidPacket }
        defer { offset += count }; return bytes.subdata(in: offset..<(offset + count))
    }
    mutating func byte() throws -> UInt8 { try take(1)[0] }
    mutating func uuid() throws -> UUID { let v = [UInt8](try take(16)); return v.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress!) as UUID } }
    mutating func sequence() throws -> UInt64 { try take(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) } }
}
