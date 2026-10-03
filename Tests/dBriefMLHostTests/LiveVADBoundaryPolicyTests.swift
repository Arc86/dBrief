import Foundation
import Testing
import dBriefWire
@testable import dBriefMLHost

private actor BoundaryPredictor: LiveVADPredicting {
    func predict(_ input: LiveVADNativeInput) async throws -> LiveVADNativeOutput {
        try .init(probability: 1,hiddenState: [Float](repeating: 0,count: 128),cellState: [Float](repeating: 0,count: 128))
    }
}

@Suite struct LiveVADBoundaryPolicyTests {
    private func identity(minimum: Int = 9600, padding: Int = 1600, negative: Float = 0.70,
                          runtime: String = LiveVADNativeConfiguration.runtimeRevision,
                          implementation: String = LiveVADIdentity.currentImplementationRevision) -> LiveVADIdentity {
        .init(modelRevision: "silero-vad-unified-256ms-v6.2.1",modelFingerprint: String(repeating: "a",count: 64),
              runtimeRevision: runtime,positiveThreshold: 0.85,negativeThreshold: negative,
              minSilenceSamples: minimum,speechPaddingSamples: padding,implementationRevision: implementation)
    }
    private func policy(minimum: Int = 9600, padding: Int = 1600, negative: Float = 0.70,
                        source: LiveSource = .microphone, id: UUID = UUID(), start: Int64 = 0) throws -> LiveVADBoundaryPolicy {
        try .init(identity: identity(minimum: minimum,padding: padding,negative: negative),source: source,continuityID: id,sampleStart: start)
    }
    private func observe(_ p: inout LiveVADBoundaryPolicy, _ probability: Float) throws -> LiveVADBoundaryDecision {
        try p.observe(.init(source: p.source,continuityID: p.continuityID,sampleStart: p.processedEnd,
                            sampleEnd: p.processedEnd+4096,probability: probability))
    }

    @Test func thresholdsUseExactFrozenEquality() throws {
        var p = try policy()
        #expect(try observe(&p,0.85).thresholdClass == .entry)
        #expect(try observe(&p,Float(0.85).nextDown).thresholdClass == .band)
        #expect(try observe(&p,0.70).thresholdClass == .band)
        #expect(try observe(&p,Float(0.70).nextDown).thresholdClass == .belowExit)
        #expect(p.quietSamples == 4096 && p.speechArmed)
        #expect(try observe(&p,1).thresholdClass == .entry)
        #expect(p.quietSamples == 0 && p.speechArmed)
        var zero = try policy(minimum: 1,negative: 0)
        _ = try observe(&zero,1)
        #expect(try observe(&zero,0).thresholdClass == .band)
        #expect(zero.quietSamples == 0 && zero.speechArmed)
    }

    @Test(arguments: [1,4096,4097,9600,240000])
    func minimumSilenceQuantizesToWholeObservedWindows(minimum: Int) throws {
        var p = try policy(minimum: minimum)
        _ = try observe(&p,1)
        let windows = (minimum+4095)/4096
        for i in 1...windows {
            let decision = try observe(&p,0)
            #expect(decision.range == LiveSampleRange(start: Int64(i)*4096,end: Int64(i+1)*4096))
            #expect(decision.thresholdClass == .belowExit)
            #expect(decision.flushEnd == (i == windows ? Int64(i+1)*4096 : nil))
            #expect((0...minimum).contains(p.quietSamples))
        }
        #expect(!p.speechArmed && p.quietSamples == 0)
    }

