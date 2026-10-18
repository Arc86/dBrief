import Testing
@testable import dBrief

@Suite("Call prompt text")
struct CallPromptTextTests {
    @Test func detectedNamesTheApp() {
        let text = CallPromptText.detected(app: "Zoom")
        #expect(text.title == "Zoom call detected")
        #expect(text.announcement == "Zoom call detected. Record this call and create a meeting brief.")
    }

    @Test func detectedWithoutAppSaysACall() {
        #expect(CallPromptText.detected(app: nil).title == "A call detected")
    }

    @Test func endedNamesTheApp() {
        let text = CallPromptText.ended(app: "Teams")
        #expect(text.title == "Teams ended")
        #expect(text.announcement == "Teams ended. Stop recording and create the meeting brief?")
        #expect(CallPromptText.ended(app: nil).title == "Call ended")
    }
}
