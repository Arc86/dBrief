import Testing
@testable import dBrief

/// Settings already hid provider responses; processing steps and notices showed them raw.
@Suite struct UserFacingErrorTests {
    @Test func serverBodiesNeverReachTheUser() {
        let raw = "AI results could not be generated.\n\nServer error (401): {\"error\":\"invalid key sk-live-123\"}"
        let text = UserFacingError.text(raw)
        #expect(text.hasPrefix("AI results could not be generated."))
        #expect(text.contains("HTTP 401"))
        #expect(!text.contains("sk-live-123"))
    }

    @Test func commandOutputIsDroppedToo() {
        let text = UserFacingError.text("Local CLI command exited with code 2: token=abc123 rejected")
        #expect(text.contains("code 2"))
        #expect(!text.contains("abc123"))
    }

    @Test func ordinaryMessagesAreUnchanged() {
        let message = "Couldn't switch microphone: The device is busy."
        #expect(UserFacingError.text(message) == message)
    }
}
