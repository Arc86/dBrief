import Foundation
import Testing
@testable import dBrief

/// The panel's "Live" button opened the processing job's transcript instead of the
/// meeting being recorded, because one flag meant "prefer the job".
@Suite struct LiveTranscriptTargetTests {
    private let capture = URL(fileURLWithPath: "/tmp/live/capture.caf")
    private let job = URL(fileURLWithPath: "/tmp/live/job.m4a")

    @Test func eachButtonOpensItsOwnRecording() {
        #expect(LiveTranscriptTarget.capture.url(capture: capture, processing: job) == capture)
        #expect(LiveTranscriptTarget.processing.url(capture: capture, processing: job) == job)
    }

    @Test func fallsBackWhenItsRecordingIsGone() {
        #expect(LiveTranscriptTarget.capture.url(capture: nil, processing: job) == job)
        #expect(LiveTranscriptTarget.processing.url(capture: capture, processing: nil) == capture)
    }
}
