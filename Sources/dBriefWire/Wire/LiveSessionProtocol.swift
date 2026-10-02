import Darwin
import Foundation

public enum LiveProtocolError: String, Error, Codable, Sendable {
    case invalidConfiguration, invalidPacket, staleScope, outOfOrder, unavailable, closed, oversizedFrame, outputLimit, unsupportedRole
}

public struct LiveASRConfiguration: Codable, Sendable, Equatable {
    public enum Language: String, Codable, Sendable { case en, nl, auto }
    public let language: Language
    public let chunkMs: Int
    public let modelDirectory: String
    public var chunkSamples: Int { [560,1120,2240].contains(chunkMs) ? chunkMs * 16 : 0 }
    public var pendingSampleLimit: Int { chunkSamples + 32000 }
    public init(language: Language, chunkMs: Int = 1120, modelDirectory: String) {
        self.language = language; self.chunkMs = chunkMs; self.modelDirectory = modelDirectory
    }
    public var isValid: Bool {
        [560,1120,2240].contains(chunkMs) && modelDirectory.hasPrefix("/") &&
            modelDirectory.utf8.count <= 4096 && !modelDirectory.contains("\0")
    }
}

public struct LiveLaneScope: Codable, Sendable, Equatable {
    public let identity: LiveSessionIdentity
    public let source: LiveSource
    public let epochID: UUID
    public init(identity: LiveSessionIdentity, source: LiveSource, epochID: UUID) {
        self.identity = identity; self.source = source; self.epochID = epochID
    }
}

public struct LiveAudioPacket: Codable, Sendable, Equatable {
    public let scope: LiveLaneScope
    public let sequence: UInt64
    public let startSample: Int64
    public let sampleCount: Int
    public let pcm: Data
    public init(scope: LiveLaneScope, sequence: UInt64, startSample: Int64, sampleCount: Int, pcm: Data) {
        self.scope = scope; self.sequence = sequence; self.startSample = startSample; self.sampleCount = sampleCount; self.pcm = pcm
    }
    public init(scope: LiveLaneScope, sequence: UInt64, startSample: Int64, samples: [Float]) throws {
        guard (1...3200).contains(samples.count), samples.allSatisfy(\.isFinite) else { throw LiveProtocolError.invalidPacket }
        var pcm = Data()
        for sample in samples { var bits = sample.bitPattern.littleEndian; withUnsafeBytes(of: &bits) { pcm.append(contentsOf: $0) } }
        self.init(scope: scope, sequence: sequence, startSample: startSample, sampleCount: samples.count, pcm: pcm)
        _ = try decodedSamples()
    }
    public func decodedSamples() throws -> [Float] {
        guard scope.source.isCaptureSource, sequence < .max, startSample >= 0, (1...3200).contains(sampleCount),
              !startSample.addingReportingOverflow(Int64(sampleCount)).overflow, pcm.count == sampleCount * 4 else { throw LiveProtocolError.invalidPacket }
        let bytes = [UInt8](pcm)
        var samples: [Float] = []; samples.reserveCapacity(sampleCount)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let bits = UInt32(bytes[offset]) | UInt32(bytes[offset+1]) << 8 | UInt32(bytes[offset+2]) << 16 | UInt32(bytes[offset+3]) << 24
            let sample = Float(bitPattern: bits)
            guard sample.isFinite else { throw LiveProtocolError.invalidPacket }
            samples.append(sample)
        }
        return samples
    }
}

public struct LiveSessionBegin: Codable, Sendable, Equatable {
    public let identity: LiveSessionIdentity
    public let configuration: LiveASRConfiguration
    public let epochs: [LiveEpoch]
    public init(identity: LiveSessionIdentity, configuration: LiveASRConfiguration, epochs: [LiveEpoch]) {
        self.identity = identity; self.configuration = configuration; self.epochs = epochs
    }
    public var isValid: Bool {
        configuration.isValid && (1...2).contains(epochs.count) && Set(epochs.map(\.id)).count == epochs.count &&
            Set(epochs.map(\.source)).count == epochs.count && epochs.allSatisfy {
                $0.source.isCaptureSource && $0.availability == .active && $0.language == configuration.language.rawValue &&
                    !$0.engineRevision.isEmpty && $0.engineRevision.utf8.count <= 256 && ($0.meetingOriginNanoseconds.map { $0 >= 0 } ?? true)
            }
    }
}

public struct LiveFinishBarrier: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case utterance, pause, finish }
    public let scope: LiveLaneScope
    public let nextPacketSequence: UInt64
    public let sampleEnd: Int64
    public let kind: Kind
    public init(scope: LiveLaneScope, nextPacketSequence: UInt64, sampleEnd: Int64, kind: Kind) {
        self.scope = scope; self.nextPacketSequence = nextPacketSequence; self.sampleEnd = sampleEnd; self.kind = kind
    }
}

