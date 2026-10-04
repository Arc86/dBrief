import Foundation
import Testing
import dBriefWire
@testable import dBrief

@MainActor @Suite struct LiveSpeakerPromptTests {
    private let route = ChatRouteBasis(engine: "fixture", endpointID: nil, provider: nil, origin: nil, model: nil)
    private let budget = ChatContextBudget(contextTokens: 8_192, outputTokens: 512, templateReserve: 256)
    private func key(_ f: LiveTranscriptFixture, _ context: UUID, _ slot: Int) -> SpeakerTrackKey {
        .init(captureSessionID: f.identity.captureSessionID, source: .microphone, contextID: context, slot: slot)
    }
    private func trackID(_ key: SpeakerTrackKey) -> String { "\(key.source.rawValue):\(key.contextID.uuidString.lowercased()):\(key.slot)" }
    private func text(_ span: ChatSpeakerAttributionSpan, in reference: ChatEvidenceReference) -> String {
        String(decoding: Array(reference.text.utf8)[span.startUTF8..<span.endUTF8], as: UTF8.self)
    }
    private func setup(_ f: LiveTranscriptFixture, _ context: UUID, _ text: String, _ words: [String]) async throws -> (LiveTranscriptStore, CommittedLiveSegment) {
        let epoch = f.epoch(), store = LiveTranscriptStore(identity: f.identity)
        let segment = CommittedLiveSegment(id: .init(epochID: epoch.id, index: 0), source: .microphone, range: f.range(epoch, 0, 1),
            text: text, words: words.map { .init(text: $0, samples: nil, confidence: 1) }, diarizerContextID: context)
        try #require(await store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        try #require(await store.registerDiarizer(owner: f.identity, source: .microphone, contextID: context) == .accepted)
        try #require(await store.admit(f.event(epoch, 0, f.progress(1))) == .accepted)
        try #require(await store.admit(f.event(epoch, 1, .committed(segment))) == .accepted)
        return (store, segment)
    }
    private func build(_ store: LiveTranscriptStore, budget: ChatContextBudget? = nil) async throws -> PreparedTranscriptChat {
        try TranscriptContextBuilder.build(snapshot: .live(await store.snapshot()), route: route, budget: budget ?? self.budget,
            language: .english, question: "What did each speaker say?", history: [], answerID: UUID())
    }

