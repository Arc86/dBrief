import Foundation
import Testing
@testable import dBrief

@Suite struct LiveAudioTimelineTests {
    @Test func staggeredSourcesHaveSeparateMeetingAndSavedTrackPositions() throws {
        let timeline = try LiveAudioTimeline(originNanoseconds: 0), mic = UUID(), system = UUID()
        let frames = LiveAudioFrameRange(startFrame: 0, frameCount: 100, sampleRate: 1000)
        let outcome = LiveAudioWriteOutcome.receipt(.written(startFrame: 0, frameCount: 100, sampleRate: 1000))
        let a = timeline.project(sourceFrames: frames, sourceEpoch: mic,
            anchor: .init(sourceEpoch: mic, sourceFrame: 0, hostNanoseconds: 0, sampleRate: 1000, verified: true),
            outcome: outcome, conversionAlignmentVerified: true)
        let b = timeline.project(sourceFrames: frames, sourceEpoch: system,
            anchor: .init(sourceEpoch: system, sourceFrame: 0, hostNanoseconds: 300000000, sampleRate: 1000, verified: true),
            outcome: outcome, conversionAlignmentVerified: true)
        #expect(a.meeting == .init(startNanoseconds: 0, endNanoseconds: 100000000))
        #expect(b.meeting == .init(startNanoseconds: 300000000, endNanoseconds: 400000000))
        #expect(a.savedTrack == frames)
        #expect(b.savedTrack == frames)
    }
    @Test func pauseAndSourceRestartExcludePausedTimeWithoutRewritingTrackPosition() throws {
        let timeline = try LiveAudioTimeline(originNanoseconds: 0,
            pauses: [.init(startNanoseconds: 1000000000, endNanoseconds: 11000000000)])
        let epoch = UUID()
        let value = timeline.project(sourceFrames: .init(startFrame: 0, frameCount: 100, sampleRate: 1000), sourceEpoch: epoch,
            anchor: .init(sourceEpoch: epoch, sourceFrame: 0, hostNanoseconds: 11000000000, sampleRate: 1000, verified: true),
            outcome: .receipt(.written(startFrame: 400, frameCount: 100, sampleRate: 1000)), conversionAlignmentVerified: true)
        #expect(value.meeting == .init(startNanoseconds: 1000000000, endNanoseconds: 1100000000))
        #expect(value.savedTrack == .init(startFrame: 400, frameCount: 100, sampleRate: 1000))
    }
    @Test func missingUnverifiedOrWrongEpochAnchorsKeepOnlyActualSavedAudio() throws {
        let timeline = try LiveAudioTimeline(originNanoseconds: 0), epoch = UUID()
        let frames = LiveAudioFrameRange(startFrame: 0, frameCount: 10, sampleRate: 16000)
        let outcomes: [LiveAudioClockAnchor?] = [nil,
            .init(sourceEpoch: epoch, sourceFrame: 0, hostNanoseconds: 0, sampleRate: 16000, verified: false),
            .init(sourceEpoch: UUID(), sourceFrame: 0, hostNanoseconds: 0, sampleRate: 16000, verified: true)]
        for anchor in outcomes {
            let value = timeline.project(sourceFrames: frames, sourceEpoch: epoch, anchor: anchor,
                outcome: .receipt(.written(startFrame: 20, frameCount: 10, sampleRate: 16000)), conversionAlignmentVerified: true)
            #expect(value.meeting == nil)
            #expect(value.savedTrack == .init(startFrame: 20, frameCount: 10, sampleRate: 16000))
        }
    }
    @Test func writeFailureAndUnverifiedConversionCannotInventSavedAudioOrChronology() throws {
        let timeline = try LiveAudioTimeline(originNanoseconds: 0), epoch = UUID()
        let frames = LiveAudioFrameRange(startFrame: 0, frameCount: 100, sampleRate: 1000)
        let anchor = LiveAudioClockAnchor(sourceEpoch: epoch, sourceFrame: 0, hostNanoseconds: 0, sampleRate: 1000, verified: true)
        let failed = timeline.project(sourceFrames: frames, sourceEpoch: epoch, anchor: anchor, outcome: .failed, conversionAlignmentVerified: true)
        #expect(failed.meeting == .init(startNanoseconds: 0, endNanoseconds: 100000000))
        #expect(failed.savedTrack == nil)
        let unverified = timeline.project(sourceFrames: frames, sourceEpoch: epoch, anchor: anchor,
            outcome: .receipt(.written(startFrame: 0, frameCount: 100, sampleRate: 1000)), conversionAlignmentVerified: false)
        #expect(unverified.meeting == nil)
        #expect(unverified.savedTrack == frames)
    }
    @Test func crossPauseInvalidRatesAndOverflowRemainUnmapped() throws {
        let timeline = try LiveAudioTimeline(originNanoseconds: 0,
            pauses: [.init(startNanoseconds: 1000000000, endNanoseconds: 2000000000)]), epoch = UUID()
        let anchor = LiveAudioClockAnchor(sourceEpoch: epoch, sourceFrame: 0, hostNanoseconds: 0, sampleRate: 1000, verified: true)
        for frames in [LiveAudioFrameRange(startFrame: 500, frameCount: 1000, sampleRate: 1000),
                       .init(startFrame: Int64.max, frameCount: 1, sampleRate: 1000),
                       .init(startFrame: 0, frameCount: 1, sampleRate: .infinity)] {
            let value = timeline.project(sourceFrames: frames, sourceEpoch: epoch, anchor: anchor,
                outcome: .receipt(.dropped(.formatMismatch)), conversionAlignmentVerified: true)
            #expect(value.meeting == nil)
            #expect(value.savedTrack == nil)
        }
        #expect(throws: (any Error).self) {
            try LiveAudioTimeline(originNanoseconds: 0, pauses: [
                .init(startNanoseconds: 2, endNanoseconds: 5), .init(startNanoseconds: 4, endNanoseconds: 8)])
        }
    }

    @Test func fractionalFrameDurationsUseConservativeIntegerBounds() throws {
        let timeline = try LiveAudioTimeline(originNanoseconds: 10), epoch = UUID()
        let anchor = LiveAudioClockAnchor(sourceEpoch: epoch, sourceFrame: 100, hostNanoseconds: 10, sampleRate: 44100, verified: true)
        let value = timeline.project(sourceFrames: .init(startFrame: 101, frameCount: 1, sampleRate: 44100), sourceEpoch: epoch,
            anchor: anchor, outcome: .failed, conversionAlignmentVerified: true)
        #expect(value.meeting == .init(startNanoseconds: 22675, endNanoseconds: 45352))
    }

    @Test func invalidClocksAndRangesCannotEscapeUnmappedState() throws {
        #expect(throws: (any Error).self) { try LiveAudioTimeline(originNanoseconds: -1) }
        #expect(throws: (any Error).self) {
            try LiveAudioTimeline(originNanoseconds: 10, pauses: [.init(startNanoseconds: 0, endNanoseconds: 5)])
        }
        let timeline = try LiveAudioTimeline(originNanoseconds: 100), epoch = UUID()
        let frames = LiveAudioFrameRange(startFrame: 0, frameCount: 1, sampleRate: 16000)
        for anchor in [LiveAudioClockAnchor(sourceEpoch: epoch, sourceFrame: 0, hostNanoseconds: 99, sampleRate: 16000, verified: true),
                       .init(sourceEpoch: epoch, sourceFrame: 1, hostNanoseconds: 100, sampleRate: 16000, verified: true),
                       .init(sourceEpoch: epoch, sourceFrame: 0, hostNanoseconds: .max, sampleRate: 16000, verified: true),
                       .init(sourceEpoch: epoch, sourceFrame: 0, hostNanoseconds: 100, sampleRate: 48000, verified: true)] {
            let value = timeline.project(sourceFrames: frames, sourceEpoch: epoch, anchor: anchor,
                outcome: .receipt(.written(startFrame: -1, frameCount: 1, sampleRate: 16000)), conversionAlignmentVerified: true)
            #expect(value.meeting == nil && value.savedTrack == nil)
        }
    }

    @Test func aPrePauseAnchorCannotExtrapolateConcatenatedFramesAfterResume() throws {
        let timeline = try LiveAudioTimeline(originNanoseconds: 0,
            pauses: [.init(startNanoseconds: 1000000000, endNanoseconds: 2000000000)]), epoch = UUID()
        let frames = LiveAudioFrameRange(startFrame: 2000, frameCount: 100, sampleRate: 1000)
        let outcome = LiveAudioWriteOutcome.receipt(.written(startFrame: 2000, frameCount: 100, sampleRate: 1000))
        let old = timeline.project(sourceFrames: frames, sourceEpoch: epoch,
            anchor: .init(sourceEpoch: epoch, sourceFrame: 0, hostNanoseconds: 0, sampleRate: 1000, verified: true),
            outcome: outcome, conversionAlignmentVerified: true)
        #expect(old.meeting == nil)
        #expect(old.savedTrack == frames)
        let resumed = timeline.project(sourceFrames: frames, sourceEpoch: epoch,
            anchor: .init(sourceEpoch: epoch, sourceFrame: 1000, hostNanoseconds: 2000000000, sampleRate: 1000, verified: true),
            outcome: outcome, conversionAlignmentVerified: true)
        #expect(resumed.meeting == .init(startNanoseconds: 2000000000, endNanoseconds: 2100000000))
    }
}
