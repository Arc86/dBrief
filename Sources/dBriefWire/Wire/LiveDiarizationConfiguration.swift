import Foundation

/// Nominal SDK cadence. Structural support supplies no acoustic/device eligibility.
public enum LiveDiarizationPreset: String, Codable, CaseIterable, Sendable {
    case ultraLow, veryLow, low, fast, fast24, fast32, efficient, fast128
    public var core: Int {
        switch self {
        case .ultraLow: 3
        case .veryLow: 6
        case .low, .fast: 9
        case .fast24: 24
        case .fast32: 32
        case .efficient: 48
        case .fast128: 128
        }
    }
    public var right: Int { self == .ultraLow ? 1 : self == .veryLow ? 2 : 4 }
    public var fifo: Int { [.ultraLow,.veryLow,.low,.efficient].contains(self) ? 264 : 40 }
    public var pendingSampleLimit: Int64 { Int64((core + right) * 1_280 + 512 + 3_200) }
    public var maximumBatchFrames: Int { Int((pendingSampleLimit + 159) / 160) + 2 }
    public var modelFileName: String {
        let name = self == .ultraLow ? "ultra" : self == .veryLow ? "verylow" : rawValue
        return "Nemotron3Diarizer_\(name).mlmodelc"
    }
}

public struct LiveDiarizationIdentity: Codable, Sendable, Equatable {
    public static let modelFamily = "nemotron-3-diarization-streaming"
    public static let currentModelRevision = "ga-2026-09-23"
    public static let currentImplementationRevision = "dbrief-nemotron-live-diarization-v1"
    public let family: String
    public let modelRevision: String
    public let modelFingerprint: String
    public let runtimeRevision: String
    public let implementationRevision: String
    public let preset: LiveDiarizationPreset
    public let computeUnits: LiveASRIdentity.ComputeUnits
    public let allowLowPrecisionGPUAccumulation: Bool
    public init(family: String = Self.modelFamily, modelRevision: String = Self.currentModelRevision, modelFingerprint: String,
                runtimeRevision: String = LiveASRIdentity.currentRuntimeRevision,
                implementationRevision: String = Self.currentImplementationRevision, preset: LiveDiarizationPreset,
                computeUnits: LiveASRIdentity.ComputeUnits = .cpuAndNeuralEngine, allowLowPrecisionGPUAccumulation: Bool = false) {
        self.family = family; self.modelRevision = modelRevision; self.modelFingerprint = modelFingerprint
        self.runtimeRevision = runtimeRevision; self.implementationRevision = implementationRevision
        self.preset = preset; self.computeUnits = computeUnits; self.allowLowPrecisionGPUAccumulation = allowLowPrecisionGPUAccumulation
    }
    public var isSupported: Bool {
        family == Self.modelFamily && modelRevision == Self.currentModelRevision &&
        runtimeRevision == LiveASRIdentity.currentRuntimeRevision && implementationRevision == Self.currentImplementationRevision &&
        !allowLowPrecisionGPUAccumulation && modelFingerprint.utf8.count == 64 &&
        modelFingerprint.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct LiveDiarizationConfiguration: Codable, Sendable, Equatable {
    public let identity: LiveDiarizationIdentity
    public let modelDirectory: String
    public init(identity: LiveDiarizationIdentity, modelDirectory: String) { self.identity = identity; self.modelDirectory = modelDirectory }
    public var isValid: Bool { identity.isSupported && LiveASRIdentity.validPath(modelDirectory) }
}

/// Created only from the copied descriptor tree and its exact fingerprint.
public struct LiveDiarizationMetadataWitness: Sendable {
    public static let maximumMetadataBytes = 65_536
    public let metadata: Data
    public let silenceEmbedding: [Float]
    internal init(metadata: Data, embedding: Data, marker: Data, revision: String) throws {
        guard !metadata.isEmpty, metadata.count <= Self.maximumMetadataBytes, embedding.count == 2_048,
              marker == Data(revision.utf8) || marker == Data((revision + "\n").utf8) else { throw LiveASRAssetError.invalidAsset }
        var values: [Float] = []; values.reserveCapacity(512)
        for offset in stride(from: 0,to: embedding.count,by: 4) {
            let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(embedding[offset + $1]) << ($1 * 8) }
            let value = Float(bitPattern: bits)
            guard value.isFinite else { throw LiveASRAssetError.invalidAsset }
            values.append(value)
        }
        self.metadata = metadata; silenceEmbedding = values
    }
}
