import Foundation
import CoreML

public enum WhisperComputeUnits: String, CaseIterable, Codable, Hashable, Sendable {
    case cpuAndNeuralEngine
    case cpuAndGPU
    case all

    public var displayName: String {
        switch self {
        case .cpuAndNeuralEngine: String(localized: "Neural Engine")
        case .cpuAndGPU: String(localized: "Metal GPU")
        case .all: String(localized: "All (GPU + Neural Engine)")
        }
    }

    /// Non-technical label. ".all" reads as "Automatic" (the smart default);
    /// the others keep their technical names for users who know them.
    public var friendlyName: String {
        switch self {
        case .all: String(localized: "Automatic")
        default: displayName
        }
    }

    /// Maps to the CoreML compute units WhisperKit applies per model component.
    public var mlComputeUnits: MLComputeUnits {
        switch self {
        case .cpuAndNeuralEngine: .cpuAndNeuralEngine
        case .cpuAndGPU: .cpuAndGPU
        case .all: .all
        }
    }
}
