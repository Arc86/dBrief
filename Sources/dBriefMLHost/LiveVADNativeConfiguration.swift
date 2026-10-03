import CoreML
import FluidAudio
import Foundation
import dBriefWire

/// Canonical mapping for the pinned SDK's used streaming policy. This only
/// constructs validated configuration; native cache/model loading is separate.
struct LiveVADNativeConfiguration: Sendable {
    static let runtimeRevision = "21493f8dac5a97e65742e6ff26f42f164c2fda0f"
    let vad: VadConfig
    let segmentation: VadSegmentationConfig

    init(_ configuration: LiveVADConfiguration) throws {
        let policy = configuration.identity
        guard configuration.isValid, policy.runtimeRevision == Self.runtimeRevision else { throw LiveProtocolError.invalidConfiguration }
        let silence = (Double(policy.minSilenceSamples) / 16000).nextUp
        let padding = policy.speechPaddingSamples == 0 ? 0 : (Double(policy.speechPaddingSamples) / 16000).nextUp
        guard Int(silence * 16000) == policy.minSilenceSamples, Int(padding * 16000) == policy.speechPaddingSamples else {
            throw LiveProtocolError.invalidConfiguration
        }
        let compute: MLComputeUnits
        switch policy.computeUnits {
        case .cpuOnly: compute = .cpuOnly
        case .cpuAndGPU: compute = .cpuAndGPU
        case .cpuAndNeuralEngine: compute = .cpuAndNeuralEngine
        case .all: compute = .all
        }
        vad = .init(defaultThreshold: policy.positiveThreshold,debugMode: false,computeUnits: compute)
        let minimumSpeech = max(0.15,padding)
        // These speech-duration knobs are unused by streaming but asserted by
        // the SDK initializer. Rounded-up maximum silence can exceed exact15s.
        segmentation = .init(minSpeechDuration: minimumSpeech,minSilenceDuration: silence,
            maxSpeechDuration: max(15,silence,minimumSpeech),speechPadding: padding,
            silenceThresholdForSplit: policy.negativeThreshold,negativeThreshold: policy.negativeThreshold,
            negativeThresholdOffset: policy.positiveThreshold - policy.negativeThreshold)
    }
}