    @Test func leadingQuietAndRepeatedQuietCannotInventOrDuplicateSpeechEnd() throws {
        var p = try policy(minimum: 1)
        for _ in 0..<100 {
            let decision = try observe(&p,0)
            #expect(decision.thresholdClass == .belowExit && decision.flushEnd == nil)
            #expect(!p.speechArmed && p.quietSamples == 0)
        }
        _ = try observe(&p,1)
        #expect(try observe(&p,0).flushEnd == 102*4096)
        for _ in 0..<100 { #expect(try observe(&p,0).flushEnd == nil) }
        _ = try observe(&p,1)
        #expect(try observe(&p,0).flushEnd == 204*4096)
    }

    @Test(arguments: [Float(0.70),Float(0.80),Float(0.85),Float(1)])
    func bandOrEntryRestartsConsecutiveQuietCount(interruption: Float) throws {
        var p = try policy()
        _ = try observe(&p,1); _ = try observe(&p,0); _ = try observe(&p,0)
        #expect(p.quietSamples == 8192)
        #expect(try observe(&p,interruption).flushEnd == nil)
        #expect(p.speechArmed && p.quietSamples == 0)
        #expect(try observe(&p,0).flushEnd == nil)
        #expect(try observe(&p,0).flushEnd == nil)
        #expect(try observe(&p,0).flushEnd == 7*4096)
    }

    @Test(arguments: [0,1,1600,4096])
    func paddingNeverMovesFlushBeyondActualWindowEnd(padding: Int) throws {
        var p = try policy(padding: padding)
        #expect(p.identity == identity(padding: padding))
        _ = try observe(&p,1); _ = try observe(&p,0); _ = try observe(&p,0)
        let decision = try observe(&p,0)
        #expect(decision.range.end == 16384 && decision.flushEnd == decision.range.end)
    }

    @Test(arguments: ["source","continuity","duplicate","gap","negative-start","short","long","nan","infinity","negative-probability","above-one"])
    func invalidWindowRollsBackWholePolicyAndValidRetryCanFlush(mode: String) throws {
        var p = try policy()
        _ = try observe(&p,1); _ = try observe(&p,0); _ = try observe(&p,0)
        let before = p
        var source = p.source, id = p.continuityID, start = p.processedEnd, end = start+4096, probability: Float = 0
        switch mode {
        case "source": source = .system
        case "continuity": id = UUID()
        case "duplicate": start -= 4096; end -= 4096
        case "gap": start += 4096; end += 4096
        case "negative-start": start = -4096; end = 0
        case "short": end -= 1
        case "long": end += 1
        case "nan": probability = .nan
        case "infinity": probability = .infinity
        case "negative-probability": probability = -0.01
        default: probability = 1.01
        }
        #expect(throws: LiveVADBoundaryError.invalidWindow) {
            _ = try p.observe(.init(source: source,continuityID: id,sampleStart: start,sampleEnd: end,probability: probability))
        }
        #expect(p == before)
        #expect(try observe(&p,0).flushEnd == 16384)
    }

    @Test func overflowingEndpointCannotMutatePolicyOrGrantCoverage() throws {
        var p = try policy(start: .max-2048)
        let before = p
        #expect(throws: LiveVADBoundaryError.invalidWindow) {
            _ = try p.observe(.init(source: p.source,continuityID: p.continuityID,sampleStart: p.processedEnd,sampleEnd: .max,probability: 1))
        }
        #expect(p == before && p.processedEnd == .max-2048 && !p.speechArmed)
    }

    @Test(arguments: ["runtime","implementation","minimum-zero","minimum-large","padding-negative","padding-large","threshold","source","start"])
    func invalidFrozenPolicyCannotBeConstructed(mode: String) throws {
        let value: LiveVADIdentity
        switch mode {
        case "runtime": value = identity(runtime: "foreign")
        case "implementation": value = identity(implementation: "foreign")
        case "minimum-zero": value = identity(minimum: 0)
        case "minimum-large": value = identity(minimum: 240001)
        case "padding-negative": value = identity(padding: -1)
        case "padding-large": value = identity(padding: 4097)
        case "threshold": value = identity(negative: 0.85)
        default: value = identity()
        }
        #expect(throws: LiveVADBoundaryError.invalidConfiguration) {
            _ = try LiveVADBoundaryPolicy(identity: value,source: mode == "source" ? .finalMix : .microphone,
                                           continuityID: UUID(),sampleStart: mode == "start" ? -1 : 0)
        }
    }

    @Test func independentSourcesAndFreshContinuityDoNotShareSpeechState() throws {
        var mic = try policy(), system = try policy(source: .system), fresh = try policy()
        _ = try observe(&mic,1); _ = try observe(&mic,0); _ = try observe(&mic,0)
        #expect(try observe(&system,0).flushEnd == nil)
        #expect(try observe(&fresh,0).flushEnd == nil)
        #expect(try observe(&mic,0).flushEnd == 16384)
        #expect(!fresh.speechArmed && !system.speechArmed)
    }

    @Test func windowProducerBindsSourceAndFreshIDAcrossConsecutiveResults() async throws {
        let predictor = BoundaryPredictor()
        let mic = try LiveVADWindowSession(source: .microphone,predictor: predictor,sampleStart: 91)
        let system = try LiveVADWindowSession(source: .system,predictor: predictor)
        let fresh = try LiveVADWindowSession(source: .microphone,predictor: predictor)
        #expect(mic.continuityID != system.continuityID && mic.continuityID != fresh.continuityID)
        let first = try await mic.process(samples: [Float](repeating: 0,count: 4096),startSample: 91)
        let second = try await mic.process(samples: [Float](repeating: 0,count: 4096),startSample: 4187)
        #expect(first.source == .microphone && first.continuityID == mic.continuityID && second.continuityID == first.continuityID)
        var p = try policy(id: mic.continuityID,start: 91)
        #expect(try p.observe(first).range == LiveSampleRange(start: 91,end: 4187))
        #expect(try p.observe(second).range == LiveSampleRange(start: 4187,end: 8283))
        var replacement = try policy(id: fresh.continuityID)
        #expect(throws: LiveVADBoundaryError.invalidWindow) { _ = try replacement.observe(first) }
    }
}
