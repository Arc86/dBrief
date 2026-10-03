import Foundation

/// Portable identity used by measured profiles. The exact compiled model tree,
/// runtime, compute choice and used streaming policy must all match.
public struct LiveVADIdentity: Codable, Sendable, Equatable {
    public enum ComputeUnits: String, Codable, Sendable { case cpuOnly, cpuAndGPU, cpuAndNeuralEngine, all }
    public static let sampleRate = 16_000
    public static let windowSamples = 4096
    public static let currentImplementationRevision = "dbrief-vad-indexed-v1"
    public let modelRevision: String
    public let modelFingerprint: String
    public let runtimeRevision: String
    public let implementationRevision: String
    public let computeUnits: ComputeUnits
    public let positiveThreshold: Float
    public let negativeThreshold: Float
    public let minSilenceSamples: Int
    public let speechPaddingSamples: Int

    public init(modelRevision: String, modelFingerprint: String, runtimeRevision: String,
                computeUnits: ComputeUnits = .cpuAndNeuralEngine, positiveThreshold: Float = 0.85,
                negativeThreshold: Float = 0.70, minSilenceSamples: Int = 9600, speechPaddingSamples: Int = 1600,
                implementationRevision: String = Self.currentImplementationRevision) {
        self.modelRevision = modelRevision; self.modelFingerprint = modelFingerprint; self.runtimeRevision = runtimeRevision
        self.computeUnits = computeUnits; self.positiveThreshold = positiveThreshold; self.negativeThreshold = negativeThreshold
        self.minSilenceSamples = minSilenceSamples; self.speechPaddingSamples = speechPaddingSamples
        self.implementationRevision = implementationRevision
    }

    public var isValid: Bool {
        func validID(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 256 &&
                !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        return validID(modelRevision) && validID(runtimeRevision) && validID(implementationRevision) && modelFingerprint.utf8.count == 64 &&
            modelFingerprint.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } &&
            positiveThreshold.isFinite && negativeThreshold.isFinite && positiveThreshold > 0 && positiveThreshold <= 1 &&
            negativeThreshold >= 0 && negativeThreshold < positiveThreshold &&
            // Pinned streaming derives its entry threshold from exit + offset.
            // Reject a Float pair that cannot represent the frozen entry exactly.
            negativeThreshold + (positiveThreshold - negativeThreshold) == positiveThreshold &&
            (1...240_000).contains(minSilenceSamples) && (0...Self.windowSamples).contains(speechPaddingSamples)
    }
}

/// A machine's cached path is frozen in Begin/the lease but is not a portable
/// measurement key. Validation here never reads, mutates or downloads assets.
public struct LiveVADConfiguration: Codable, Sendable, Equatable {
    public let identity: LiveVADIdentity
    public let modelPath: String
    public init(identity: LiveVADIdentity, modelPath: String) { self.identity = identity; self.modelPath = modelPath }
    public var isValid: Bool {
        // Foundation's standardizedFileURL can consult existing filesystem
        // aliases (for example /private/tmp -> /tmp). Admission is lexical and
        // must have the same result before and after assets are created.
        let components = modelPath.split(separator: "/",omittingEmptySubsequences: false)
        return identity.isValid && modelPath.hasPrefix("/") && modelPath.hasSuffix(".mlmodelc") && modelPath.utf8.count <= 4096 &&
            !modelPath.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } &&
            components.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
