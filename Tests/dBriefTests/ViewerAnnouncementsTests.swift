import Foundation
import Testing
@testable import dBrief

@Suite("Viewer and assistant announcements")
struct ViewerAnnouncementsTests {
    @Test func answerReadsItsFirstSentenceWithoutMarkdown() {
        let spoken = ChatAnnouncement.finished("**Alex** owns the launch. Bob reviews it.\n- more")
        #expect(spoken.text == "Answer ready. Alex owns the launch.")
        #expect(spoken.priority == .normal)
    }

    @Test func errorsAreSpokenUrgently() {
        let spoken = ChatAnnouncement.finished("Error: The model is unavailable.")
        #expect(spoken.text == "Error: The model is unavailable.")
        #expect(spoken.priority == .high)
    }

    @Test func longSentencesAreCut() {
        let sentence = ChatAnnouncement.firstSentence(String(repeating: "word ", count: 80))
        #expect(sentence.count <= 201)
        #expect(sentence.hasSuffix("…"))
    }

    @Test func spokenSummaryStepsHaveOneLineEach() {
        #expect(SpokenSummaryService.Phase.idle.announcement == nil)
        #expect(SpokenSummaryService.Phase.preparingVoice(progress: 0.2).announcement
                == SpokenSummaryService.Phase.preparingVoice(progress: 0.7).announcement)
        #expect(SpokenSummaryService.Phase.failed(message: "No voice.").announcement
                == "Couldn't create the spoken summary. No voice.")
        #expect(SpokenSummaryService.Phase.failed(message: "x").isFailure)
    }
}

@Suite("Onboarding step announcements")
struct OnboardingStepTests {
    @Test func stepPositionCountsOnlyVisibleSteps() {
        #expect(OnboardingStep.announcement(step: 1, visibleSteps: [0, 1, 2, 4]) == "Step 2 of 4: Permissions")
        #expect(OnboardingStep.announcement(step: 4, visibleSteps: [0, 1, 2, 4]) == "Step 4 of 4: Before you record")
        #expect(OnboardingStep.announcement(step: 3, visibleSteps: [0, 1, 2, 3, 4]) == "Step 4 of 5: Prepare your models")
    }
}
