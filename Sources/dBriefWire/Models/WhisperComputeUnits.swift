import Foundation
import CoreML

public enum WhisperComputeUnits: String, CaseIterable, Codable, Hashable, Sendable {
    case cpuAndNeuralEngine
    case cpuAndGPU
    case all

    public var displayName: String {
        switch self {
        case .cpuAndNeuralEngine: "Neural Engine"
        case .cpuAndGPU: "Metal GPU"
        case .all: "All (GPU + Neural Engine)"
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
