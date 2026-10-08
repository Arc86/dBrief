import Testing
import dBriefWire
@testable import dBrief

@MainActor
@Suite struct TranscriptChatLongModeTests {
    private let notes = [ChunkNotes(keyPoints: ["Kestrel contract goes to legal"], decisions: ["Halcyon moves to March 14"],
                                    actionItems: ["Marisol: send contract by Thursday"], people: ["Marisol"])]

    private func insights(notes: [ChunkNotes]?, stale: Bool?) -> RecordingInsights {
        var i = RecordingInsights(summary: "The team reviewed vendor contracts.", actionItems: ["Priya: share Brightwater"],
                                  tags: [], sentiment: "Neutral", markdownPath: nil, partNotes: notes)
        i.basedOnPreviousTranscript = stale
        return i
    }

    @Test func overviewUsesSidecarPartNotesForTheCurrentTranscript() {
        let text = TranscriptChatService.overview(insights: insights(notes: notes, stale: nil), profile: .gemma)
        #expect(text.hasPrefix("MEETING NOTES"))
        #expect(text.contains("Halcyon moves to March 14"))
    }

    @Test func staleNotesFallBackToTheSummary() {
        let text = TranscriptChatService.overview(insights: insights(notes: notes, stale: true), profile: .gemma)
        #expect(text.hasPrefix("MEETING SUMMARY:\nThe team reviewed vendor contracts."))
        #expect(text.contains("- Priya: share Brightwater"))
        #expect(!text.contains("Halcyon"))
    }

    @Test func missingNotesFallBackToTheSummary() {
        let text = TranscriptChatService.overview(insights: insights(notes: nil, stale: false), profile: .gemma)
        #expect(text.hasPrefix("MEETING SUMMARY:"))
    }

    @Test func noInsightsMeansNoOverview() {
        #expect(TranscriptChatService.overview(insights: nil, profile: .gemma).isEmpty)
    }

    @Test func shortTranscriptsStayInFullMode() {
        let mode = TranscriptChatService.chatMode(transcriptTokens: 1_000, profile: .gemma, hasOverview: true, canRetrieve: true)
        #expect(mode == .fullTranscript)
    }

    @Test func longTranscriptsUseOverviewAndRetrieval() {
        let tokens = ChatEngineProfile.gemma.fullTranscriptTokens + 1
        #expect(TranscriptChatService.chatMode(transcriptTokens: tokens, profile: .gemma, hasOverview: true,
                                               canRetrieve: true) == .overviewAndRetrieval)
        #expect(TranscriptChatService.chatMode(transcriptTokens: tokens, profile: .gemma, hasOverview: false,
                                               canRetrieve: true) == .retrievalOnly)
    }

    @Test func withoutTurnsALongTranscriptKeepsFullMode() {
        // Live chat (or a recording without segments) has no retrieval windows.
        let tokens = ChatEngineProfile.gemma.fullTranscriptTokens * 4
        #expect(TranscriptChatService.chatMode(transcriptTokens: tokens, profile: .gemma, hasOverview: true,
                                               canRetrieve: false) == .fullTranscript)
    }
}
