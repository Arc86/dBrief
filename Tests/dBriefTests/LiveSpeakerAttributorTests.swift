import Foundation
import Testing
import dBriefWire
@testable import dBrief

private struct AttributionFixture {
    let transcript = LiveTranscriptFixture()
    let context = UUID(), qualification = UUID()
    var identity: LiveSessionIdentity { transcript.identity }
    func range(_ first: Int64, _ last: Int64) -> LiveMeetingRange { .init(startNanoseconds: first * 1_000_000_000, endNanoseconds: last * 1_000_000_000) }
    func evaluator(qualified: Bool = true) throws -> LiveSpeakerAttributor {
        try .init(identity: identity, source: .system, contextID: context,
            policy: .init(acousticQualificationID: qualified ? qualification : nil))
    }
    func segment(words: Int = 1, origin: Int64? = 0) -> (LiveEpoch, CommittedLiveSegment) {
        let epoch = transcript.epoch(.system, origin: origin)
        let value = CommittedLiveSegment(id: .init(epochID: epoch.id, index: 0), source: .system,
            range: transcript.range(epoch, 0, 3), text: "Keep every original word, including untimed text.",
            words: (0..<words).map { .init(text: "word\($0)", samples: nil, confidence: 1.0) }, diarizerContextID: context)
        return (epoch, value)
    }
    func row(_ first: Int64 = 0, _ last: Int64 = 3, _ values: [Double] = [0.9,0.1,0,0,0,0,0,0]) -> LiveSpeakerAttributor.Frame {
        .init(meeting: range(first,last), activity: values)
    }
    func window(_ frames: [LiveSpeakerAttributor.Frame]? = nil, recorded: [LiveMeetingRange]? = nil,
                identity: LiveSessionIdentity? = nil, source: LiveSource = .system, contextID: UUID? = nil) -> LiveSpeakerAttributor.Window {
        .init(identity: identity ?? self.identity, source: source, contextID: contextID ?? context,
            recorded: recorded ?? [range(0,3)], frames: frames ?? [row()])
    }
    func acoustic(_ word: Int = 0, _ first: Int64 = 0, _ last: Int64 = 3, id: UUID? = nil) -> LiveSpeakerAttributor.Timing {
        .acoustic(wordIndex: word, meeting: range(first,last), qualificationID: id ?? qualification)
    }
    func key(_ slot: Int) -> SpeakerTrackKey { .init(captureSessionID: identity.captureSessionID, source: .system, contextID: context, slot: slot) }
    func store(_ epoch: LiveEpoch, _ segment: CommittedLiveSegment) async throws -> LiveTranscriptStore {
        let store = LiveTranscriptStore(identity: identity)
        try #require(await store.beginEpoch(owner: identity, epoch: epoch) == .accepted)
        try #require(await store.registerDiarizer(owner: identity, source: .system, contextID: context) == .accepted)
        try #require(await store.admit(transcript.event(epoch,0,transcript.progress(3))) == .accepted)
        try #require(await store.admit(transcript.event(epoch,1,.committed(segment))) == .accepted)
        return store
    }
}

@MainActor @Suite struct LiveSpeakerAttributorTests {
    @Test func completeQualifiedAcousticActivityAssignsOneScopedTrack() throws {
        let f = AttributionFixture(), (_,segment) = f.segment(), evaluator = try f.evaluator()
        let batch = try evaluator.evaluate(segment,timings: [f.acoustic()],window: f.window())
        #expect(batch.identity == f.identity && batch.source == .system && batch.contextID == f.context)
        #expect(batch.annotations == [.init(segmentID: segment.id,wordIndex: 0,assignment: .track(f.key(0)))])
        #expect(batch.coverage == [.init(source: .system,contextID: f.context,meeting: f.range(0,3),status: .resolved)])
    }

