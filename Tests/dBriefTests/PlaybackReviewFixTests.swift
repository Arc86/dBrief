import AppKit
import Foundation
import Testing
@testable import dBrief

@Suite("Batch 2 review fixes", .serialized) @MainActor
struct PlaybackReviewFixTests {
    // #1: only ordinary playback ticks animate the follow-scroll. Scrubs and
    // arrow-key seeks — even small forward ones, or any while paused — jump.
    @Test func smallForwardSeeksDoNotAnimate() {
        #expect(PlaybackFocus.animatesFollowScroll(from: 10.0, to: 10.1, isPlaying: true, rate: 1))
        #expect(PlaybackFocus.animatesFollowScroll(from: 10.0, to: 10.2, isPlaying: true, rate: 2))
        #expect(!PlaybackFocus.animatesFollowScroll(from: 10.0, to: 10.4, isPlaying: true, rate: 1))   // scrub step
        #expect(!PlaybackFocus.animatesFollowScroll(from: 10.0, to: 10.1, isPlaying: false, rate: 1))  // paused drag
        #expect(!PlaybackFocus.animatesFollowScroll(from: 10.0, to: 9.9, isPlaying: true, rate: 1))
    }

    // #2: when another recording is loaded, this bar shows the start — pressing
    // Play here starts from 0:00 — never a stale earlier position.
    @Test func unloadedRecordingShowsTheStart() {
        #expect(TranscriptPlayerBar.displayTime(isThisFile: false, playerTime: 300, duration: 600) == 0)
        #expect(TranscriptPlayerBar.displayTime(isThisFile: true, playerTime: 300, duration: 600) == 300)
        #expect(TranscriptPlayerBar.displayTime(isThisFile: true, playerTime: 900, duration: 600) == 600)
        #expect(TranscriptPlayerBar.displayTime(isThisFile: true, playerTime: .nan, duration: 600) == 0)
    }

    // #5: a tick whose owner is gone stops its timer instead of running forever.
    @Test func tickTimerStopsWhenItsOwnerIsGone() {
        _ = NSApplication.shared
        var ticks = 0
        let timer = AudioPlayer.scheduleTickTimer(interval: 0.02) {
            ticks += 1
            return ticks < 2
        }
        let deadline = Date().addingTimeInterval(2)
        while timer.isValid, Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        #expect(!timer.isValid)
        #expect(ticks == 2)
    }
}
