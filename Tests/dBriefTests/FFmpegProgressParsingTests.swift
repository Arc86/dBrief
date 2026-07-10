import Foundation
import Testing
@testable import dBrief

struct FFmpegProgressParsingTests {

    @Test
    func parsesMicrosecondField() {
        // out_time_us is microseconds → 1_234_567µs = 1.234567s.
        let seconds = RecordingFinalizer.parseFFmpegProgressSeconds(from: "out_time_us=1234567")
        #expect(seconds == 1.234567)
    }

    @Test
    func parsesTimecodeField() {
        let seconds = RecordingFinalizer.parseFFmpegProgressSeconds(from: "out_time=00:01:30.500000")
        #expect(seconds == 90.5)
    }

    @Test
    func microsecondFieldToleratesWhitespace() {
        let seconds = RecordingFinalizer.parseFFmpegProgressSeconds(from: "  out_time_us=500000  ")
        #expect(seconds == 0.5)
    }

    @Test
    func naPlaceholderReturnsNil() {
        // ffmpeg emits "out_time_us=N/A" at startup before any frame is written.
        let seconds = RecordingFinalizer.parseFFmpegProgressSeconds(from: "out_time_us=N/A")
        #expect(seconds == nil)
    }

    @Test
    func unrelatedLinesReturnNil() {
        let frame = RecordingFinalizer.parseFFmpegProgressSeconds(from: "frame=123")
        let progress = RecordingFinalizer.parseFFmpegProgressSeconds(from: "progress=continue")
        let empty = RecordingFinalizer.parseFFmpegProgressSeconds(from: "")
        #expect(frame == nil)
        #expect(progress == nil)
        #expect(empty == nil)
    }

    @Test
    func timecodeParsingZero() {
        let seconds = RecordingFinalizer.parseTimecodeSeconds("00:00:00.000000")
        #expect(seconds == 0)
    }

    @Test
    func timecodeParsingOneHour() {
        let seconds = RecordingFinalizer.parseTimecodeSeconds("01:00:00.000000")
        #expect(seconds == 3600)
    }

    @Test
    func timecodeParsingCompound() {
        let seconds = RecordingFinalizer.parseTimecodeSeconds("02:03:04.5")
        let expected: Double = 7384.5 // 2h + 3m + 4.5s
        #expect(seconds == expected)
    }

    @Test
    func timecodeParsingRejectsMalformed() {
        let bad = RecordingFinalizer.parseTimecodeSeconds("malformed")
        let short = RecordingFinalizer.parseTimecodeSeconds("00:00")
        #expect(bad == nil)
        #expect(short == nil)
    }
}