    @Test func emissionSyntheticConfidenceMissingAndUnqualifiedTimingStayUnknown() throws {
        let f = AttributionFixture(), (_,segment) = f.segment()
        for timings in [[LiveSpeakerAttributor.Timing](), [.emission(wordIndex: 0)], [f.acoustic(id: UUID())]] {
            let batch = try f.evaluator().evaluate(segment,timings: timings,window: f.window())
            #expect(batch.annotations.first?.assignment == .unknown && batch.coverage.first?.status == .unknown)
        }
        let disabled = try f.evaluator(qualified: false).evaluate(segment,timings: [f.acoustic()],window: f.window())
        #expect(disabled.annotations.first?.assignment == .unknown && segment.words.first?.confidence == 1.0)
    }

    @Test func simultaneousActivityRetainsOverlapInsteadOfNormalizingAWinningSlot() throws {
        let f = AttributionFixture(), (_,segment) = f.segment()
        let batch = try f.evaluator().evaluate(segment,timings: [f.acoustic()],window: f.window([f.row(0,3,[0.95,0.9,0,0,0,0,0,0])]))
        #expect(batch.annotations.first?.assignment == .overlap([f.key(0),f.key(1)]))
        #expect(batch.coverage.first?.status == .overlap)
    }

    @Test func sequentialTurnsLowActivityAndInsufficientSeparationRemainUnknown() throws {
        let f = AttributionFixture(), (_,segment) = f.segment()
        let windows = [f.window([f.row(0,1),f.row(1,3,[0.1,0.9,0,0,0,0,0,0])]),
            f.window([f.row(0,3,[0.55,0.49,0,0,0,0,0,0])]), f.window([f.row(0,3,[0.1,0.1,0,0,0,0,0,0])])]
        for window in windows {
            let batch = try f.evaluator().evaluate(segment,timings: [f.acoustic()],window: window)
            #expect(batch.annotations.first?.assignment == .unknown && batch.coverage.first?.status == .unknown)
        }
    }

    @Test func missingRowsAndPauseMappingNeverBridgeUnobservedAudio() throws {
        let f = AttributionFixture(), (_,segment) = f.segment()
        for window in [f.window([f.row(0,1),f.row(2,3)]), f.window(recorded: [f.range(0,1),f.range(2,3)]), f.window([])] {
            let batch = try f.evaluator().evaluate(segment,timings: [f.acoustic()],window: window)
            #expect(batch.annotations.first?.assignment == .unknown)
            #expect(batch.coverage == [.init(source: .system,contextID: f.context,meeting: f.range(0,3),status: .unavailable)])
        }
    }

    @Test func nativePaddingIsClippedToRecordedAudioBeforeQualification() throws {
        let f = AttributionFixture(), (_,segment) = f.segment()
        let good = try f.evaluator().evaluate(segment,timings: [f.acoustic()],window: f.window([f.row(0,4)]))
        #expect(good.annotations.first?.assignment == .track(f.key(0)))
        let padded = try f.evaluator().evaluate(segment,timings: [f.acoustic()],window: f.window([f.row(0,4)],recorded: [f.range(0,2)]))
        #expect(padded.annotations.first?.assignment == .unknown && padded.coverage.first?.status == .unavailable)
    }

