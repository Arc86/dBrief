import Foundation
import Testing
import dBriefWire
@testable import dBrief

/// Decode future/legacy wire shapes to exercise behavior before adding the field.
enum ConsumptionFrontierFixture {
    static func progress<T: Decodable>(_ type: T.Type, end: Int64, common: Int64, asr: Int64?, helper: Bool = false) throws -> T {
        var fields: [String: Any] = ["capturedSampleEnd": end,"admittedSampleEnd": end,"consumedSampleEnd": common]
        if let asr { fields["asrConsumedSampleEnd"] = asr }
        if helper {
            fields["queuedSamples"] = 0; fields["inFlightSamples"] = 0
            fields["heldSamples"] = end-common; fields["creditSamples"] = 49920-(end-common)
        }
        return try JSONDecoder().decode(type,from: JSONSerialization.data(withJSONObject: fields))
    }
    static func effectiveASR<T: Encodable>(_ value: T, common: Int64) throws -> Int64 {
        let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        return (fields["asrConsumedSampleEnd"] as? NSNumber)?.int64Value ?? common
    }
}

@Suite struct LiveConsumptionFrontierTests {
    @Test(arguments: [false,true])
    func absentAndNullASRFieldsKeepTheLegacyFrontier(null: Bool) throws {
        var fields: [String: Any] = ["capturedSampleEnd": 4800,"admittedSampleEnd": 4800,"consumedSampleEnd": 4096,
            "queuedSamples": 0,"inFlightSamples": 0,"heldSamples": 704,"creditSamples": 49216]
        if null { fields["asrConsumedSampleEnd"] = NSNull() }
        let bytes = try JSONSerialization.data(withJSONObject: fields)
        let helper = try JSONDecoder().decode(LiveHelperProgress.self,from: bytes)
        let store = try JSONDecoder().decode(LiveLaneProgress.self,from: bytes)
        #expect(helper.asrConsumedSampleEnd == nil && store.asrConsumedSampleEnd == nil)
        #expect(helper.effectiveASRConsumedSampleEnd == 4096 && store.effectiveASRConsumedSampleEnd == 4096)
        #expect(try JSONDecoder().decode(LiveHelperProgress.self,from: JSONEncoder().encode(helper)) == helper)
        #expect(try JSONDecoder().decode(LiveLaneProgress.self,from: JSONEncoder().encode(store)) == store)
    }

    @Test func separatelyCertifiedProcessedCoverageUsesASREvidence() async throws {
        let f = LiveTranscriptFixture(), epoch = f.epoch(origin: nil), store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity,epoch: epoch) == .accepted)
        #expect(await store.admit(f.event(epoch,0,.progress(try ConsumptionFrontierFixture.progress(LiveLaneProgress.self,end: 4800,common: 4096,asr: 4800)))) == .accepted)
        // This is supplied coverage evidence. Consumption itself does not
        // manufacture a silence certificate or any coverage interval.
        #expect(await store.projection().coverage.isEmpty)
        #expect(await store.admit(f.event(epoch,1,.settled(.init(epochID: epoch.id,source: .microphone,
            range: .init(samples: .init(start: 0,end: 4800),meeting: nil),kind: .processedSilence)))) == .accepted)
    }

    @Test(arguments: [Int64(4800),240000])
    func committedEvidenceCanExceedTheCommonCreditFrontier(end: Int64) async throws {
        let f = LiveTranscriptFixture(), epoch = f.epoch(origin: nil), store = LiveTranscriptStore(identity: f.identity)
        let common = end/4096*4096
        #expect(end-common == (end == 4800 ? 704 : 2432))
        #expect(await store.beginEpoch(owner: f.identity,epoch: epoch) == .accepted)
        let progress = try ConsumptionFrontierFixture.progress(LiveLaneProgress.self,end: end,common: common,asr: end)
        #expect(await store.admit(f.event(epoch,0,.progress(progress))) == .accepted)
        let segment = CommittedLiveSegment(id: .init(epochID: epoch.id,index: 0),source: .microphone,
            range: .init(samples: .init(start: 0,end: end),meeting: nil),text: "Real ASR prefix")
        #expect(await store.admit(f.event(epoch,1,.committed(segment))) == .accepted)
        let snapshot = await store.snapshot()
        let reloaded = try JSONDecoder().decode(TranscriptSnapshot.self,from: JSONEncoder().encode(snapshot))
        #expect(reloaded == snapshot)
        let lane = try #require(reloaded.lanes.first)
        #expect(try ConsumptionFrontierFixture.effectiveASR(lane.progress,common: lane.progress.consumedSampleEnd) == end)
        #expect(lane.progress.consumedSampleEnd == common)
    }

    @Test(arguments: ["common_exceeds_asr","asr_exceeds_admitted","negative_asr","asr_rewinds","common_rewinds","omitted_rewinds"])
    func invalidOrRegressingFrontiersCannotMutateTheStore(kind: String) async throws {
        let f = LiveTranscriptFixture(), epoch = f.epoch(origin: nil), store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity,epoch: epoch) == .accepted)
        #expect(await store.admit(f.event(epoch,0,.progress(try ConsumptionFrontierFixture.progress(LiveLaneProgress.self,end: 4800,common: 4096,asr: 4800)))) == .accepted)
        let before = await store.snapshot()
        var common: Int64 = 4096, asr: Int64? = 4800
        switch kind {
        case "common_exceeds_asr": asr = 4000
        case "asr_exceeds_admitted": asr = 4801
        case "negative_asr": asr = -1
        case "asr_rewinds": asr = 4500
        case "common_rewinds": common = 4000
        default: asr = nil
        }
        let invalid = try ConsumptionFrontierFixture.progress(LiveLaneProgress.self,end: 4800,common: common,asr: asr)
        #expect(await store.admit(f.event(epoch,1,.progress(invalid))) == .rejected(.invalidRange))
        #expect(await store.snapshot() == before)
    }

    @Test func explicitHelperAndStoreFrontiersRoundTripWithoutReturningCredit() throws {
        let helper = try ConsumptionFrontierFixture.progress(LiveHelperProgress.self,end: 4800,common: 4096,asr: 4800,helper: true)
        let store = try ConsumptionFrontierFixture.progress(LiveLaneProgress.self,end: 4800,common: 4096,asr: 4800)
        #expect(try ConsumptionFrontierFixture.effectiveASR(helper,common: helper.consumedSampleEnd) == 4800)
        #expect(try ConsumptionFrontierFixture.effectiveASR(store,common: store.consumedSampleEnd) == 4800)
        #expect(helper.heldSamples == 704 && helper.creditSamples == 49216)
    }
}
