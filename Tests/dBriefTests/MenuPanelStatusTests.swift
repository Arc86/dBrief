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

    @Test func selectedTaskCountFollowsTranscriptionAndAI() {
        #expect(MenuPanelProgress.selectedTaskCount(transcribe: true, summary: true, actionItems: true, tags: true, aiEnabled: true) == 4)
        #expect(MenuPanelProgress.selectedTaskCount(transcribe: true, summary: false, actionItems: true, tags: false, aiEnabled: true) == 2)
        // AI tasks don't run without a transcript or with AI processing off.
        #expect(MenuPanelProgress.selectedTaskCount(transcribe: false, summary: true, actionItems: true, tags: true, aiEnabled: true) == 0)
        #expect(MenuPanelProgress.selectedTaskCount(transcribe: true, summary: true, actionItems: true, tags: true, aiEnabled: false) == 1)
    }

    @Test func moreDetailsAppearsWheneverTextCanBeCutOff() {
        // Short single-line summary with nothing else: nothing to reveal.
        #expect(!MenuPanelProgress.offersMoreDetails(summary: "Short.", transcriptFallback: false, actionCount: 0, tagCount: 0, hasSentiment: false))
        // Medium summary that wraps past four lines in a 328 pt column.
        #expect(MenuPanelProgress.offersMoreDetails(summary: String(repeating: "word ", count: 36), transcriptFallback: false, actionCount: 0, tagCount: 0, hasSentiment: false))
        // Short bulleted summary spread over several lines.
        #expect(MenuPanelProgress.offersMoreDetails(summary: "- a\n- b\n- c\n- d\n- e", transcriptFallback: false, actionCount: 0, tagCount: 0, hasSentiment: false))
        // A transcript fallback is always expandable.
        #expect(MenuPanelProgress.offersMoreDetails(summary: nil, transcriptFallback: true, actionCount: 0, tagCount: 0, hasSentiment: false))
        #expect(MenuPanelProgress.offersMoreDetails(summary: "Short.", transcriptFallback: false, actionCount: 2, tagCount: 0, hasSentiment: false))
    }

    @Test func stopProcessingIsNamedApartFromStopRecording() {
        #expect(MenuPanelProgress.stopProcessingTitle(isCapturing: false) == "Stop")
        #expect(MenuPanelProgress.stopProcessingTitle(isCapturing: true) == "Stop processing")
    }

    @Test func deferredProfileNoticeStaysOnTheSurface() {
        #expect(MenuPanelProgress.profileNoticeOnSurface(isDeferred: true))
        #expect(!MenuPanelProgress.profileNoticeOnSurface(isDeferred: false))
    }

    @Test func statusDotOnlyDimsWhilePulsing() {
        #expect(MenuPanelStatusDot.opacity(pulse: true, dimmed: true) < 1)
        #expect(MenuPanelStatusDot.opacity(pulse: false, dimmed: true) == 1)
        #expect(MenuPanelStatusDot.opacity(pulse: true, dimmed: false) == 1)
    }

    @Test func levelBarsRiseFastAndFallSlowly() {
        let rise = MenuPanelLevelBars.smoothed(previous: 0, target: 1)
        let fall = MenuPanelLevelBars.smoothed(previous: 1, target: 0)
        #expect(rise > 1 - fall, "rise \(rise) should outpace fall \(1 - fall)")
        #expect((0...1).contains(rise) && (0...1).contains(fall))
        #expect(MenuPanelLevelBars.smoothed(previous: 0.4, target: 0.4) == 0.4)
    }
}
