import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Processing transcript preview") @MainActor
struct ProcessingTranscriptPreviewTests {
    @Test func retranscriptionPreviewUsesTheStagedRecordingAndKeepsOriginalSeparate() {
        let original = Recording(fileURL: URL(fileURLWithPath: "/tmp/preview.wav"), duration: 120)
        original.transcription = .init(text: "Published words")
        let staged = Recording(id: original.id, fileURL: original.fileURL, duration: 120)
        let job = ProcessingJob(recording: staged)
        job.reprocessingAttemptID = job.id
        #expect(job.showsTranscriptPreview(for: staged))
        #expect(!job.showsTranscriptPreview(for: original))
        job.progressiveSegments = [.init(start: 0, end: 2, text: "Replacement words")]
        #expect(job.transcriptPreviewSegments.first?.text == "Replacement words")
        #expect(original.transcription?.text == "Published words")
    }

    @Test func streamingThenCompletedTranscriptRemainsAvailableDuringAnalysis() {
        let job = ProcessingJob(recording: Recording(fileURL: URL(fileURLWithPath: "/tmp/preview.wav"), duration: 12))
        #expect(job.transcriptPreviewSegments.isEmpty)
        #expect(job.transcriptButtonTitle == nil)
        job.transcriptionStartedAt = .now
        #expect(job.transcriptButtonTitle == "Transcription Progress")
        job.progressiveSegments = [.init(start: 0, end: 2, text: "Draft words")]
        #expect(job.transcriptButtonTitle == "Live Transcript")
        #expect(job.transcriptPreviewSegments.map(\.text) == ["Draft words"])
        job.recording.transcription = .init(text: "Final words", segments: [.init(start: 0, end: 3, text: "Final words", speaker: "Alice")])
        job.transcriptionStartedAt = nil
        #expect(job.transcriptButtonTitle == "View Transcript")
        #expect(job.transcriptPreviewSegments.map(\.text) == ["Final words"])
        #expect(job.transcriptPreviewSegments.first?.speaker == "Alice")
    }

    @Test func nonStreamingTextOnlyResultCanBeViewedWhileAnalysisRuns() {
        let job = ProcessingJob(recording: Recording(fileURL: URL(fileURLWithPath: "/tmp/preview.wav"), duration: 12))
        job.recording.transcription = .init(text: "A complete transcript without timestamps")
        #expect(job.transcriptButtonTitle == "View Transcript")
        #expect(job.transcriptPreviewSegments.first?.text == "A complete transcript without timestamps")
        #expect(job.transcriptPreviewSegments.first?.end == 12)
    }
}
