import Foundation
import Testing
@testable import dBrief

@MainActor
@Suite("Accessibility announcements")
struct AccessibilityAnnouncerTests {
    /// Records what would have been spoken, with a clock the test moves.
    @MainActor final class Spy {
        var spoken: [(String, AnnouncementPriority)] = []
        var now = Date(timeIntervalSince1970: 1_000)

        func announcer() -> AccessibilityAnnouncer {
            AccessibilityAnnouncer(post: { [unowned self] text, priority in spoken.append((text, priority)) },
                                   now: { [unowned self] in now })
        }
    }

    @Test(arguments: [
        (RecordingAnnouncement.started, "Recording started"),
        (.paused, "Recording paused"),
        (.resumed, "Recording resumed"),
        (.stopped, "Recording stopped"),
        (.failed, "Recording failed"),
        (.processingFinished(failedSteps: 0), "Processing complete"),
        (.processingFinished(failedSteps: 1), "Processing finished, 1 step failed"),
        (.processingFinished(failedSteps: 3), "Processing finished, 3 steps failed"),
        (.error("Microphone unavailable."), "Error: Microphone unavailable."),
    ])
    func eventsBecomeShortSentences(event: RecordingAnnouncement, text: String) {
        #expect(event.text == text)
    }

    @Test func problemsAreSpokenAtHighPriority() {
        #expect(RecordingAnnouncement.error("x").priority == .high)
        #expect(RecordingAnnouncement.failed.priority == .high)
        #expect(RecordingAnnouncement.processingFinished(failedSteps: 2).priority == .high)
        #expect(RecordingAnnouncement.processingFinished(failedSteps: 0).priority == .normal)
        #expect(RecordingAnnouncement.started.priority == .normal)
    }

    @Test func anIdenticalMessageWithinASecondIsSpokenOnce() {
        let spy = Spy()
        let announcer = spy.announcer()
        announcer.announce(.started)
        spy.now += 0.5
        announcer.announce(.started)
        #expect(spy.spoken.map(\.0) == ["Recording started"])

        spy.now += 1.0
        announcer.announce(.started)
        #expect(spy.spoken.count == 2)
    }

    @Test func aDifferentMessageIsAlwaysSpoken() {
        let spy = Spy()
        let announcer = spy.announcer()
        announcer.announce(.paused)
        announcer.announce(.resumed)
        #expect(spy.spoken.map(\.0) == ["Recording paused", "Recording resumed"])
        #expect(spy.spoken.map(\.1) == [.normal, .normal])
    }

    @Test func blankTextIsNeverSpoken() {
        let spy = Spy()
        spy.announcer().announce("   ", priority: .high)
        #expect(spy.spoken.isEmpty)
    }

    @Test func settingAnErrorOnAppStateAnnouncesItAndClearingItStaysSilent() {
        let spy = Spy()
        let state = AppState()
        state.announcer = spy.announcer()

        state.lastError = "Screen Recording permission is off."
        #expect(spy.spoken.map(\.0) == ["Error: Screen Recording permission is off."])
        #expect(spy.spoken.map(\.1) == [.high])

        state.lastError = nil
        state.lastError = "   "
        #expect(spy.spoken.count == 1)
    }

    @Test func errorNoticesFromAnySourceAreSpokenButWarningsAndInfoAreNot() {
        let spy = Spy()
        let state = AppState()
        state.announcer = spy.announcer()

        state.post(.warning, "Calendar unavailable", source: .capture)
        state.post(.info, "Copied", source: .library)
        state.post(.error, "Notion delivery failed", source: .integrations)
        #expect(spy.spoken.map(\.0) == ["Error: Notion delivery failed"])
    }
}
