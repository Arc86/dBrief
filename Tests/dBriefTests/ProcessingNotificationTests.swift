import Testing
@testable import dBrief

/// Notifications used to announce only success, said "analyzed" with AI off, and named
/// the draft file instead of the meeting.
@Suite struct ProcessingNotificationTests {
    @Test func successSaysWhatActuallyHappened() {
        let analyzed = ProcessingNotification.content(.processed(analyzed: true), title: "Weekly sync")
        #expect(analyzed.title == "Recording processed")
        #expect(analyzed.body == "“Weekly sync” is transcribed and analyzed.")
        let transcribed = ProcessingNotification.content(.processed(analyzed: false), title: "Weekly sync")
        #expect(transcribed.body == "“Weekly sync” is transcribed.")
    }

    @Test func failuresAreAnnouncedWithANextStep() {
        let failed = ProcessingNotification.content(.failed(stage: "transcription"), title: "Weekly sync")
        #expect(failed.title == "Processing didn't finish")
        #expect(failed.body == "“Weekly sync”: transcription failed. Open it to retry.")
        let issues = ProcessingNotification.content(.finishedWithIssues(failedSteps: ["Generating summary", "Send: Notion"]),
                                                    title: "Weekly sync")
        #expect(issues.title == "Processing finished with issues")
        #expect(issues.body == "“Weekly sync”: Generating summary and 1 more step didn't finish. Open it to retry.")
    }

    @Test func reprocessingHasItsOwnOutcomes() {
        #expect(ProcessingNotification.content(.reprocessed, title: "X").title == "Reprocessing finished")
        let failed = ProcessingNotification.content(.reprocessFailed, title: "X")
        #expect(failed.title == "Reprocessing didn't finish")
        #expect(failed.body.contains("current results were kept"))
    }
}
