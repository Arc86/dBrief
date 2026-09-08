import Foundation
import Testing
@testable import dBrief

@Suite("Consistent recording list presentation")
struct RecordingListPresentationTests {
    @Test func recordingAndQueueUseReadableCaptureTitles() {
        #expect(RecordingListPresentation.title(filenameStem: "2026-09-08_1148_Team-handover") == "Team handover")
    }

    @Test func generatedTitlesTakePrecedenceWithoutChangingTheirPunctuation() {
        #expect(RecordingListPresentation.title(filenameStem: "2026-09-08_1148_meeting", generatedTitle: " \nTeam — next steps\n ") == "Team — next steps")
        #expect(RecordingListPresentation.title(filenameStem: "2026-09-08_1148_Team-handover", generatedTitle: "\n ") == "Team handover")
    }

    @Test(arguments: ["client_project_handover", "meeting-name", "2026-09-08_notes_Team", "録音_プロジェクト_打合せ"])
    func importedFilenamesAreNotStripped(name: String) {
        #expect(RecordingListPresentation.title(filenameStem: name) == name)
    }

    @Test func emptyQueueDoesNotSuggestPendingWork() {
        #expect(RecordingListPresentation.queueSummary(pending: 0, recovery: 0, paused: false, processing: false, hasError: false) == "No pending work")
    }

    @Test func collapsedQueueExposesRecoveryEvenWithoutQueuedItems() {
        #expect(RecordingListPresentation.queueSummary(pending: 0, recovery: 2, paused: false, processing: false, hasError: false) == "2 need attention")
    }

    @Test func summaryIncludesPauseProcessingAndLoadErrors() {
        #expect(RecordingListPresentation.queueSummary(pending: 3, recovery: 1, paused: true, processing: true, hasError: true) == "Paused · Processing · 3 queued · 1 need attention · Couldn’t refresh")
        #expect(RecordingListPresentation.queueSummary(pending: 0, recovery: 0, paused: false, processing: false, hasError: true) == "Couldn’t refresh")
    }

    @MainActor
    @Test func everyRecordingHasAStatusAndQueuedWorkTakesPrecedence() {
        func item(transcript: Bool = false, insights: Bool = false, queued: Bool = false) -> RecordingHistoryView.HistoryItem {
            .init(url: URL(fileURLWithPath: "/tmp/presentation-fixture.m4a"), name: "meeting",
                  date: .now, size: 0, duration: 0, profileName: nil, hasTranscript: transcript,
                  hasRichTranscript: false, hasInsights: insights, isQueued: queued)
        }
        #expect(item().status.label == "Recorded")
        #expect(item(transcript: true).status.label == "Transcribed")
        #expect(item(transcript: true, insights: true).status.label == "Analyzed")
        #expect(item(transcript: true, insights: true, queued: true).status.label == "Queued")
    }
}