public enum LiveSessionRequest: Codable, Sendable, Equatable {
    case begin(LiveSessionBegin), packet(LiveAudioPacket), barrier(LiveFinishBarrier)
    case cut(scope: LiveLaneScope, nextPacketSequence: UInt64, sampleEnd: Int64, reason: LiveGapReason)
    case replaceEpoch(identity: LiveSessionIdentity, oldEpochID: UUID, epoch: LiveEpoch)
    case cancel(LiveSessionIdentity)
}
public enum LiveSessionReply: Codable, Sendable, Equatable { case accepted, rejected(LiveProtocolError) }

public struct LiveHelperProgress: Codable, Sendable, Equatable {
    public let capturedSampleEnd: Int64
    public let admittedSampleEnd: Int64
    public let consumedSampleEnd: Int64
    public let queuedSamples: Int64
    public let inFlightSamples: Int64
    public let heldSamples: Int64
    public let creditSamples: Int64
    /// Evidence processed by ASR may exceed the common releasable prefix when
    /// another native consumer retains input. Legacy ASR-only frames omit it.
    public let asrConsumedSampleEnd: Int64?
    public var effectiveASRConsumedSampleEnd: Int64 { asrConsumedSampleEnd ?? consumedSampleEnd }
    public init(capturedSampleEnd: Int64, admittedSampleEnd: Int64, consumedSampleEnd: Int64,
                queuedSamples: Int64, inFlightSamples: Int64, heldSamples: Int64, creditSamples: Int64,
                asrConsumedSampleEnd: Int64? = nil) {
        self.capturedSampleEnd = capturedSampleEnd; self.admittedSampleEnd = admittedSampleEnd
        self.consumedSampleEnd = consumedSampleEnd; self.queuedSamples = queuedSamples
        self.inFlightSamples = inFlightSamples; self.heldSamples = heldSamples; self.creditSamples = creditSamples
        self.asrConsumedSampleEnd = asrConsumedSampleEnd
    }
}

public struct LiveLaneEvent: Codable, Sendable, Equatable {
    public enum Payload: Codable, Sendable, Equatable {
        case ready(generation: UUID, originSample: Int64)
        case admitted(packetSequence: UInt64, sampleEnd: Int64)
        case progress(LiveHelperProgress), partial(LivePartial), committed(CommittedLiveSegment), settled(LiveCoverageInterval)
        case needsEpochReplacement, barrierCompleted(requestID: UUID, kind: LiveFinishBarrier.Kind, sampleEnd: Int64)
        case closed(sampleEnd: Int64)
    }
    public let scope: LiveLaneScope
    public let sequence: UInt64
    public let payload: Payload
    public init(scope: LiveLaneScope, sequence: UInt64, payload: Payload) { self.scope = scope; self.sequence = sequence; self.payload = payload }
}
public enum LiveSessionEvent: Codable, Sendable, Equatable {
    case lane(LiveLaneEvent), finished(LiveSessionIdentity), failed(LiveSessionIdentity, LiveProtocolError)
}
public enum LiveSessionMessage: Codable, Sendable, Equatable { case reply(LiveSessionReply), event(LiveSessionEvent) }

/// Dedicated live frames have their own bound; ordinary helper framing is unchanged.
public struct LiveFrameReader {
    public static let maximumFrameBytes = 65536
    private var buffer = Data()
    public var bufferedBytes: Int { buffer.count }
    public init() {}
    /// Foundation's read(upToCount:) on macOS can wait to fill the requested
    /// length. One POSIX read returns a small available frame immediately while
    /// retaining a fixed allocation bound. Nil means EOF.
    public static func readChunk(from handle: FileHandle) throws -> Data? {
        var bytes = [UInt8](repeating: 0,count: 16384)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor,$0.baseAddress,$0.count) }
            if count > 0 { return Data(bytes.prefix(count)) }
            if count == 0 { return nil }
            if errno != EINTR { throw LiveProtocolError.unavailable }
        }
    }
    public mutating func feed(_ data: Data) throws -> [Data] {
        var frames: [Data] = [], offset = data.startIndex
        while offset < data.endIndex {
            if buffer.count < 4 {
                let count = min(4 - buffer.count, data.endIndex - offset)
                buffer.append(data[offset..<(offset+count)]); offset += count
                if buffer.count < 4 { break }
            }
            let length = Int(buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            guard length > 0, length <= Self.maximumFrameBytes else {
                buffer.removeAll(); throw LiveProtocolError.oversizedFrame
            }
            let count = min(4 + length - buffer.count, data.endIndex - offset)
            buffer.append(data[offset..<(offset+count)]); offset += count
            if buffer.count == 4 + length { frames.append(Data(buffer.dropFirst(4))); buffer.removeAll(keepingCapacity: true) }
        }
        return frames
    }
}
