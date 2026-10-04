import Foundation

/// Nominal mapped evidence, never an acoustic alignment certificate.
public struct LiveDiarizationRow: Sendable, Equatable {
    public let streamSamples: LiveSampleRange
    public let samples: LiveSampleRange
    public let meeting: LiveMeetingRange?
    public let activity: Data
    public init(streamSamples: LiveSampleRange, samples: LiveSampleRange, meeting: LiveMeetingRange?, activity: [Float]) throws {
        var bytes = Data()
        for value in activity { var bits = value.bitPattern.littleEndian; Swift.withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) } }
        self.streamSamples = streamSamples; self.samples = samples; self.meeting = meeting; self.activity = bytes
        guard isValid else { throw LiveProtocolError.invalidPacket }
    }
    private init(stream: Int64, sample: Int64, count: Int64, meeting: Int64?, activity: Data) throws {
        guard stream >= 0, sample >= 0, (1...160).contains(count), stream <= .max - count, sample <= .max - count,
              meeting.map({ $0 >= 0 && $0 <= .max - count * 62_500 }) ?? true else { throw LiveProtocolError.invalidPacket }
        streamSamples = .init(start: stream, end: stream + count); samples = .init(start: sample, end: sample + count)
        self.meeting = meeting.map { .init(startNanoseconds: $0, endNanoseconds: $0 + count * 62_500) }; self.activity = activity
        guard isValid else { throw LiveProtocolError.invalidPacket }
    }
    public var isValid: Bool {
        streamSamples.isValid && samples.isValid && (1...160).contains(samples.end - samples.start) &&
        streamSamples.end - streamSamples.start == samples.end - samples.start &&
        (meeting.map { $0.isValid && $0.endNanoseconds - $0.startNanoseconds == (samples.end - samples.start) * 62_500 } ?? true) &&
        (try? activityValues()) != nil
    }
    public func activityValues() throws -> [Float] {
        guard activity.count == 32 else { throw LiveProtocolError.invalidPacket }
        let bytes = [UInt8](activity); var values: [Float] = []
        for start in stride(from: 0, to: 32, by: 4) {
            let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[start + $1]) << ($1 * 8) }
            let value = Float(bitPattern: bits)
            guard value.isFinite, (0...1).contains(value) else { throw LiveProtocolError.invalidPacket }
            values.append(value)
        }
        return values
    }
    fileprivate func encode(into bytes: inout Data) {
        bytes.hpInteger(UInt64(streamSamples.start)); bytes.hpInteger(UInt64(samples.start))
        bytes.hpInteger(UInt16(samples.end - samples.start)); bytes.append(meeting == nil ? 0 : 1)
        if let meeting { bytes.hpInteger(UInt64(meeting.startNanoseconds)) }
        bytes.append(activity)
    }
    fileprivate static func decode(_ reader: inout HPbinaryReader) throws -> Self {
        let stream = try reader.signed(), start = try reader.signed(), count: UInt16 = try reader.integer()
        let flag = try reader.byte(); guard flag <= 1 else { throw LiveProtocolError.invalidPacket }
        let meeting = flag == 1 ? try reader.signed() : nil
        return try .init(stream: stream, sample: start, count: Int64(count), meeting: meeting, activity: reader.data(32))
    }
}

