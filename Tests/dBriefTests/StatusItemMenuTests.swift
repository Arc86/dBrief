import Foundation
import Testing
@testable import dBrief

@Suite("Menu bar icon extras")
struct StatusItemMenuTests {
    @Test func idleOffersRecordThenLibraryImportSettingsQuit() {
        #expect(StatusItemMenuEntry.entries(isRecording: false, isPaused: false, isIdle: true, canImport: true) == [
            .startRecording(enabled: true), .separator, .openLibrary, .importFile(enabled: true), .separator, .settings, .quit,
        ])
    }

    @Test func recordingOffersPauseAndStop() {
        let entries = StatusItemMenuEntry.entries(isRecording: true, isPaused: false, isIdle: false, canImport: false)
        #expect(Array(entries.prefix(2)) == [.pauseRecording, .stopRecording])
        #expect(entries.contains(.importFile(enabled: false)))
    }

    @Test func pausedOffersResumeAndStop() {
        let entries = StatusItemMenuEntry.entries(isRecording: false, isPaused: true, isIdle: false, canImport: false)
        #expect(Array(entries.prefix(2)) == [.resumeRecording, .stopRecording])
    }

    @Test func recordIsDisabledWhenCaptureIsNotIdle() {
        let entries = StatusItemMenuEntry.entries(isRecording: false, isPaused: false, isIdle: false, canImport: false)
        #expect(entries.first == .startRecording(enabled: false))
    }

    @Test(arguments: ["meeting.m4a", "memo.wav", "talk.mp3", "voice.flac", "chat.ogg", "note.opus", "clip.aiff"])
    func audioFilesAreImportable(name: String) {
        #expect(RecordingManager.isImportableAudio(URL(fileURLWithPath: "/tmp/\(name)")))
    }

    @Test(arguments: ["notes.md", "slides.pdf", "folder", "image.png"])
    func otherFilesAreNotImportable(name: String) {
        #expect(!RecordingManager.isImportableAudio(URL(fileURLWithPath: "/tmp/\(name)")))
    }

    @Test func webLinksAreNotImportableFiles() {
        #expect(!RecordingManager.isImportableAudio(URL(string: "https://example.com/talk.mp3")!))
    }
}
