import Foundation

/// Exact assets and runtime policy, shared across app admission and native load.
/// A structurally valid identity does not supply hardware qualification.
public struct LiveASRIdentity: Codable, Sendable, Equatable {
    public enum ComputeUnits: String, Codable, Sendable { case cpuOnly, cpuAndNeuralEngine, cpuAndGPU, all }
    public static let modelFamily = "nemotron-3.5-asr-streaming-multilingual-0.6b"
    public static let currentRuntimeRevision = "21493f8dac5a97e65742e6ff26f42f164c2fda0f"
    public static let currentImplementationRevision = "dbrief-nemotron-live-asr-v1"
    public let family: String
    public let modelRevision: String
    public let modelFingerprint: String
    public let runtimeRevision: String
    public let implementationRevision: String
    public let computeUnits: ComputeUnits
    public let allowLowPrecisionGPUAccumulation: Bool

    public init(family: String = Self.modelFamily, modelRevision: String, modelFingerprint: String,
                runtimeRevision: String, implementationRevision: String = Self.currentImplementationRevision,
                computeUnits: ComputeUnits = .cpuAndNeuralEngine, allowLowPrecisionGPUAccumulation: Bool = false) {
        self.family = family; self.modelRevision = modelRevision; self.modelFingerprint = modelFingerprint
        self.runtimeRevision = runtimeRevision; self.implementationRevision = implementationRevision
        self.computeUnits = computeUnits; self.allowLowPrecisionGPUAccumulation = allowLowPrecisionGPUAccumulation
    }
    public var isValid: Bool {
        [family,modelRevision,runtimeRevision,implementationRevision].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256 &&
                !$0.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
        } && modelFingerprint.utf8.count == 64 && modelFingerprint.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public var isSupported: Bool {
        isValid && family == Self.modelFamily && runtimeRevision == Self.currentRuntimeRevision &&
            implementationRevision == Self.currentImplementationRevision && !allowLowPrecisionGPUAccumulation
    }
    public static func validPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return false }
        let parts = path.split(separator: "/",omittingEmptySubsequences: false)
        return parts.count > 1 && parts.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }
    }
    public static func environment(inherited: [String:String], extra: [String:String], live: Bool) -> [String:String] {
        let merged = inherited.merging(extra) { _,new in new }
        return live ? merged.filter { !$0.key.hasPrefix("FLUIDAUDIO_") } : merged
    }
}