/// Compact independent control stream. The outer frame also fits macOS's actual
/// PIPE_BUF512; no repeated JSON UUID/scope dictionary for each posterior row.
public struct LiveDiarizationEvent: Codable, Sendable, Equatable {
    public enum RetirementReason: UInt8, Sendable { case pressure, capacity, discontinuity, failed, stopped, finished, output }
    public enum Payload: Sendable, Equatable {
        case preparing
        case ready(originSample: Int64, contextID: UUID)
        case posterior(contextID: UUID, rows: [LiveDiarizationRow])
        case retired(contextID: UUID?, receiptID: UUID, reason: RetirementReason)
    }
    public let scope: LiveLaneScope
    public let ownerID: UUID
    public let sequence: UInt64
    public let payload: Payload
    public init(scope: LiveLaneScope, ownerID: UUID, sequence: UInt64, payload: Payload) {
        self.scope = scope; self.ownerID = ownerID; self.sequence = sequence; self.payload = payload
    }
    public func encode(to encoder: any Encoder) throws {
        guard scope.source == .system, sequence < .max else { throw LiveProtocolError.invalidPacket }
        var bytes = Data([1])
        switch payload { case .preparing: bytes.append(0); case .ready: bytes.append(1); case .posterior: bytes.append(2); case .retired: bytes.append(3) }
        bytes.hpUUID(scope.identity.recordingID); bytes.hpUUID(scope.identity.captureSessionID)
        bytes.hpUUID(scope.epochID); bytes.hpUUID(ownerID); bytes.hpInteger(sequence)
        switch payload {
        case .preparing: break
        case .ready(let origin, let context):
            guard origin >= 0 else { throw LiveProtocolError.invalidPacket }; bytes.hpInteger(UInt64(origin)); bytes.hpUUID(context)
        case .posterior(let context, let rows):
            guard (1...2).contains(rows.count), rows.allSatisfy(\.isValid) else { throw LiveProtocolError.invalidPacket }
            bytes.hpUUID(context); bytes.append(UInt8(rows.count)); for row in rows { row.encode(into: &bytes) }
        case .retired(let context, let receipt, let reason):
            bytes.append(context == nil ? 0 : 1); if let context { bytes.hpUUID(context) }; bytes.hpUUID(receipt); bytes.append(reason.rawValue)
        }
        guard bytes.count <= 209 else { throw LiveProtocolError.oversizedFrame }
        var container = encoder.singleValueContainer(); try container.encode(bytes)
    }
    public init(from decoder: any Decoder) throws {
        let bytes = try decoder.singleValueContainer().decode(Data.self)
        guard bytes.count <= 209 else { throw LiveProtocolError.oversizedFrame }
        var reader = HPbinaryReader(bytes: bytes); guard try reader.byte() == 1 else { throw LiveProtocolError.invalidPacket }
        let kind = try reader.byte(), recording = try reader.uuid(), capture = try reader.uuid(), epoch = try reader.uuid()
        ownerID = try reader.uuid(); sequence = try reader.integer()
        guard sequence < .max else { throw LiveProtocolError.invalidPacket }
        scope = .init(identity: .init(recordingID: recording, captureSessionID: capture), source: .system, epochID: epoch)
        switch kind {
        case 0: payload = .preparing
        case 1: payload = .ready(originSample: try reader.signed(), contextID: try reader.uuid())
        case 2:
            let context = try reader.uuid(), count = try reader.byte(); guard (1...2).contains(count) else { throw LiveProtocolError.invalidPacket }
            var rows: [LiveDiarizationRow] = []; for _ in 0..<count { rows.append(try .decode(&reader)) }; payload = .posterior(contextID: context, rows: rows)
        case 3:
            let flag = try reader.byte(); guard flag <= 1 else { throw LiveProtocolError.invalidPacket }
            let context = flag == 1 ? try reader.uuid() : nil, receipt = try reader.uuid()
            guard let reason = RetirementReason(rawValue: try reader.byte()) else { throw LiveProtocolError.invalidPacket }
            payload = .retired(contextID: context, receiptID: receipt, reason: reason)
        default: throw LiveProtocolError.invalidPacket
        }
        guard reader.offset == bytes.count else { throw LiveProtocolError.invalidPacket }
    }
}
private extension Data {
    mutating func hpInteger<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) } }
    mutating func hpUUID(_ value: UUID) { var v = value.uuid; Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) } }
}
fileprivate struct HPbinaryReader {
    let bytes: Data
    var offset = 0
    mutating func data(_ count: Int) throws -> Data {
        guard count >= 0, offset <= bytes.count - count else { throw LiveProtocolError.invalidPacket }
        defer { offset += count }; return bytes.subdata(in: offset..<(offset + count))
    }
    mutating func byte() throws -> UInt8 { try data(1)[0] }
    mutating func integer<T: FixedWidthInteger>() throws -> T {
        let values = try data(MemoryLayout<T>.size)
        return values.enumerated().reduce(T.zero) { $0 | T($1.element) << ($1.offset * 8) }
    }
    mutating func signed() throws -> Int64 {
        let raw: UInt64 = try integer(); guard raw <= Int64.max else { throw LiveProtocolError.invalidPacket }; return Int64(raw)
    }
    mutating func uuid() throws -> UUID { let bytes = [UInt8](try data(16)); return bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress!) as UUID } }
}
