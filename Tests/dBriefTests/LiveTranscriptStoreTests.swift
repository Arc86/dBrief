import Foundation
import Testing
import dBriefWire
@testable import dBrief

struct LiveTranscriptFixture {
    let identity = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
    func epoch(_ source: LiveSource = .microphone, origin: Int64? = 0,
               availability: LiveSourceAvailability = .active) -> LiveEpoch {
        .init(id: UUID(), source: source, engineRevision: "nemotron-multilingual-1120", language: "auto",
              meetingOriginNanoseconds: origin, availability: availability)
    }
    func event(_ epoch: LiveEpoch, _ sequence: UInt64, _ payload: LiveTranscriptEvent.Payload) -> LiveTranscriptEvent {
        .init(identity: identity, epochID: epoch.id, source: epoch.source, sequence: sequence, payload: payload)
    }
    func progress(_ captured: Int64, consumed: Int64? = nil) -> LiveTranscriptEvent.Payload {
        .progress(.init(capturedSampleEnd: captured * 16000, admittedSampleEnd: captured * 16000,
                        consumedSampleEnd: (consumed ?? captured) * 16000))
    }
    func range(_ epoch: LiveEpoch, _ start: Int64, _ end: Int64) -> LiveEvidenceRange {
        .init(samples: .init(start: start * 16000, end: end * 16000),
              meeting: epoch.meetingOriginNanoseconds.map {
            .init(startNanoseconds: $0 + start * 1000000000, endNanoseconds: $0 + end * 1000000000)
        })
    }
    func segment(_ epoch: LiveEpoch, _ index: UInt64, _ start: Int64, _ end: Int64, _ text: String = "Committed",
                 context: UUID? = nil) -> CommittedLiveSegment {
        .init(id: .init(epochID: epoch.id, index: index), source: epoch.source, range: range(epoch, start, end),
              text: text, diarizerContextID: context)
    }
    func settlement(_ epoch: LiveEpoch, _ start: Int64, _ end: Int64, _ kind: LiveCoverageInterval.Kind) -> LiveTranscriptEvent.Payload {
        .settled(.init(epochID: epoch.id, source: epoch.source, range: range(epoch, start, end), kind: kind))
    }
}