    @Test func sparseResolvedAndOverlapWordsNeverBecomeAWholeTurnSpeakerUnion() async throws {
        let f = LiveTranscriptFixture(), context = UUID(), (store, segment) = try await setup(f, context, "alpha beta gamma", ["alpha", "beta", "gamma"])
        try #require(await store.annotate(owner: f.identity, source: .microphone, contextID: context, sequence: 0, annotations: [
            .init(segmentID: segment.id, wordIndex: 0, assignment: .track(key(f, context, 0))),
            .init(segmentID: segment.id, wordIndex: 2, assignment: .overlap([key(f, context, 0), key(f, context, 1)]))]) == .accepted)
        let prepared = try await build(store), reference = try #require(prepared.basis.evidence.first), spans = try #require(reference.speakerAttribution)
        #expect(reference.text == segment.text && reference.parentSegmentID == segment.id.description && reference.speakers.isEmpty)
        #expect(spans.filter { $0.status == .resolved }.map { text($0, in: reference) } == ["alpha"])
        #expect(spans.filter { $0.status == .overlap }.map { text($0, in: reference) } == ["gamma"])
        #expect(spans.contains { $0.status == .unknown && text($0, in: reference).contains("beta") && $0.speakers.isEmpty })
        #expect(spans.first?.startUTF8 == 0 && spans.last?.endUTF8 == reference.text.utf8.count)
        for (left, right) in zip(spans, spans.dropFirst()) { #expect(left.endUTF8 == right.startUTF8) }
        #expect(prepared.systemPrompt.contains("concurrent activity") && prepared.systemPrompt.contains("Only resolved speaker spans"))
        #expect(prepared.basis.budget.totalReserved <= budget.contextTokens)
    }

    @Test func sequentialUnicodeAndRepeatedWordsKeepTheirOriginalByteRanges() async throws {
        let f = LiveTranscriptFixture(), context = UUID(), original = " café 👩🏽‍💻 café "
        let (store, segment) = try await setup(f, context, original, ["café", "👩🏽‍💻", "café"])
        try #require(await store.annotate(owner: f.identity, source: .microphone, contextID: context, sequence: 0, annotations: [
            .init(segmentID: segment.id, wordIndex: 0, assignment: .track(key(f, context, 0))),
            .init(segmentID: segment.id, wordIndex: 2, assignment: .track(key(f, context, 1)))]) == .accepted)
        let reference = try #require(try await build(store).basis.evidence.first), spans = try #require(reference.speakerAttribution)
        let resolved = spans.filter { $0.status == .resolved }
        #expect(resolved.map { text($0, in: reference) } == ["café", "café"])
        #expect(resolved.map(\.startUTF8) == [1, " café 👩🏽‍💻 ".utf8.count])
        #expect(resolved.map(\.speakers) == [[trackID(key(f, context, 0))], [trackID(key(f, context, 1))]])
        #expect(spans.contains { $0.status == .unknown && text($0, in: reference).contains("👩🏽‍💻") })
        #expect(reference.text == original && reference.speakers.isEmpty && !spans.contains { $0.status == .overlap })
    }

    @Test(arguments: [("prefix alpha", ["alpha"]), ("alpha, beta", ["alpha", "beta"]), ("café", ["cafe\u{301}"]), ("alpha", Array(repeating: "alpha", count: 513))])
    func mismatchOrWordCapacityKeepsTheWholeOriginalTextUnattributed(input: (String, [String])) async throws {
        let f = LiveTranscriptFixture(), context = UUID(), (store, segment) = try await setup(f, context, input.0, input.1)
        try #require(await store.annotate(owner: f.identity, source: .microphone, contextID: context, sequence: 0,
            annotations: [.init(segmentID: segment.id, wordIndex: 0, assignment: .track(key(f, context, 0)))]) == .accepted)
        let reference = try #require(try await build(store).basis.evidence.first), spans = try #require(reference.speakerAttribution)
        #expect(reference.text == input.0 && reference.speakers.isEmpty)
        #expect(spans.count == 1 && spans[0].startUTF8 == 0 && spans[0].endUTF8 == reference.text.utf8.count)
        #expect(spans[0].speakers.isEmpty && (spans[0].status == .unknown || spans[0].status == .unavailable))
    }

    @Test func aPrefixCutInsideAResolvedWordCannotInheritItsSpeaker() async throws {
        let f = LiveTranscriptFixture(), context = UUID(), original = String(repeating: "x", count: 4_096)
        let (store, segment) = try await setup(f, context, original, [original])
        try #require(await store.annotate(owner: f.identity, source: .microphone, contextID: context, sequence: 0,
            annotations: [.init(segmentID: segment.id, wordIndex: 0, assignment: .track(key(f, context, 0)))]) == .accepted)
        let small = ChatContextBudget(contextTokens: 3_072, outputTokens: 512, templateReserve: 256)
        let prepared = try await build(store, budget: small), reference = try #require(prepared.basis.evidence.first), spans = try #require(reference.speakerAttribution)
        #expect(reference.isFragment && original.hasPrefix(reference.text) && reference.text.utf8.count < original.utf8.count)
        #expect(reference.speakers.isEmpty && spans.allSatisfy { $0.status == .unknown && $0.speakers.isEmpty })
        #expect(spans.last?.endUTF8 == reference.endUTF8 && prepared.basis.budget.totalReserved <= small.contextTokens)
    }

    @Test func directDenseOverlapCorpusHitsAnAggregateMetadataBoundBeforeSelection() throws {
        let context = UUID(), speakers = (0..<8).map { "system:\(context.uuidString.lowercased()):\($0)" }, original = String(repeating: "x", count: 128)
        let spans = (0..<128).map { index in
            ChatSpeakerAttributionSpan(startUTF8: index, endUTF8: index + 1, status: .overlap, speakers: Array(speakers.prefix(index.isMultiple(of: 2) ? 8 : 7)))
        }
        let source = ChatTranscriptSource.legacy(recordingID: UUID(), live: true, speakerLabels: speakers.map { .init(id: $0, displayName: $0) })
        let segments = (0..<2_000).map { ChatTranscriptSegment(id: "\($0)", source: "system", text: original, speakerAttribution: spans) }
        let prepared = try TranscriptContextBuilder.build(snapshot: .init(source: source, segments: segments), route: route, budget: budget,
            language: .english, question: "What is established?", history: [], answerID: UUID())
        #expect(prepared.basis.scanLimited && prepared.basis.scannedSegmentCount < segments.count)
        #expect(prepared.basis.budget.totalReserved <= budget.contextTokens)
        #expect(prepared.systemPrompt.contains("Search/scan was bounded"))
    }

    @Test func malformedDirectSpansCannotClaimResolvedOrOverlapText() throws {
        let bad: [[ChatSpeakerAttributionSpan]] = [
            [.init(startUTF8: -1, endUTF8: 4, status: .resolved, speakers: ["speaker"])],
            [.init(startUTF8: 0, endUTF8: 4, status: .resolved, speakers: ["a", "b"])],
            [.init(startUTF8: 0, endUTF8: 4, status: .overlap, speakers: ["a"])],
            [.init(startUTF8: 0, endUTF8: 3, status: .resolved, speakers: ["a"]), .init(startUTF8: 2, endUTF8: 4, status: .resolved, speakers: ["b"])],
            [.init(startUTF8: 0, endUTF8: 4, status: .unknown, speakers: ["a"])]]
        for spans in bad {
            let source = ChatTranscriptSource.legacy(recordingID: UUID(), live: true)
            let prepared = try TranscriptContextBuilder.build(snapshot: .init(source: source, segments: [.init(id: "original", source: "system", text: "word", speakerAttribution: spans)]),
                route: route, budget: budget, language: .english, question: "Who?", history: [], answerID: UUID())
            let reference = try #require(prepared.basis.evidence.first), projection = try #require(reference.speakerAttribution)
            #expect(reference.text == "word" && reference.speakers.isEmpty && projection.allSatisfy { $0.speakers.isEmpty && $0.status != .resolved && $0.status != .overlap })
        }
    }

    @Test func olderBasisDecodesWithoutInventedSpansAndCompletedRichLabelsStayCompatible() throws {
        let transcript = RichTranscript(segments: [.init(start: 0, end: 1, text: "Confirmed final", originalText: "Confirmed final", speakerId: "confirmed")],
            speakerLabels: [.init(id: "confirmed", displayName: "Confirmed speaker")])
        let prepared = try TranscriptContextBuilder.build(snapshot: .completed(transcript, recordingID: UUID()), route: route, budget: budget,
            language: .english, question: "Who?", history: [], answerID: UUID())
        #expect(prepared.basis.evidence.first?.speakers == ["confirmed"] && prepared.basis.evidence.first?.speakerAttribution == nil)
        let bytes = try JSONEncoder().encode(prepared.basis), object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect((object["evidence"] as? [[String: Any]])?.first?["speakerAttribution"] == nil)
        #expect(try JSONDecoder().decode(ChatAnswerBasis.self, from: bytes) == prepared.basis)
    }

    @Test func wordlessAndMissingAnnotationsStayExplicitlyUnknownWithoutChangingText() async throws {
        let f = LiveTranscriptFixture(), context = UUID(), (store, segment) = try await setup(f, context, "No aligned words", [])
        let before = try await build(store)
        #expect(before.basis.evidence.first?.speakers.isEmpty == true)
        try #require(await store.annotate(owner: f.identity, source: .microphone, contextID: context, sequence: 0,
            annotations: [.init(segmentID: segment.id, assignment: .unknown)]) == .accepted)
        let after = try await build(store), reference = try #require(after.basis.evidence.first), spans = try #require(reference.speakerAttribution)
        #expect(reference.text == segment.text && spans.count == 1 && spans[0].status == .unknown && spans[0].speakers.isEmpty)
    }

    @Test func heldOwnedChatColdRecoveryPreservesTheOriginalWordLevelBasisAfterCorrection() async throws {
        let files = try LiveArtifactFixture(); defer { files.remove() }
        let gate = LiveArtifactGate(stage: .sourceTranscript), registry = LiveRecordingSessionRegistry(artifactRoot: files.root, beforeStage: { try await gate.enter($0) })
        let entry = try registry.register(files.identity), context = UUID()
        let epoch = LiveEpoch(id: UUID(), source: .system, engineRevision: "fixture", language: "auto", meetingOriginNanoseconds: 0)
        let segment = CommittedLiveSegment(id: .init(epochID: epoch.id, index: 0), source: .system,
            range: .init(samples: .init(start: 0, end: 16_000), meeting: .init(startNanoseconds: 0, endNanoseconds: 1_000_000_000)),
            text: "alpha beta", words: [.init(text: "alpha", samples: nil), .init(text: "beta", samples: nil)], diarizerContextID: context)
        let track = SpeakerTrackKey(captureSessionID: files.identity.captureSessionID, source: .system, contextID: context, slot: 0)
        try #require(await entry.store.beginEpoch(owner: files.identity, epoch: epoch) == .accepted)
        try #require(await entry.store.registerDiarizer(owner: files.identity, source: .system, contextID: context) == .accepted)
        try #require(await entry.store.admit(.init(identity: files.identity, epochID: epoch.id, source: .system, sequence: 0,
            payload: .progress(.init(capturedSampleEnd: 16_000, admittedSampleEnd: 16_000, consumedSampleEnd: 16_000)))) == .accepted)
        try #require(await entry.store.admit(.init(identity: files.identity, epochID: epoch.id, source: .system, sequence: 1, payload: .committed(segment))) == .accepted)
        try #require(await entry.store.annotate(owner: files.identity, source: .system, contextID: context, sequence: 0,
            annotations: [.init(segmentID: segment.id, wordIndex: 0, assignment: .track(track))]) == .accepted)
        let prepared = try await build(entry.store), reference = try #require(prepared.basis.evidence.first)
        try #require(reference.speakerAttribution?.contains { $0.status == .resolved } == true)
        _ = try await entry.artifacts.loadChat()
        registry.startPersistence(files.identity)
        do {
            try await gate.waitForArrival()
            let answer = ChatMessage(role: .assistant, content: "Frozen word-level answer", basis: prepared.basis, outcome: .completed)
            try entry.artifacts.saveChat(.init(messages: [answer]), urgent: true)
            try #require(await entry.store.annotate(owner: files.identity, source: .system, contextID: context, sequence: 1,
                annotations: [.init(segmentID: segment.id, wordIndex: 0, assignment: .unknown)]) == .accepted)
            #expect(try await build(entry.store).basis.evidence.first?.speakerAttribution != reference.speakerAttribution)
            try #require(await entry.store.close(owner: files.identity) == .accepted)
            try registry.captureDidClose(files.identity)
            await gate.release(); try await entry.artifacts.flush()
            let restored = try await LiveSessionArtifactStore(identity: files.identity, rootURL: files.root).recover()
            #expect(restored.chat?.messages == [answer] && restored.chat?.messages.first?.basis?.evidence.first?.speakerAttribution == reference.speakerAttribution)
            #expect(restored.appTranscript?.native?.annotations.first?.assignment == .unknown && reference.speakerAttribution?.contains { $0.status == .resolved } == true)
        } catch {
            await gate.release(); try? registry.retire(files.identity); await entry.artifacts.waitForSubmittedWrites(); throw error
        }
    }
}
