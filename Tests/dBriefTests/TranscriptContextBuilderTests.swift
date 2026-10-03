import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Transcript chat immutable context")
struct TranscriptContextBuilderTests {
    private let route = ChatRouteBasis(engine: "remoteEndpoint", endpointID: nil, provider: "fixture", origin: nil, model: "fixture")
    private let budget = ChatContextBudget(contextTokens: 8_192, outputTokens: 512, templateReserve: 256)

    @Test func completeEligibleContextAndConversationHaveDifferentAuthority() throws {
        let snapshot = TranscriptContextSnapshot.legacy(text: "Ship on Friday.", recordingID: UUID(), speakerLabels: [])
        let complete = ChatMessage(role: .assistant, content: "Earlier conversation", outcome: .completed)
        let partial = ChatMessage(role: .assistant, content: "Invented partial identity", outcome: .interrupted)
        let prepared = try TranscriptContextBuilder.build(snapshot: snapshot, route: route, budget: budget,
            language: .english, question: "When do we ship?", history: [complete, partial], answerID: UUID())
        #expect(prepared.basis.evidence.map(\.text) == ["Ship on Friday."])
        #expect(prepared.basis.selection == .allEligible)
        #expect(prepared.userMessage.contains("Earlier conversation"))
        #expect(!prepared.userMessage.contains("Invented partial identity"))
        #expect(!prepared.systemPrompt.contains("complete transcript included in full"))
        #expect(prepared.systemPrompt.contains("quoted evidence"))
        #expect(prepared.basis.budget.totalReserved <= budget.contextTokens)
    }

    @Test func unicodeFragmentsReferenceOnlyTheExactSentText() throws {
        let text = String(repeating: "A café 👩🏽‍💻 proposed shipping. ", count: 300)
        let snapshot = TranscriptContextSnapshot.legacy(text: text, recordingID: UUID(), speakerLabels: [])
        let small = ChatContextBudget(contextTokens: 3_072, outputTokens: 512, templateReserve: 256)
        let prepared = try TranscriptContextBuilder.build(snapshot: snapshot, route: route, budget: small,
            language: .matchInput, question: "Shipping?", history: [], answerID: UUID())
        let evidence = try #require(prepared.basis.evidence.first)
        #expect(prepared.basis.selection == .excerpts && evidence.isFragment)
        #expect(text.hasPrefix(evidence.text) && evidence.text.utf8.count == evidence.endUTF8 - evidence.startUTF8)
        #expect(evidence.text.count < text.count)
        let refs = ChatReferenceParser.resolve("A claim [[ref:\(evidence.id)]] [[ref:invented]]", basis: prepared.basis)
        #expect(refs.references.map(\.text) == [evidence.text])
        #expect(refs.invalidCount == 1 && !refs.references[0].text.contains(text))
        #expect(prepared.basis.budget.totalReserved <= small.contextTokens)
    }

    @Test func selectionIsDeterministicRecentAndLexicallyRelevant() throws {
        let segments = (0..<150).map { index in
            ChatTranscriptSegment(id: "\(index)", source: "legacy", text: index == 20
                ? "The zebra migration was approved." : "Ordinary agenda item \(index). " + String(repeating: "details ", count: 10))
        }
        let snapshot = TranscriptContextSnapshot(source: .legacy(recordingID: UUID()), segments: segments)
        let id = UUID(), small = ChatContextBudget(contextTokens: 4_096, outputTokens: 512, templateReserve: 256)
        let first = try TranscriptContextBuilder.build(snapshot: snapshot, route: route, budget: small,
            language: .matchInput, question: "What about zebra migration?", history: [], answerID: id)
        let second = try TranscriptContextBuilder.build(snapshot: snapshot, route: route, budget: small,
            language: .matchInput, question: "What about zebra migration?", history: [], answerID: id)
        #expect(first == second && first.basis.selection == .excerpts)
        #expect(first.basis.evidence.contains { $0.parentSegmentID == "20" })
        #expect(first.basis.evidence.contains { $0.parentSegmentID == "149" })
        #expect(first.systemPrompt.contains("Selected excerpts") && first.systemPrompt.contains("smaller range"))
    }

    @Test func emptyEvidenceAndOversizedQuestionsDoNotCreateARequest() {
        #expect(throws: TranscriptContextError.waitingForTranscript) {
            try TranscriptContextBuilder.build(snapshot: .legacy(text: "", recordingID: nil, speakerLabels: []),
                route: route, budget: budget, language: .matchInput, question: "Anything?", history: [], answerID: UUID())
        }
        #expect(throws: TranscriptContextError.questionTooLarge) {
            try TranscriptContextBuilder.build(snapshot: .legacy(text: "Evidence", recordingID: nil, speakerLabels: []),
                route: route, budget: budget, language: .matchInput, question: String(repeating: "q", count: 5_000), history: [], answerID: UUID())
        }
    }

    @Test func originalLiveBasisSurvivesFinalPublicationAndLabels() async throws {
        let f = LiveTranscriptFixture(), epoch = f.epoch(), store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        #expect(await store.admit(f.event(epoch, 0, f.progress(1))) == .accepted)
        #expect(await store.admit(f.event(epoch, 1, .committed(f.segment(epoch, 0, 0, 1, "Original live wording")))) == .accepted)
        let frozen = TranscriptContextSnapshot.live(await store.snapshot())
        let prepared = try TranscriptContextBuilder.build(snapshot: frozen, route: route, budget: budget,
            language: .matchInput, question: "What was said?", history: [], answerID: UUID())
        #expect(await store.close(owner: f.identity) == .accepted)
        let closed = try TranscriptContextBuilder.build(snapshot: .live(await store.snapshot()), route: route, budget: budget,
            language: .matchInput, question: "What was said?", history: [], answerID: UUID())
        #expect(!closed.systemPrompt.contains("The meeting is ongoing"))
        let pub = UUID()
        #expect(await store.publishFinal(.init(identity: f.identity, id: pub, revision: 1,
            segments: [.init(id: .init(epochID: pub, index: 0), source: .finalMix,
                range: .init(samples: nil, meeting: nil), text: "Different final wording")])) == .accepted)
        #expect(prepared.basis.source.version == .live)
        #expect(prepared.basis.source.captureSessionID == f.identity.captureSessionID)
        #expect(prepared.basis.source.cutoffNanoseconds == 1_000_000_000)
        #expect(prepared.basis.evidence.first?.text == "Original live wording")
        #expect(TranscriptContextSnapshot.live(await store.snapshot()).source.version == .final)
    }

    @Test func oldMessagesDoNotGainProvenanceOrCompletion() throws {
        let old = ChatMessage(role: .assistant, content: "Old answer")
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(old))
        #expect(decoded.basis == nil && decoded.outcome == nil && decoded.referenceResolution == nil)
    }
}