@Suite struct LiveTranscriptStoreTests {
    @Test func clockRecoveryCannotRewindASourcesHistoricalQualifiedFrontier() async {
        let f = LiveTranscriptFixture(), mic = f.epoch(), system = f.epoch(.system), store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity, epoch: mic) == .accepted)
        #expect(await store.beginEpoch(owner: f.identity, epoch: system) == .accepted)
        #expect(await store.admit(f.event(mic, 0, f.progress(100))) == .accepted)
        #expect(await store.admit(f.event(mic, 1, .committed(f.segment(mic, 0, 0, 100)))) == .accepted)
        #expect(await store.admit(f.event(system, 0, f.progress(10))) == .accepted)
        #expect(await store.admit(f.event(system, 1, f.settlement(system, 0, 10, .processedSilence))) == .accepted)
        let unknown = f.epoch(origin: nil)
        #expect(await store.beginEpoch(owner: f.identity, epoch: unknown) == .accepted)
        #expect(await store.admit(f.event(unknown, 0, f.progress(1))) == .accepted)
        #expect(await store.admit(f.event(unknown, 1, .committed(f.segment(unknown, 0, 0, 1)))) == .accepted)
        let before = await store.snapshot()
        #expect(await store.beginEpoch(owner: f.identity, epoch: f.epoch(origin: 10000000000)) == .rejected(.invalidRange))
        #expect(await store.snapshot() == before)
        #expect(await store.beginEpoch(owner: f.identity, epoch: f.epoch(origin: 101000000000)) == .accepted)
        #expect(await store.admit(f.event(system, 2, f.progress(102))) == .accepted)
        #expect(await store.admit(f.event(system, 3, f.settlement(system, 10, 102, .processedSilence))) == .accepted)
        let recovered = await store.snapshot()
        #expect(recovered.cutoffNanoseconds == 101000000000)
        #expect(recovered.coverage.contains { $0.interval.source == .microphone && $0.interval.kind == .gap(.unknownClock) &&
            $0.interval.range.meeting == .init(startNanoseconds: 100000000000, endNanoseconds: 101000000000) })
    }

    @Test func savedTrackRangesCannotOverlapAcrossMappingRevisionsOrCommits() async {
        let f = LiveTranscriptFixture(), epoch = f.epoch(), store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        #expect(await store.admit(f.event(epoch, 0, f.progress(2))) == .accepted)
        func slice(_ start: Int64, _ end: Int64, _ frame: Int64, _ revision: UInt64) -> LiveSavedAudioSlice {
            .init(samples: .init(start: start, end: end), destination: .track(.microphone), startFrame: frame,
                  frameCount: end - start, sampleRate: 16000, mappingRevision: revision)
        }
        let overlap = CommittedLiveSegment(id: .init(epochID: epoch.id, index: 0), source: .microphone,
            range: .init(samples: .init(start: 0, end: 16000), meeting: f.range(epoch, 0, 1).meeting,
                savedAudio: [slice(0, 8000, 0, 1), slice(8000, 16000, 4000, 2)]), text: "Overlap")
        #expect(await store.admit(f.event(epoch, 1, .committed(overlap))) == .rejected(.invalidRange))
        let first = CommittedLiveSegment(id: overlap.id, source: .microphone,
            range: .init(samples: .init(start: 0, end: 16000), meeting: f.range(epoch, 0, 1).meeting,
                savedAudio: [slice(0, 16000, 0, 1)]), text: "First")
        #expect(await store.admit(f.event(epoch, 1, .committed(first))) == .accepted)
        let before = await store.snapshot()
        let second = CommittedLiveSegment(id: .init(epochID: epoch.id, index: 1), source: .microphone,
            range: .init(samples: .init(start: 16000, end: 32000), meeting: f.range(epoch, 1, 2).meeting,
                savedAudio: [slice(16000, 32000, 0, 2)]), text: "Second")
        #expect(await store.admit(f.event(epoch, 2, .committed(second))) == .rejected(.invalidRange))
        #expect(await store.snapshot() == before)
        let valid = CommittedLiveSegment(id: second.id, source: .microphone,
            range: .init(samples: second.range.samples, meeting: second.range.meeting,
                savedAudio: [slice(16000, 32000, 16000, 2)]), text: "Second")
        #expect(await store.admit(f.event(epoch, 2, .committed(valid))) == .accepted)
    }

    @Test func pendingSlowerLaneLimitsChatButNotTheDisplay() async {
        let f = LiveTranscriptFixture(), mic = f.epoch(), system = f.epoch(.system)
        let store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity, epoch: mic) == .accepted)
        #expect(await store.beginEpoch(owner: f.identity, epoch: system) == .accepted)
        let first = f.segment(mic, 0, 0, 8, "Mic prefix"), later = f.segment(mic, 1, 8, 12, "Mic future")
        let remote = f.segment(system, 0, 0, 8, "System prefix")
        #expect(await store.admit(f.event(mic, 0, f.progress(12))) == .accepted)
        #expect(await store.admit(f.event(mic, 1, .committed(first))) == .accepted)
        #expect(await store.admit(f.event(mic, 2, .committed(later))) == .accepted)
        #expect(await store.admit(f.event(system, 0, f.progress(13))) == .accepted)
        #expect(await store.admit(f.event(system, 1, .committed(remote))) == .accepted)
        #expect(await store.admit(f.event(system, 2, .partial(.init(epochID: system.id, source: .system,
            revision: 1, samples: .init(start: 8 * 16000, end: 13 * 16000), text: "Pending remote")))) == .accepted)
        let frozen = await store.snapshot(), display = await store.projection()
        #expect(frozen.cutoffNanoseconds == 8000000000)
        #expect(Set(frozen.segments.map(\.id)) == Set([first.id, remote.id]))
        #expect(display.segments.count == 3 && display.partials.count == 1)
        #expect(await store.admit(f.event(system, 3, f.settlement(system, 8, 10, .processedSilence))) == .accepted)
        #expect(await store.snapshot().cutoffNanoseconds == 10000000000)
        #expect(await store.admit(f.event(system, 4, f.settlement(system, 10, 13, .gap(.overload)))) == .accepted)
        let after = await store.snapshot()
        #expect(after.cutoffNanoseconds == 12000000000 && after.segments.contains(later))
        let gap = after.coverage.first { $0.interval.kind == .gap(.overload) }
        #expect(gap?.interval.range.meeting?.endNanoseconds == 13000000000)
        #expect(gap?.includedMeeting == .init(startNanoseconds: 10000000000, endNanoseconds: 12000000000))
        #expect(frozen.cutoffNanoseconds == 8000000000 && frozen.segments.count == 2)
    }

    @Test func partialsDoNotChangeTheChatSnapshotAndConsumptionIsNotSettlement() async {
        let f = LiveTranscriptFixture(), epoch = f.epoch(), store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        #expect(await store.admit(f.event(epoch, 0, f.progress(5))) == .accepted)
        let before = await store.snapshot()
        #expect(before.cutoffNanoseconds == 0 && before.segments.isEmpty)
        #expect(await store.admit(f.event(epoch, 1, .partial(.init(epochID: epoch.id, source: .microphone,
            revision: 1, samples: .init(start: 0, end: 80000), text: "Provisional")))) == .accepted)
        #expect(await store.snapshot() == before)
        #expect(await store.projection().partials.count == 1)
    }

    @Test func duplicatesAreIdempotentAndRejectedEventsLeaveNoMutation() async {
        let f = LiveTranscriptFixture(), epoch = f.epoch(), store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        let before = await store.snapshot()
        #expect(await store.admit(f.event(epoch, 1, f.progress(2))) == .rejected(.outOfOrder))
        let wrong = LiveTranscriptEvent(identity: .init(recordingID: UUID(), captureSessionID: f.identity.captureSessionID),
            epochID: epoch.id, source: epoch.source, sequence: 0, payload: f.progress(2))
        #expect(await store.admit(wrong) == .rejected(.wrongOwner))
        #expect(await store.snapshot() == before)
        #expect(await store.admit(f.event(epoch, 0, f.progress(2))) == .accepted)
        let segment = f.segment(epoch, 0, 0, 1), commit = f.event(epoch, 1, .committed(segment))
        #expect(await store.admit(commit) == .accepted)
        let committed = await store.snapshot()
        #expect(await store.admit(commit) == .duplicate)
        #expect(await store.admit(f.event(epoch, 2, .committed(f.segment(epoch, 0, 0, 1, "Conflict")))) == .rejected(.conflictingID))
        #expect(await store.snapshot() == committed)
        #expect(await store.admit(f.event(epoch, 2, f.settlement(epoch, 1, 2, .processedSilence))) == .accepted)
        #expect(await store.projection().segments == [segment])
    }

    @Test func invalidProgressAndCoverageCannotHidePendingOrUndecodedInput() async {
        let f = LiveTranscriptFixture(), epoch = f.epoch(), store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        #expect(await store.admit(f.event(epoch, 0, f.progress(2, consumed: 1))) == .accepted)
        let before = await store.snapshot()
        #expect(await store.admit(f.event(epoch, 1, .committed(f.segment(epoch, 0, 0, 2)))) == .rejected(.invalidRange))
        #expect(await store.admit(f.event(epoch, 1, f.settlement(epoch, 0, 2, .processedSilence))) == .rejected(.invalidRange))
        #expect(await store.admit(f.event(epoch, 1, f.progress(1))) == .rejected(.invalidRange))
        #expect(await store.admit(f.event(epoch, 1, .availability(.disabled))) == .rejected(.unsettledEpoch))
        #expect(await store.snapshot() == before)
        #expect(await store.admit(f.event(epoch, 1, f.settlement(epoch, 0, 2, .gap(.deadline)))) == .accepted)
        #expect(await store.snapshot().cutoffNanoseconds == 2000000000)
    }

    @Test func replacementRequiresSettlementAndRetiresOnlyItsLane() async {
        let f = LiveTranscriptFixture(), old = f.epoch(), other = f.epoch(.system)
        let store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity, epoch: old) == .accepted)
        #expect(await store.beginEpoch(owner: f.identity, epoch: other) == .accepted)
        #expect(await store.admit(f.event(old, 0, f.progress(2, consumed: 1))) == .accepted)
        let new = f.epoch(origin: 2000000000)
        #expect(await store.beginEpoch(owner: f.identity, epoch: new) == .rejected(.unsettledEpoch))
        #expect(await store.admit(f.event(old, 1, f.settlement(old, 0, 2, .gap(.engineRestart)))) == .accepted)
        #expect(await store.beginEpoch(owner: f.identity, epoch: new) == .accepted)
        #expect(await store.admit(f.event(old, 2, f.progress(3))) == .rejected(.staleEpoch))
        #expect(await store.admit(f.event(other, 0, f.progress(1))) == .accepted)
        #expect(await store.admit(f.event(other, 1, .committed(f.segment(other, 0, 0, 1)))) == .accepted)
        #expect(await store.snapshot().segments.count == 1)
    }

    @Test func unalignedAndDisabledSourcesAreQualifiedInsteadOfPinningTheCutoff() async {
        let f = LiveTranscriptFixture(), mic = f.epoch(origin: nil), system = f.epoch(.system, availability: .disabled)
        let store = LiveTranscriptStore(identity: f.identity), text = f.segment(mic, 0, 0, 1, "Unaligned but retained")
        #expect(await store.beginEpoch(owner: f.identity, epoch: mic) == .accepted)
        #expect(await store.beginEpoch(owner: f.identity, epoch: system) == .accepted)
        #expect(await store.admit(f.event(mic, 0, f.progress(1))) == .accepted)
        #expect(await store.admit(f.event(mic, 1, .committed(text))) == .accepted)
        let ordinary = await store.snapshot()
        #expect(ordinary.cutoffNanoseconds == nil && ordinary.segments.isEmpty)
        #expect(Set(ordinary.excludedSources) == Set([.microphone, .system]))
        #expect(await store.projection().segments == [text])
        #expect(await store.snapshot(selection: .evidence([text.id], includeUnaligned: false)).segments.isEmpty)
        let selected = await store.snapshot(selection: .evidence([text.id], includeUnaligned: true))
        #expect(selected.segments == [text] && selected.scope == .unalignedEvidence && selected.cutoffNanoseconds == nil)
    }

    @Test func closureRequiresExactSettlementThenRejectsAllLateLiveEvents() async {
        let f = LiveTranscriptFixture(), epoch = f.epoch(), store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        #expect(await store.admit(f.event(epoch, 0, f.progress(1))) == .accepted)
        #expect(await store.close(owner: f.identity) == .rejected(.unsettledEpoch))
        #expect(await store.admit(f.event(epoch, 1, .committed(f.segment(epoch, 0, 0, 1)))) == .accepted)
        #expect(await store.close(owner: f.identity) == .accepted)
        #expect(await store.close(owner: f.identity) == .duplicate)
        let frozen = await store.snapshot()
        #expect(await store.admit(f.event(epoch, 2, f.progress(2))) == .rejected(.closed))
        #expect(await store.beginEpoch(owner: f.identity, epoch: f.epoch(origin: 1000000000)) == .rejected(.closed))
        let after = await store.snapshot(), display = await store.projection()
        #expect(after == frozen && display.isClosed)
    }

    @Test func savedSlicesCannotOverlapOrBelongToAnotherCaptureSource() async {
        let f = LiveTranscriptFixture(), epoch = f.epoch(), store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        #expect(await store.admit(f.event(epoch, 0, f.progress(1))) == .accepted)
        let before = await store.snapshot()
        for source in [LiveSource.microphone, .system] {
            let slices = [LiveSavedAudioSlice(samples: .init(start: 0, end: 8000), destination: .track(source),
                startFrame: 0, frameCount: 8000, sampleRate: 16000, mappingRevision: 1),
                .init(samples: .init(start: 8000, end: 16000), destination: .track(source),
                    startFrame: 4000, frameCount: 8000, sampleRate: 16000, mappingRevision: 1)]
            let segment = CommittedLiveSegment(id: .init(epochID: epoch.id, index: 0), source: .microphone,
                range: .init(samples: .init(start: 0, end: 16000), meeting: f.range(epoch, 0, 1).meeting, savedAudio: slices), text: "Invalid saved provenance")
            #expect(await store.admit(f.event(epoch, 1, .committed(segment))) == .rejected(.invalidRange))
        }
        #expect(await store.snapshot() == before)
    }

    @Test func disabledLaneCannotPublishDecodedEvidence() async {
        let f = LiveTranscriptFixture(), epoch = f.epoch(availability: .disabled), store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        #expect(await store.admit(f.event(epoch, 0, f.progress(1))) == .accepted)
        #expect(await store.admit(f.event(epoch, 1, .committed(f.segment(epoch, 0, 0, 1)))) == .rejected(.invalidRange))
        #expect(await store.admit(f.event(epoch, 1, f.settlement(epoch, 0, 1, .gap(.disabled)))) == .accepted)
        #expect(await store.projection().segments.isEmpty)
    }

    @Test func aMisroutedOldPayloadIsRejectedInsteadOfTreatedAsADuplicate() async {
        let f = LiveTranscriptFixture(), mic = f.epoch(), system = f.epoch(.system), store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity, epoch: mic) == .accepted)
        #expect(await store.beginEpoch(owner: f.identity, epoch: system) == .accepted)
        let committed = f.segment(mic, 0, 0, 1)
        #expect(await store.admit(f.event(mic, 0, f.progress(1))) == .accepted)
        #expect(await store.admit(f.event(mic, 1, .committed(committed))) == .accepted)
        #expect(await store.admit(f.event(system, 0, f.progress(1))) == .accepted)
        let before = await store.snapshot()
        #expect(await store.admit(f.event(system, 0, .committed(committed))) == .rejected(.staleEpoch))
        #expect(await store.snapshot() == before)
    }

    @Test func rejoiningALaneNeedsANewAnchorAndRetainsDisabledCoverage() async {
        let f = LiveTranscriptFixture(), mic = f.epoch(), disabled = f.epoch(.system, availability: .disabled)
        let store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity, epoch: mic) == .accepted)
        #expect(await store.beginEpoch(owner: f.identity, epoch: disabled) == .accepted)
        #expect(await store.admit(f.event(mic, 0, f.progress(5))) == .accepted)
        #expect(await store.admit(f.event(mic, 1, .committed(f.segment(mic, 0, 0, 5)))) == .accepted)
        #expect(await store.admit(f.event(disabled, 0, .availability(.active))) == .rejected(.invalidRange))
        #expect(await store.snapshot().cutoffNanoseconds == 5000000000)
        let resumed = f.epoch(.system, origin: 5000000000)
        #expect(await store.beginEpoch(owner: f.identity, epoch: resumed) == .accepted)
        let gap = await store.snapshot().coverage.first { $0.interval.source == .system && $0.interval.kind == .gap(.disabled) }
        #expect(gap?.includedMeeting == .init(startNanoseconds: 0, endNanoseconds: 5000000000))
        #expect(gap?.interval.range.samples == nil)
    }
}
