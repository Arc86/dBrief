import Testing
@testable import dBrief

@Suite struct MenuPanelStatusTests {
    private func status(rec: Bool = false, paused: Bool = false, proc: Bool = false, post: Bool = false, results: Bool = false) -> MenuPanelStatus {
        .resolve(isRecording: rec, isPaused: paused, isProcessing: proc, showsPostRecording: post, hasResults: results)
    }

    @Test func idleIsReady() { #expect(status() == .ready); #expect(status().label == "Ready") }
    @Test func captureWinsOverABackgroundJob() {
        #expect(status(rec: true, proc: true) == .recording)
        #expect(status(paused: true, proc: true) == .paused)
    }
    @Test func reviewFormWinsOverABackgroundJob() {
        #expect(status(proc: true, post: true) == .recordingCompleted)
        #expect(status(proc: true, post: true).label == "Recording completed")
    }
    @Test func processingThenBrief() {
        #expect(status(proc: true) == .processing)
        #expect(status(results: true) == .briefReady)
        #expect(status(results: true).label == "Brief ready")
    }
    @Test func tones() {
        #expect(MenuPanelStatus.ready.tone == .success)
        #expect(MenuPanelStatus.recording.tone == .danger)
        #expect(MenuPanelStatus.paused.tone == .warning)
        #expect(MenuPanelStatus.processing.tone == .accent)
    }

    @Test func countsCompletedSteps() {
        let steps = [
            ProcessingStep(name: "Finalizing audio", status: .completed),
            ProcessingStep(name: "Identifying speakers", status: .completed),
            ProcessingStep(name: "Generating summary", status: .inProgress),
            ProcessingStep(name: "Extracting action items", status: .pending),
            ProcessingStep(name: "Analyzing tags", status: .failed("x")),
        ]
        #expect(MenuPanelProgress.doneLabel(steps) == "2 of 5 done")
        #expect(MenuPanelProgress.doneLabel([]) == nil)
    }

    @Test func briefContentsListsOnlyWhatExists() {
        #expect(MenuPanelProgress.briefContents(summary: true, actions: true, tags: true, notes: true) == "Summary · Actions · Tags · Notes")
        #expect(MenuPanelProgress.briefContents(summary: true, actions: false, tags: false, notes: true) == "Summary · Notes")
        #expect(MenuPanelProgress.briefContents(summary: false, actions: false, tags: false, notes: false) == nil)
    }
}
