import Foundation
import Testing
@testable import dBrief

@Suite("Meeting insights presentation")
@MainActor
struct MeetingInsightsPresentationTests {
    @Test func processingNotesFollowFinalizationWarnings() {
        let recording = Recording(fileURL: URL(fileURLWithPath: "/synthetic/meeting.m4a"),
                                  finalizationWarnings: ["Mic track missing", "  "])
        recording.processingNotes = [TranscriptSpellingService.SkipReason.noEngine.message]
        let content = MeetingInsightsPresentation(recording: recording, richTranscript: nil, insights: nil)
        #expect(content.warnings == ["Mic track missing", TranscriptSpellingService.SkipReason.noEngine.message])
        #expect(content.plainText().contains("Vocabulary correction skipped"))
    }
}
