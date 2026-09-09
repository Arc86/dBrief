import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Reprocessing stage ownership") @MainActor
struct ReprocessingStageTests {
    @Test func stopJoinsConfirmationAlreadySuspendedInPersistence() async {
        let job = ProcessingJob(recording: Recording(fileURL: URL(fileURLWithPath: "/tmp/review.wav")))
        job.task = Task {}
        await job.task?.value
        let (started, signal) = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<Void, Never>?
        var resumed = false
        var joined = false
        RecordingManager.installReprocessingReviewTask(on: job) {
            await withCheckedContinuation { continuation in
                release = continuation
                signal.yield(())
            }
            guard !Task.isCancelled else { return }
            resumed = true
        }
        var iterator = started.makeAsyncIterator()
        await iterator.next()
        // Stop uses this exact handle; cancelling an already-finished held task
        // would neither cancel nor join the suspended confirmation above.
        job.task?.cancel()
        let stop = Task { await job.task?.value; joined = true }
        await Task.yield()
        #expect(!joined)
        release?.resume()
        await stop.value
        #expect(joined)
        #expect(!resumed)
    }

    @Test func cancelledConfirmationWaitsForHeldWorkflowBeforeDoingAnyWork() async {
        let job = ProcessingJob(recording: Recording(fileURL: URL(fileURLWithPath: "/tmp/review.wav")))
        let (started, signal) = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<Void, Never>?
        job.task = Task {
            await withCheckedContinuation { continuation in release = continuation; signal.yield(()) }
        }
        var iterator = started.makeAsyncIterator()
        await iterator.next()
        var executed = false
        RecordingManager.installReprocessingReviewTask(on: job) { executed = true }
        job.task?.cancel()
        release?.resume()
        await job.task?.value
        #expect(!executed)
    }

    @Test func replacementSpeakerEvidencePreservesWordsAndTimingButNotOldClusters() throws {
        let raw = TranscriptionResult(text: "Hello there", segments: [
            .init(start: 0, end: 2, text: "Hello", words: [.init(word: "Hello", start: 0, end: 1, probability: 0.9, speaker: "old")], speaker: "old"),
            .init(start: 3, end: 4, text: "there", speaker: "old")
        ], language: "en", warnings: ["kept"], speakerCount: 1, inferenceTime: 2,
           diarizationTime: 3, speakerEmbeddings: ["old": [9], "Speaker 1": [8]], modelName: "asr")
        let output = RecordingManager.reprocessingSpeakerEvidence(raw,
            turns: [.init(speakerId: "Speaker 1", start: 0, end: 2)], embeddings: ["Speaker 1": [1], "unused": [7]])
        let saved = try JSONDecoder().decode(TranscriptionResult.self, from: JSONEncoder().encode(output))
        #expect(saved.text == raw.text)
        #expect(saved.segments.map(\.text) == raw.segments.map(\.text))
        #expect(saved.segments.map(\.start) == raw.segments.map(\.start))
        #expect(saved.segments.map(\.end) == raw.segments.map(\.end))
        #expect(saved.segments[0].words?.first?.word == "Hello")
        #expect(saved.segments[0].words?.first?.probability == 0.9)
        #expect(saved.segments[0].words?.first?.speaker == "Speaker 1")
        #expect(saved.segments[0].speaker == "Speaker 1")
        #expect(saved.segments[1].speaker == nil)
        #expect(saved.speakerEmbeddings == ["Speaker 1": [1]])
        #expect(saved.language == "en" && saved.modelName == "asr")
        #expect(saved.warnings == ["kept"] && saved.inferenceTime == 2)
        #expect(saved.diarizationTime == nil)
        let empty = RecordingManager.reprocessingSpeakerEvidence(raw,
            turns: [.init(speakerId: "Speaker 1", start: 0, end: 2)], embeddings: [:])
        #expect(empty.speakerEmbeddings?.isEmpty == true)
    }
}
