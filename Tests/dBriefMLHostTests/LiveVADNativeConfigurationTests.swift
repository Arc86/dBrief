import CoreML
import FluidAudio
import Foundation
import Testing
import dBriefWire
@testable import dBriefMLHost

@Suite struct LiveVADNativeConfigurationTests {
    @Test func unknownHelperImplementationRefusesBeforeNativeConstruction() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration())) as? [String: Any])
        var identity = try #require(object["identity"] as? [String: Any])
        identity["implementationRevision"] = "another-vad-adapter"; object["identity"] = identity
        let config = try JSONDecoder().decode(LiveVADConfiguration.self,from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: LiveProtocolError.invalidConfiguration) { _ = try LiveVADNativeConfiguration(config) }
    }
    private func configuration(silence: Int = 9600, padding: Int = 1600, positive: Float = 0.85, negative: Float = 0.70,
                               runtime: String = "21493f8dac5a97e65742e6ff26f42f164c2fda0f",
                               compute: LiveVADIdentity.ComputeUnits = .cpuAndNeuralEngine) -> LiveVADConfiguration {
        .init(identity: .init(modelRevision: "fixture-silero",modelFingerprint: String(repeating: "a",count: 64),runtimeRevision: runtime,
            computeUnits: compute,positiveThreshold: positive,negativeThreshold: negative,minSilenceSamples: silence,speechPaddingSamples: padding),
            modelPath: "/fixture/silero.mlmodelc")
    }

    @Test(arguments: [1,1001,4096,9600,224000,239999,240000], [0,1001,1600,4096])
    func SDKMappingPreservesExactSamplePolicyAndSatisfiesItsAssertions(silence: Int, padding: Int) throws {
        let config = configuration(silence: silence,padding: padding)
        let native = try LiveVADNativeConfiguration(config)
        let segmentation = native.segmentation
        #expect(Int(segmentation.minSilenceDuration * 16000) == silence)
        #expect(Int(segmentation.speechPadding * 16000) == padding)
        #expect(segmentation.speechPadding <= segmentation.minSpeechDuration)
        #expect(segmentation.minSpeechDuration <= segmentation.maxSpeechDuration)
        #expect(segmentation.minSilenceDuration <= segmentation.maxSpeechDuration)
        let negative = try #require(segmentation.negativeThreshold)
        #expect(negative <= segmentation.silenceThresholdForSplit)
        #expect(min(1,negative + segmentation.negativeThresholdOffset) == config.identity.positiveThreshold)
        #expect(segmentation.effectiveNegativeThreshold(baseThreshold: native.vad.defaultThreshold) == config.identity.negativeThreshold)
    }

    @Test func nonfiniteUnorderedAndUnsupportedPoliciesRejectBeforeSDKConstruction() {
        for config in [configuration(positive: .nan),configuration(negative: .infinity),configuration(positive: -.infinity),
            configuration(positive: 0),configuration(positive: 1.01),configuration(negative: -0.01),
            configuration(negative: 0.85),configuration(positive: 0.05,negative: 0.01),
            configuration(silence: 0),configuration(silence: 240001),
            configuration(padding: -1),configuration(padding: 4097),configuration(runtime: "other-runtime")] {
            #expect(throws: LiveProtocolError.invalidConfiguration) { try LiveVADNativeConfiguration(config) }
        }
    }

    @Test func everyFrozenComputeChoiceMapsExactlyWithoutLoadingAModel() throws {
        for (choice,expected): (LiveVADIdentity.ComputeUnits,MLComputeUnits) in [(.cpuOnly,.cpuOnly),(.cpuAndGPU,.cpuAndGPU),
            (.cpuAndNeuralEngine,.cpuAndNeuralEngine),(.all,.all)] {
            #expect(try LiveVADNativeConfiguration(configuration(compute: choice)).vad.computeUnits == expected)
        }
    }
}
