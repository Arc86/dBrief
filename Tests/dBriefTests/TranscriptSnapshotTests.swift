import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite struct TranscriptSnapshotTests {
    @Test func attributionCorrectionReplacesOnlyItsOwnCoverageInterval() async {
        let f = LiveTranscriptFixture(), epoch = f.epoch(.system), context = UUID()
        let store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        #expect(await store.registerDiarizer(owner: f.identity, source: .system, contextID: context) == .accepted)
        #expect(await store.admit(f.event(epoch, 0, f.progress(2))) == .accepted)
        #expect(await store.admit(f.event(epoch, 1, .committed(f.segment(epoch, 0, 0, 2, context: context)))) == .accepted)
        #expect(await store.annotate(owner: f.identity, source: .system, contextID: context, sequence: 0,
            annotations: [], coverage: [.init(source: .system, contextID: context,
                meeting: .init(startNanoseconds: 0, endNanoseconds: 2000000000), status: .resolved)]) == .accepted)
        let frozen = await store.snapshot()
        #expect(await store.annotate(owner: f.identity, source: .system, contextID: context, sequence: 1,
            annotations: [], coverage: [.init(source: .system, contextID: context,
                meeting: .init(startNanoseconds: 1000000000, endNanoseconds: 2000000000), status: .unknown)]) == .accepted)
        let current = await store.snapshot()
        #expect(current.attributionCoverage == [.init(source: .system, contextID: context,
            meeting: .init(startNanoseconds: 0, endNanoseconds: 1000000000), status: .resolved),
            .init(source: .system, contextID: context, meeting: .init(startNanoseconds: 1000000000, endNanoseconds: 2000000000), status: .unknown)])
        #expect(frozen.attributionCoverage.count == 1 && frozen.attributionCoverage.first?.status == .resolved)
    }

    @Test func identitiesAndSnapshotsSurviveCodableRoundTrips() async throws {
        let f = LiveTranscriptFixture(), epoch = f.epoch(), store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        #expect(await store.admit(f.event(epoch, 0, f.progress(1))) == .accepted)
        let segment = f.segment(epoch, 7, 0, 1)
        #expect(await store.admit(f.event(epoch, 1, .committed(segment))) == .accepted)
        let snapshot = await store.snapshot(), bytes = try JSONEncoder().encode(snapshot)
        let reloaded = try JSONDecoder().decode(TranscriptSnapshot.self, from: bytes)
        #expect(snapshot == reloaded && reloaded.segments.first?.id == segment.id)
        #expect(try JSONDecoder().decode(LiveSegmentID.self, from: JSONEncoder().encode(segment.id)).description == segment.id.description)
    }

    @Test func attributionIsIndependentOfASREpochAndFrozenPerSnapshot() async {
        let f = LiveTranscriptFixture(), epoch = f.epoch(.system), context = UUID()
        let store = LiveTranscriptStore(identity: f.identity), first = f.segment(epoch, 0, 0, 1, context: context)
        #expect(await store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        #expect(await store.registerDiarizer(owner: f.identity, source: .system, contextID: context) == .accepted)
        #expect(await store.admit(f.event(epoch, 0, f.progress(1))) == .accepted)
        #expect(await store.admit(f.event(epoch, 1, .committed(first))) == .accepted)
        let replacement = f.epoch(.system, origin: 1000000000)
        #expect(await store.beginEpoch(owner: f.identity, epoch: replacement) == .accepted)
        let key = SpeakerTrackKey(captureSessionID: f.identity.captureSessionID, source: .system, contextID: context, slot: 0)
        #expect(await store.annotate(owner: f.identity, source: .system, contextID: context, sequence: 0,
            annotations: [.init(segmentID: first.id, assignment: .track(key))]) == .accepted)
        let frozen = await store.snapshot()
        #expect(frozen.cutoffNanoseconds == 1000000000 && frozen.speakerLegend == [key])
        #expect(await store.annotate(owner: f.identity, source: .system, contextID: context, sequence: 1,
            annotations: [.init(segmentID: first.id, assignment: .unknown)],
            coverage: [.init(source: .system, contextID: context,
                meeting: .init(startNanoseconds: 0, endNanoseconds: 1000000000), status: .unknown)]) == .accepted)
        let after = await store.snapshot()
        #expect(after.cutoffNanoseconds == frozen.cutoffNanoseconds && after.segments == frozen.segments)
        #expect(after.speakerLegend.isEmpty && after.annotationRevision > frozen.annotationRevision)
        #expect(frozen.annotations.first?.assignment == .track(key) && frozen.speakerLegend == [key])
    }

    @Test func wrongSpeakerScopeAndStaleAnnotationCannotChangeTheBasis() async {
        let f = LiveTranscriptFixture(), epoch = f.epoch(.system), context = UUID()
        let store = LiveTranscriptStore(identity: f.identity), first = f.segment(epoch, 0, 0, 1, context: context)
        #expect(await store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        #expect(await store.registerDiarizer(owner: f.identity, source: .system, contextID: context) == .accepted)
        #expect(await store.admit(f.event(epoch, 0, f.progress(1))) == .accepted)
        #expect(await store.admit(f.event(epoch, 1, .committed(first))) == .accepted)
        let before = await store.snapshot()
        let wrong = SpeakerTrackKey(captureSessionID: UUID(), source: .system, contextID: context, slot: 0)
        #expect(await store.annotate(owner: f.identity, source: .system, contextID: context, sequence: 0,
            annotations: [.init(segmentID: first.id, assignment: .track(wrong))]) == .rejected(.invalidAnnotation))
        #expect(await store.annotate(owner: f.identity, source: .system, contextID: UUID(), sequence: 0,
            annotations: [.init(segmentID: first.id, assignment: .unknown)]) == .rejected(.invalidAnnotation))
        #expect(await store.snapshot() == before)
    }

    @Test func finalPublicationChangesFutureQuestionsWithoutChangingFrozenLiveEvidence() async {
        let f = LiveTranscriptFixture(), epoch = f.epoch(), store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        #expect(await store.admit(f.event(epoch, 0, f.progress(1))) == .accepted)
        #expect(await store.admit(f.event(epoch, 1, .committed(f.segment(epoch, 0, 0, 1, "Live wording")))) == .accepted)
        let frozen = await store.snapshot(), publicationID = UUID()
        let final = CommittedLiveSegment(id: .init(epochID: publicationID, index: 0), source: .finalMix,
            range: .init(samples: nil, meeting: nil), text: "Durable final wording")
        let publication = TranscriptSourcePublication(identity: f.identity, id: publicationID, revision: 1, segments: [final])
        #expect(await store.publishFinal(publication) == .rejected(.unsettledEpoch))
        #expect(await store.close(owner: f.identity) == .accepted)
        #expect(await store.publishFinal(publication) == .accepted)
        #expect(await store.publishFinal(publication) == .duplicate)
        let current = await store.snapshot()
        #expect(current.sourceVersion == .final && current.scope == .completeFinal && current.segments == [final])
        #expect(frozen.sourceVersion == .live && frozen.segments.first?.text == "Live wording")
        #expect(await store.projection().segments.first?.text == "Live wording")
    }

    @Test func selectedRangesAndIDsCannotReachFasterEvidenceBeyondTheCutoff() async {
        let f = LiveTranscriptFixture(), mic = f.epoch(), system = f.epoch(.system), store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity, epoch: mic) == .accepted)
        #expect(await store.beginEpoch(owner: f.identity, epoch: system) == .accepted)
        let first = f.segment(mic, 0, 0, 1), faster = f.segment(mic, 1, 1, 3)
        #expect(await store.admit(f.event(mic, 0, f.progress(3))) == .accepted)
        #expect(await store.admit(f.event(mic, 1, .committed(first))) == .accepted)
        #expect(await store.admit(f.event(mic, 2, .committed(faster))) == .accepted)
        #expect(await store.admit(f.event(system, 0, f.progress(1))) == .accepted)
        #expect(await store.admit(f.event(system, 1, f.settlement(system, 0, 1, .processedSilence))) == .accepted)
        let selected = await store.snapshot(selection: .evidence([first.id, faster.id], includeUnaligned: true))
        #expect(selected.segments == [first] && selected.scope == .selectedEvidence)
        let ranged = await store.snapshot(selection: .range(.init(startNanoseconds: 0, endNanoseconds: 3000000000)))
        #expect(ranged.segments == [first] && ranged.scope == .selectedRange)
    }

    @Test func aStraddlingCommitIsCoveredButItsTextIsExplicitlyOmitted() async {
        let f = LiveTranscriptFixture(), mic = f.epoch(), system = f.epoch(.system), store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity, epoch: mic) == .accepted)
        #expect(await store.beginEpoch(owner: f.identity, epoch: system) == .accepted)
        #expect(await store.admit(f.event(mic, 0, f.progress(12))) == .accepted)
        #expect(await store.admit(f.event(mic, 1, .committed(f.segment(mic, 0, 0, 12)))) == .accepted)
        #expect(await store.admit(f.event(system, 0, f.progress(8))) == .accepted)
        #expect(await store.admit(f.event(system, 1, .committed(f.segment(system, 0, 0, 8)))) == .accepted)
        let snapshot = await store.snapshot()
        #expect(snapshot.cutoffNanoseconds == 8000000000 && snapshot.segments.count == 1)
        let micCoverage = snapshot.coverage.first { $0.interval.source == .microphone }
        #expect(micCoverage?.includedMeeting?.endNanoseconds == 8000000000 && micCoverage?.textIncluded == false)
    }

    @Test func aRetiredDiarizerContextCannotBeReusedAsTheSameSpeakerNamespace() async {
        let f = LiveTranscriptFixture(), epoch = f.epoch(.system), store = LiveTranscriptStore(identity: f.identity)
        let old = UUID(), new = UUID()
        #expect(await store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        #expect(await store.registerDiarizer(owner: f.identity, source: .system, contextID: old) == .accepted)
        #expect(await store.registerDiarizer(owner: f.identity, source: .system, contextID: new) == .accepted)
        #expect(await store.registerDiarizer(owner: f.identity, source: .system, contextID: old) == .rejected(.invalidAnnotation))
        #expect(await store.registerDiarizer(owner: f.identity, source: .system, contextID: new) == .duplicate)
    }

    @Test func finalSourceCannotSeekIntoCapturedTracksOrMutateTextWithinAVersion() async {
        let f = LiveTranscriptFixture(), store = LiveTranscriptStore(identity: f.identity), id = UUID()
        #expect(await store.close(owner: f.identity) == .accepted)
        let invalid = CommittedLiveSegment(id: .init(epochID: id, index: 0), source: .finalMix,
            range: .init(samples: nil, meeting: nil, savedAudio: [.init(samples: nil, destination: .track(.microphone),
                startFrame: 0, frameCount: 16000, sampleRate: 16000, mappingRevision: 1)]), text: "Final")
        #expect(await store.publishFinal(.init(identity: f.identity, id: id, revision: 1, segments: [invalid])) == .rejected(.invalidRange))
        let valid = CommittedLiveSegment(id: invalid.id, source: .finalMix,
            range: .init(samples: nil, meeting: nil, savedAudio: [.init(samples: nil, destination: .master,
                startFrame: 0, frameCount: 16000, sampleRate: 16000, mappingRevision: 1)]), text: "Final")
        #expect(await store.publishFinal(.init(identity: f.identity, id: id, revision: 1, segments: [valid])) == .accepted)
        let before = await store.snapshot()
        let changed = CommittedLiveSegment(id: valid.id, source: .finalMix, range: valid.range, text: "Changed")
        #expect(await store.publishFinal(.init(identity: f.identity, id: id, revision: 2, segments: [changed])) == .rejected(.conflictingID))
        #expect(await store.publishFinal(.init(identity: f.identity, id: id, revision: 0, segments: [valid])) == .rejected(.stalePublication))
        #expect(await store.snapshot() == before)
    }

    @Test func replacementDiarizerCannotClaimEarlierContextCoverage() async {
        let f = LiveTranscriptFixture(), epoch = f.epoch(.system), store = LiveTranscriptStore(identity: f.identity)
        let old = UUID(), new = UUID()
        #expect(await store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        #expect(await store.registerDiarizer(owner: f.identity, source: .system, contextID: old) == .accepted)
        #expect(await store.admit(f.event(epoch, 0, f.progress(2))) == .accepted)
        #expect(await store.admit(f.event(epoch, 1, .committed(f.segment(epoch, 0, 0, 2, context: old)))) == .accepted)
        #expect(await store.registerDiarizer(owner: f.identity, source: .system, contextID: new) == .accepted)
        let before = await store.snapshot()
        #expect(await store.annotate(owner: f.identity, source: .system, contextID: new, sequence: 0, annotations: [],
            coverage: [.init(source: .system, contextID: new, meeting: .init(startNanoseconds: 0, endNanoseconds: 1000000000),
                status: .resolved)]) == .rejected(.invalidAnnotation))
        #expect(await store.snapshot() == before)
        let next = f.epoch(.system, origin: 2000000000)
        #expect(await store.beginEpoch(owner: f.identity, epoch: next) == .accepted)
        #expect(await store.admit(f.event(next, 0, f.progress(1))) == .accepted)
        let segment = f.segment(next, 0, 0, 1, context: new)
        #expect(await store.admit(f.event(next, 1, .committed(segment))) == .accepted)
        #expect(await store.annotate(owner: f.identity, source: .system, contextID: new, sequence: 0,
            annotations: [.init(segmentID: segment.id, assignment: .unknown)], coverage: [.init(source: .system,
                contextID: new, meeting: .init(startNanoseconds: 2000000000, endNanoseconds: 3000000000), status: .unknown)]) == .accepted)
    }

    @Test func unalignedDiarizerCannotLabelInputBeforeItsRegistration() async {
        let f = LiveTranscriptFixture(), epoch = f.epoch(.system, origin: nil), store = LiveTranscriptStore(identity: f.identity)
        let old = UUID(), new = UUID()
        #expect(await store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        #expect(await store.registerDiarizer(owner: f.identity, source: .system, contextID: old) == .accepted)
        #expect(await store.admit(f.event(epoch, 0, f.progress(1))) == .accepted)
        #expect(await store.registerDiarizer(owner: f.identity, source: .system, contextID: new) == .accepted)
        let premature = f.segment(epoch, 0, 0, 1, context: new), before = await store.snapshot()
        #expect(await store.admit(f.event(epoch, 1, .committed(premature))) == .rejected(.invalidRange))
        #expect(await store.snapshot() == before)
        #expect(await store.admit(f.event(epoch, 1, .committed(f.segment(epoch, 0, 0, 1)))) == .accepted)
        #expect(await store.admit(f.event(epoch, 2, f.progress(2))) == .accepted)
        let eligible = f.segment(epoch, 1, 1, 2, context: new)
        #expect(await store.admit(f.event(epoch, 3, .committed(eligible))) == .accepted)
        let key = SpeakerTrackKey(captureSessionID: f.identity.captureSessionID, source: .system, contextID: new, slot: 0)
        #expect(await store.annotate(owner: f.identity, source: .system, contextID: new, sequence: 0,
            annotations: [.init(segmentID: eligible.id, assignment: .track(key))]) == .accepted)
        #expect(await store.snapshot(selection: .evidence([eligible.id], includeUnaligned: true)).speakerLegend == [key])
    }

    @Test func diarizerNamespaceSurvivesClockRecoveryWithoutClaimingUnknownChronology() async {
        let f = LiveTranscriptFixture(), initial = f.epoch(.system, origin: nil), context = UUID()
        let store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity, epoch: initial) == .accepted)
        #expect(await store.registerDiarizer(owner: f.identity, source: .system, contextID: context) == .accepted)
        #expect(await store.admit(f.event(initial, 0, f.progress(1))) == .accepted)
        #expect(await store.admit(f.event(initial, 1, f.settlement(initial, 0, 1, .processedSilence))) == .accepted)
        let aligned = f.epoch(.system, origin: 1000000000)
        #expect(await store.beginEpoch(owner: f.identity, epoch: aligned) == .accepted)
        #expect(await store.admit(f.event(aligned, 0, f.progress(1))) == .accepted)
        let segment = f.segment(aligned, 0, 0, 1, context: context)
        #expect(await store.admit(f.event(aligned, 1, .committed(segment))) == .accepted)
        let key = SpeakerTrackKey(captureSessionID: f.identity.captureSessionID, source: .system, contextID: context, slot: 0)
        #expect(await store.annotate(owner: f.identity, source: .system, contextID: context, sequence: 0,
            annotations: [], coverage: [.init(source: .system, contextID: context,
                meeting: .init(startNanoseconds: 0, endNanoseconds: 2000000000), status: .resolved)]) == .rejected(.invalidAnnotation))
        #expect(await store.annotate(owner: f.identity, source: .system, contextID: context, sequence: 0,
            annotations: [.init(segmentID: segment.id, assignment: .track(key))], coverage: [.init(source: .system, contextID: context,
                meeting: .init(startNanoseconds: 1000000000, endNanoseconds: 2000000000), status: .resolved)]) == .accepted)
        #expect(await store.snapshot().speakerLegend == [key])
    }

    @Test func retiredPublicationNamespaceCannotBeReopened() async {
        let f = LiveTranscriptFixture(), store = LiveTranscriptStore(identity: f.identity), a = UUID(), b = UUID()
        #expect(await store.close(owner: f.identity) == .accepted)
        func publication(_ id: UUID, _ revision: UInt64, _ text: String) -> TranscriptSourcePublication {
            .init(identity: f.identity, id: id, revision: revision, segments: [.init(id: .init(epochID: id, index: 0),
                source: .finalMix, range: .init(samples: nil, meeting: nil), text: text)])
        }
        #expect(await store.publishFinal(publication(a, 1, "Original")) == .accepted)
        let frozen = await store.snapshot()
        #expect(await store.publishFinal(publication(b, 2, "Replacement")) == .accepted)
        let current = await store.snapshot()
        #expect(await store.publishFinal(publication(a, 3, "Changed")) == .rejected(.conflictingID))
        #expect(await store.snapshot() == current)
        #expect(frozen.segments.first?.text == "Original")
    }

    @Test func finalPublicationCannotInventCaptureCoordinates() async {
        let f = LiveTranscriptFixture(), store = LiveTranscriptStore(identity: f.identity), id = UUID()
        #expect(await store.close(owner: f.identity) == .accepted)
        let fabricated = CommittedLiveSegment(id: .init(epochID: id, index: 0), source: .finalMix,
            range: .init(samples: .init(start: 0, end: 16000), meeting: .init(startNanoseconds: 0, endNanoseconds: 1000000000)), text: "Final")
        #expect(await store.publishFinal(.init(identity: f.identity, id: id, revision: 1, segments: [fabricated])) == .rejected(.invalidRange))
    }
}
