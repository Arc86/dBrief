import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Transcript chat original references")
struct TranscriptChatReferenceTests {
    @Test func meetingTimeCannotBecomeAMasterAudioOffset() throws {
        let owner = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID()), pub = UUID()
        let slice = LiveSavedAudioSlice(samples: nil, destination: .track(.microphone),
            startFrame: 480_000, frameCount: 48_000, sampleRate: 48_000, mappingRevision: 4)
        let segment = CommittedLiveSegment(id: .init(epochID: pub, index: 0), source: .microphone,
            range: .init(samples: nil, meeting: .init(startNanoseconds: 100_000_000_000, endNanoseconds: 101_000_000_000),
                         savedAudio: [slice]), text: "Preserved live words")
        let snapshot = TranscriptSnapshot(identity: owner, sourceVersion: .live, sourcePublicationID: pub,
            sourcePublicationRevision: 0, revision: 1, annotationRevision: 0, cutoffNanoseconds: 101_000_000_000,
            scope: .liveThroughCutoff, segments: [segment], lanes: [], excludedSources: [], coverage: [],
            annotations: [], attributionCoverage: [], speakerLegend: [])
        let prepared = try TranscriptContextBuilder.build(snapshot: .live(snapshot),
            route: .init(engine: "fixture", endpointID: nil, provider: nil, origin: nil, model: nil),
            budget: .init(contextTokens: 8_192, outputTokens: 512, templateReserve: 256),
            language: .matchInput, question: "What?", history: [], answerID: UUID())
        let ref = try #require(prepared.basis.evidence.first)
        let exact = ChatPlaybackBinding(recordingID: owner.recordingID, captureSessionID: owner.captureSessionID,
            mappingRevision: 4, mapping: .rawTrackCopy(.mic))
        #expect(ChatReferencePlayback.seekSeconds(reference: ref, basis: prepared.basis, binding: exact) == 10)
        let unbound = ChatPlaybackBinding(recordingID: owner.recordingID, captureSessionID: nil, mappingRevision: nil, mapping: .rawTrackCopy(.mic))
        #expect(ChatReferencePlayback.seekSeconds(reference: ref, basis: prepared.basis, binding: unbound) == nil)
        let other = ChatPlaybackBinding(recordingID: UUID(), captureSessionID: owner.captureSessionID, mappingRevision: 4, mapping: .rawTrackCopy(.mic))
        #expect(ChatReferencePlayback.seekSeconds(reference: ref, basis: prepared.basis, binding: other) == nil)
        let differentTrack = ChatPlaybackBinding(recordingID: owner.recordingID, captureSessionID: owner.captureSessionID,
            mappingRevision: 4, mapping: .rawTrackCopy(.system))
        #expect(ChatReferencePlayback.seekSeconds(reference: ref, basis: prepared.basis, binding: differentTrack) == nil)
        #expect(ref.meeting?.startNanoseconds == 100_000_000_000 && ref.text == "Preserved live words")
        let decoded = try JSONDecoder().decode(ChatAnswerBasis.self, from: JSONEncoder().encode(prepared.basis))
        #expect(decoded == prepared.basis)
    }

    @Test @MainActor func registrySelectionIsRecordingScopedAndRetirementInvalidatesCapturedOwner() async throws {
        let registry = LiveRecordingSessionRegistry(), wanted = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
        let entry = try registry.register(wanted)
        let provider = TranscriptContextProvider.recording(recordingID: wanted.recordingID, registry: registry,
            legacy: { .legacy(text: "Wrong fallback", recordingID: UUID(), speakerLabels: []) })
        let captured = provider.freeze()
        try registry.retire(entry.identity)
        await #expect(throws: CancellationError.self) { try await captured.snapshot() }
        await #expect(throws: CancellationError.self) { try await provider.freeze().snapshot() }
        let other = TranscriptContextProvider.recording(recordingID: UUID(), registry: registry,
            legacy: { .legacy(text: "", recordingID: nil, speakerLabels: []) })
        #expect(try await other.freeze().snapshot().segments.isEmpty)
        let wrong = TranscriptContextProvider.recording(recordingID: UUID(), registry: registry,
            legacy: { .legacy(text: "Unrelated meeting", recordingID: UUID(), speakerLabels: []) })
        await #expect(throws: TranscriptContextError.recordingMismatch) { try await wrong.freeze().snapshot() }
    }
}