    @Test func sparseQualifiedWordsPartitionCoverageWithoutRebuildingOriginalText() async throws {
        let f = AttributionFixture(), (epoch,segment) = f.segment(words: 3), store = try await f.store(epoch,segment)
        let before = await store.snapshot()
        let batch = try f.evaluator().evaluate(segment,timings: [f.acoustic(0,0,1),.emission(wordIndex: 1)],window: f.window())
        #expect(batch.annotations.map(\.wordIndex) == [0,1,2])
        #expect(batch.annotations.map(\.assignment) == [.track(f.key(0)),.unknown,.unknown])
        #expect(batch.coverage == [.init(source: .system,contextID: f.context,meeting: f.range(0,1),status: .resolved),
            .init(source: .system,contextID: f.context,meeting: f.range(1,3),status: .unknown)])
        #expect(await store.annotate(owner: batch.identity,source: batch.source,contextID: batch.contextID,sequence: 0,
            annotations: batch.annotations,coverage: batch.coverage) == .accepted)
        let after = await store.snapshot()
        #expect(after.segments == before.segments && after.segments.first?.text == segment.text)
        #expect(after.annotations == batch.annotations && after.attributionCoverage == batch.coverage)
        #expect(before.annotations.isEmpty && before.speakerLegend.isEmpty)
    }

    @Test func foreignOwnerSourceAndContextRejectBeforeAnyAnnotationEffect() async throws {
        let f = AttributionFixture(), (epoch,segment) = f.segment(), store = try await f.store(epoch,segment), before = await store.snapshot()
        for window in [f.window(identity: .init(recordingID: UUID(),captureSessionID: f.identity.captureSessionID)),
            f.window(source: .microphone), f.window(contextID: UUID())] {
            #expect(throws: (any Error).self) { try f.evaluator().evaluate(segment,timings: [f.acoustic()],window: window) }
        }
        #expect(throws: (any Error).self) {
            try LiveSpeakerAttributor(identity: f.identity,source: .finalMix,contextID: f.context,policy: .init())
        }
        #expect(await store.snapshot() == before)
    }

    @Test func malformedActivityAndRecordedInventoriesAreRejectedRatherThanTruncated() throws {
        let f = AttributionFixture(), (_,segment) = f.segment(), evaluator = try f.evaluator()
        let rows = [[Double](repeating: 0.9,count: 7), [Double](repeating: 0.9,count: 9),
            [.nan,0,0,0,0,0,0,0], [.infinity,0,0,0,0,0,0,0], [-0.1,0,0,0,0,0,0,0], [1.1,0,0,0,0,0,0,0]]
        for values in rows {
            #expect(throws: (any Error).self) { try evaluator.evaluate(segment,timings: [f.acoustic()],window: f.window([f.row(0,3,values)])) }
        }
        for window in [f.window([f.row(2,3),f.row(0,1)]), f.window([f.row(0,2),f.row(1,3)]),
            f.window(recorded: [f.range(2,3),f.range(0,1)]), f.window(recorded: [f.range(0,2),f.range(1,3)]),
            f.window([.init(meeting: .init(startNanoseconds: -1,endNanoseconds: 1),activity: rows[0])])] {
            #expect(throws: (any Error).self) { try evaluator.evaluate(segment,timings: [f.acoustic()],window: window) }
        }
    }

    @Test func invalidDuplicateOutOfOrderAndOverlappingAcousticWordsReject() throws {
        let f = AttributionFixture(), (_,segment) = f.segment(words: 2), evaluator = try f.evaluator()
        for timings in [[f.acoustic(-1)], [f.acoustic(2)], [f.acoustic(),f.acoustic()],
            [f.acoustic(1,0,1),f.acoustic(0,1,2)], [f.acoustic(0,0,2),f.acoustic(1,1,3)], [f.acoustic(0,0,4)]] {
            #expect(throws: (any Error).self) { try evaluator.evaluate(segment,timings: timings,window: f.window()) }
        }
    }

    @Test func explicitPolicyThresholdAndMarginMustBeFiniteAndConservative() throws {
        for threshold in [0.0,-0.1,1.1,Double.nan,Double.infinity] {
            #expect(throws: (any Error).self) { try LiveSpeakerAttributor.Policy(activityThreshold: threshold) }
        }
        for margin in [0.0,-0.1,1.1,Double.nan,Double.infinity] {
            #expect(throws: (any Error).self) { try LiveSpeakerAttributor.Policy(separationMargin: margin) }
        }
    }

    @Test func frameWordRangeAndExtentCapacityAreCheckedBeforeEvaluation() throws {
        let f = AttributionFixture(), (_,segment) = f.segment(), evaluator = try f.evaluator()
        #expect(throws: (any Error).self) { try evaluator.evaluate(segment,timings: [],window: f.window(Array(repeating: f.row(),count: LiveSpeakerAttributor.maximumFrames+1))) }
        #expect(throws: (any Error).self) { try evaluator.evaluate(f.segment(words: LiveSpeakerAttributor.maximumWords+1).1,timings: [],window: f.window()) }
        #expect(throws: (any Error).self) { try evaluator.evaluate(segment,timings: [],window: f.window(recorded: Array(repeating: f.range(0,1),count: LiveSpeakerAttributor.maximumRecordedRanges+1))) }
        #expect(throws: (any Error).self) { try evaluator.evaluate(segment,timings: [],window: f.window([f.row(0,31)])) }
    }

    @Test func exactMaximumRowsAndWordsFitAndCoverageRemainsDisjointWithinItsDeclaredBound() throws {
        let f = AttributionFixture(), (_,segment) = f.segment(words: LiveSpeakerAttributor.maximumWords)
        let frames = (0..<LiveSpeakerAttributor.maximumFrames).map { index in
            LiveSpeakerAttributor.Frame(meeting: .init(startNanoseconds: Int64(index)*10_000_000,
                endNanoseconds: Int64(index+1)*10_000_000),activity: [0.9,0.1,0,0,0,0,0,0])
        }
        let timings = segment.words.indices.map { word in
            LiveSpeakerAttributor.Timing.acoustic(wordIndex: word,
                meeting: .init(startNanoseconds: Int64(word*2+1),endNanoseconds: Int64(word*2+2)),qualificationID: f.qualification)
        }
        let batch = try f.evaluator().evaluate(segment,timings: timings,window: f.window(frames))
        #expect(batch.annotations.count == 512 && batch.annotations.allSatisfy { $0.assignment == .track(f.key(0)) })
        #expect(batch.coverage.count == 1_025 && batch.coverage.first?.meeting?.startNanoseconds == 0)
        #expect(batch.coverage.last?.meeting?.endNanoseconds == 3_000_000_000)
        for (left,right) in zip(batch.coverage,batch.coverage.dropFirst()) {
            #expect(left.meeting?.endNanoseconds == right.meeting?.startNanoseconds && left.status != right.status)
        }
    }

    @Test func wordlessAndUnqualifiedChronologyRetainUnknownOriginalEvidence() throws {
        let f = AttributionFixture(), (_,wordless) = f.segment(words: 0), (_,unaligned) = f.segment(origin: nil)
        let whole = try f.evaluator().evaluate(wordless,timings: [],window: f.window())
        #expect(whole.annotations == [.init(segmentID: wordless.id,assignment: .unknown)])
        let unknown = try f.evaluator().evaluate(unaligned,timings: [.emission(wordIndex: 0)],window: f.window())
        #expect(unknown.coverage == [.init(source: .system,contextID: f.context,meeting: nil,status: .unknown)])
    }

    @Test func sameContextOldASREpochUpdatesButReplacementRejectsOldTracks() async throws {
        let f = AttributionFixture(), (epoch,segment) = f.segment(), store = try await f.store(epoch,segment)
        let next = f.transcript.epoch(.system,origin: 3_000_000_000)
        #expect(await store.beginEpoch(owner: f.identity,epoch: next) == .accepted)
        let batch = try f.evaluator().evaluate(segment,timings: [f.acoustic()],window: f.window())
        #expect(await store.annotate(owner: f.identity,source: .system,contextID: f.context,sequence: 0,annotations: batch.annotations,coverage: batch.coverage) == .accepted)
        let frozen = await store.snapshot()
        #expect(frozen.speakerLegend == [f.key(0)])
        #expect(await store.registerDiarizer(owner: f.identity,source: .system,contextID: UUID()) == .accepted)
        #expect(await store.annotate(owner: f.identity,source: .system,contextID: f.context,sequence: 1,annotations: batch.annotations) == .rejected(.invalidAnnotation))
        #expect(frozen.annotations == batch.annotations && frozen.segments == [segment])
    }

    @Test func heldOwnedWriterColdRecoveryPreservesTextIDsCoverageAndFrozenLegend() async throws {
        let files = try LiveArtifactFixture(); defer { files.remove() }
        let f = AttributionFixture(), gate = LiveArtifactGate(stage: .sourceTranscript)
        let registry = LiveRecordingSessionRegistry(artifactRoot: files.root,beforeStage: { try await gate.enter($0) })
        let entry = try registry.register(f.identity), (epoch,segment) = f.segment(words: 2)
        do {
            try #require(await entry.store.beginEpoch(owner: f.identity,epoch: epoch) == .accepted)
            try #require(await entry.store.registerDiarizer(owner: f.identity,source: .system,contextID: f.context) == .accepted)
            try #require(await entry.store.admit(f.transcript.event(epoch,0,f.transcript.progress(3))) == .accepted)
            try #require(await entry.store.admit(f.transcript.event(epoch,1,.committed(segment))) == .accepted)
            _ = try await entry.artifacts.loadChat()
            registry.startPersistence(f.identity); try await gate.waitForArrival()
            let first = try f.evaluator().evaluate(segment,timings: [f.acoustic(0,0,1)],window: f.window())
            try #require(await entry.store.annotate(owner: f.identity,source: .system,contextID: f.context,sequence: 0,annotations: first.annotations,coverage: first.coverage) == .accepted)
            let frozen = await entry.store.snapshot(), answerID = UUID()
            let route = ChatRouteBasis(engine: "remoteEndpoint",endpointID: nil,provider: "fixture",origin: nil,model: "fixture")
            let budget = ChatContextBudget(contextTokens: 8_192,outputTokens: 512,templateReserve: 256)
            let prepared = try TranscriptContextBuilder.build(snapshot: .live(frozen),route: route,budget: budget,
                language: .english,question: "What did the anonymous speaker say?",history: [],answerID: answerID)
            let answer = ChatMessage(id: answerID,role: .assistant,content: "Original frozen answer",basis: prepared.basis,outcome: .completed)
            try entry.artifacts.saveChat(.init(messages: [answer]),urgent: true)
            let second = try f.evaluator().evaluate(segment,timings: [f.acoustic(0,0,1)],window: f.window([f.row(0,3,[0.9,0.85,0,0,0,0,0,0])]))
            try #require(await entry.store.annotate(owner: f.identity,source: .system,contextID: f.context,sequence: 1,annotations: second.annotations,coverage: second.coverage) == .accepted)
            let changed = await entry.store.snapshot()
            let newer = try TranscriptContextBuilder.build(snapshot: .live(changed),route: route,budget: budget,
                language: .english,question: "What did the anonymous speaker say?",history: [],answerID: UUID())
            #expect(newer.basis.source.annotationRevision != prepared.basis.source.annotationRevision)
            #expect(newer.basis.source.speakerLegend.count == 2 && prepared.basis.source.speakerLegend.count == 1)
            #expect(await entry.store.close(owner: f.identity) == .accepted); try registry.captureDidClose(f.identity)
            var returned = false
            let drain = Task { try await entry.artifacts.flush(); returned = true }
            for _ in 0..<20 { await Task.yield() }
            #expect(!returned && !entry.artifacts.isDurable)
            await gate.release(); try await drain.value
            let restored = try await LiveSessionArtifactStore(identity: f.identity,rootURL: files.root).recover()
            let saved = try #require(restored.appTranscript)
            #expect(restored.chat?.messages == [answer] && restored.chat?.messages.first?.basis == prepared.basis)
            #expect(saved.captureClosed && saved.native?.segments == [segment])
            #expect(saved.native?.annotations == second.annotations && saved.native?.attributionCoverage == second.coverage)
            #expect(frozen.speakerLegend == [f.key(0)] && frozen.annotations == first.annotations)
        } catch { await gate.release(); try? registry.retire(f.identity); await entry.artifacts.waitForSubmittedWrites(); throw error }
    }
}
