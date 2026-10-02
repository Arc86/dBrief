import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite struct LiveCaptureLossTests {
    private func loss(id: UUID = UUID(), source: LiveSource = .microphone, epoch: UUID? = UUID(),
                      frames: LiveRawFrameRange? = .init(startFrame: 4410,frameCount: 4410,sampleRate: 44100), count: Int64 = 1) -> LiveCaptureRawLoss {
        .init(id: id,source: source,sourceEpoch: epoch,frames: frames,reason: .overload,bufferCount: count)
    }

    @Test func rawLossChangesEvidenceRevisionWithoutInventingProgressOrCutoff() async {
        let f = LiveTranscriptFixture(), store = LiveTranscriptStore(identity: f.identity), mic = f.epoch(), missing = loss()
        #expect(await store.beginEpoch(owner: f.identity,epoch: mic) == .accepted)
        let before = await store.snapshot()
        #expect(await store.recordCaptureLoss(owner: f.identity,loss: missing) == .accepted)
        let after = await store.snapshot(), projection = await store.projection()
        #expect(after.captureLosses == [missing])
        #expect(projection.captureLosses == [missing])
        #expect(after.revision == before.revision + 1)
        #expect(after.lanes == before.lanes && after.coverage == before.coverage && after.cutoffNanoseconds == before.cutoffNanoseconds)
        #expect(before.captureLosses == nil)
        #expect(await store.snapshot(selection: .range(.init(startNanoseconds: 0,endNanoseconds: 1000000))).captureLosses == [missing])
        #expect(await store.recordCaptureLoss(owner: f.identity,loss: missing) == .duplicate)
        #expect(await store.recordCaptureLoss(owner: f.identity,loss: loss(id: missing.id,count: 2)) == .rejected(.conflictingID))
        #expect(await store.snapshot() == after)
    }

    @Test func ownerValidityClosureAndRawRangesAreCheckedAtTheActualWrite() async {
        let f = LiveTranscriptFixture(), guardOwner = RecordingDerivativeValidity(), store = LiveTranscriptStore(identity: f.identity,validity: guardOwner)
        #expect(await store.recordCaptureLoss(owner: LiveTranscriptFixture().identity,loss: loss()) == .rejected(.wrongOwner))
        for missing in [loss(source: .finalMix),loss(epoch: nil),loss(count: 0),loss(frames: .init(startFrame: .max,frameCount: 1,sampleRate: 44100))] {
            #expect(await store.recordCaptureLoss(owner: f.identity,loss: missing) == .rejected(.invalidRange))
        }
        #expect(await store.recordCaptureLoss(owner: f.identity,loss: loss(epoch: nil,frames: nil)) == .accepted)
        let before = await store.snapshot()
        guardOwner.invalidate()
        #expect(await store.recordCaptureLoss(owner: f.identity,loss: loss()) == .rejected(.closed))
        #expect(await store.snapshot() == before)
        let closed = LiveTranscriptStore(identity: f.identity)
        #expect(await closed.close(owner: f.identity) == .accepted)
        #expect(await closed.recordCaptureLoss(owner: f.identity,loss: loss()) == .rejected(.closed))
    }

    @Test func frozenRawLossRoundTripsButDoesNotLeakIntoAFinalPublication() async throws {
        let f = LiveTranscriptFixture(), store = LiveTranscriptStore(identity: f.identity), missing = loss()
        #expect(await store.recordCaptureLoss(owner: f.identity,loss: missing) == .accepted)
        let frozen = await store.snapshot()
        let encoded = try JSONEncoder().encode(frozen)
        #expect(try JSONDecoder().decode(TranscriptSnapshot.self,from: encoded) == frozen)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "captureLosses")
        let old = try JSONDecoder().decode(TranscriptSnapshot.self,from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.captureLosses == nil)
        #expect(await store.recordCaptureLoss(owner: f.identity,loss: loss()) == .accepted)
        #expect(frozen.captureLosses == [missing])
        #expect(await store.close(owner: f.identity) == .accepted)
        #expect(await store.publishFinal(.init(identity: f.identity,id: UUID(),revision: 1,segments: [])) == .accepted)
        #expect(await store.snapshot().captureLosses == nil)
        #expect(await store.projection().captureLosses.count == 2)
    }
}
