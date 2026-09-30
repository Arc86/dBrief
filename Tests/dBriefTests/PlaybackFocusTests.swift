import Foundation
import Testing
@testable import dBrief

@Suite struct PlaybackFocusTests {
    private let turns = [
        SpeakerTurn(speakerId: "A", segments: [RichSegment(start: 0, end: 5, text: "a", originalText: "a", speakerId: "A")]),
        SpeakerTurn(speakerId: "B", segments: [RichSegment(start: 4, end: 9, text: "b", originalText: "b", speakerId: "B")]),
        SpeakerTurn(speakerId: "A", segments: [RichSegment(start: 9, end: 12, text: "c", originalText: "c", speakerId: "A")]),
    ]

    @Test func nothingIsLitBeforePlaybackStarts() {
        #expect(PlaybackFocus.activeTurnID(time: 0, turns: turns, isThisFile: true, isPlaying: false) == nil)
    }

    @Test func nothingIsLitAfterPlaybackFinishes() {
        // AudioPlayer resets currentTime to 0 and keeps currentFileURL on finish.
        #expect(PlaybackFocus.activeTurnID(time: 0, turns: turns, isThisFile: true, isPlaying: false) == nil)
    }

    @Test func pausedMidwayKeepsItsTurnLit() {
        #expect(PlaybackFocus.activeTurnID(time: 10, turns: turns, isThisFile: true, isPlaying: false) == turns[2].id)
    }

    @Test func playingFromZeroLightsTheFirstTurn() {
        #expect(PlaybackFocus.activeTurnID(time: 0, turns: turns, isThisFile: true, isPlaying: true) == turns[0].id)
    }

    @Test func anotherRecordingsAudioLightsNothing() {
        #expect(PlaybackFocus.activeTurnID(time: 6, turns: turns, isThisFile: false, isPlaying: true) == nil)
    }

    @Test func overlappingTurnsPickTheFirstMatch() {
        #expect(PlaybackFocus.activeTurnID(time: 4.5, turns: turns, isThisFile: true, isPlaying: true) == turns[0].id)
    }

    @Test func gapsAndInvalidTimesLightNothing() {
        #expect(PlaybackFocus.activeTurnID(time: 20, turns: turns, isThisFile: true, isPlaying: true) == nil)
        #expect(PlaybackFocus.activeTurnID(time: .nan, turns: turns, isThisFile: true, isPlaying: true) == nil)
    }

    @Test func onlyOrdinaryForwardPlaybackAnimatesTheFollowScroll() {
        #expect(PlaybackFocus.animatesFollowScroll(from: 10.0, to: 10.1))
        #expect(!PlaybackFocus.animatesFollowScroll(from: 10.0, to: 3.0))    // seek back
        #expect(!PlaybackFocus.animatesFollowScroll(from: 10.0, to: 40.0))   // seek / scrub forward
        #expect(!PlaybackFocus.animatesFollowScroll(from: 10.0, to: 10.0))
    }
}
