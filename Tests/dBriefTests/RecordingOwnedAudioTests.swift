import Foundation
import Testing
@testable import dBrief

@Suite("Audio a recording owns")
struct RecordingOwnedAudioTests {
    @MainActor
    @Test func importOwnsOnlyItsStagedCopyNeverTheOriginal() {
        let original = URL(fileURLWithPath: "/Users/someone/Desktop/interview.m4a")
        let staged = URL(fileURLWithPath: "/tmp/import-1.m4a")
        let recording = Recording(fileURL: original, fileSize: 1, meetingTitleDraft: "interview", finalizedAudioURL: nil)
        recording.importSourceURL = staged
        #expect(recording.ownedAudioURL == staged)
    }

    @MainActor
    @Test func captureOwnsItsFile() {
        let captured = URL(fileURLWithPath: "/tmp/capture.caf")
        let recording = Recording(fileURL: captured, fileSize: 1, meetingTitleDraft: "meeting", finalizedAudioURL: nil)
        #expect(recording.ownedAudioURL == captured)
    }
}
