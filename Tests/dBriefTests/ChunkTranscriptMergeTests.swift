import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Chunk transcript boundary preservation")
struct ChunkTranscriptMergeTests {
    @Test("Repeated speech after a shortened overlap is preserved in text and segments")
    func repeatedSpeech() async throws {
        let first = TranscriptionResult(text: "Yes that works", segments: [.init(start: 0.7, end: 1, text: "Yes that works")])
        let next = TranscriptionResult(text: "Yes that works", segments: [.init(start: 0.2, end: 0.5, text: "Yes that works")])
        let result = try await TranscriptionService().mergeChunkOutcomes([
            .success(chunk(0, start: 0, end: 2), first),
            .success(chunk(1, start: 1.6, end: 3.6), next),
        ])
        #expect(result.text == "Yes that works Yes that works")
        #expect(result.segments.count == 2)
        #expect(result.segments.last?.start == 1.8)
    }

    @Test("Repeated speech within one chunk is never treated as a boundary duplicate")
    func sameChunkRepetition() async throws {
        let transcript = TranscriptionResult(text: "Yes Yes", segments: [
            .init(start: 0, end: 0.3, text: "Yes"), .init(start: 0.5, end: 0.8, text: "Yes"),
        ])
        let result = try await TranscriptionService().mergeChunkOutcomes([
            .success(chunk(0, start: 0, end: 2), transcript),
        ])
        #expect(result.text == "Yes Yes")
        #expect(result.segments.count == 2)
    }

    @Test("The same utterance returned by both overlapping chunks is included once")
    func actualDuplicate() async throws {
        let first = TranscriptionResult(text: "Yes", segments: [.init(start: 1.7, end: 1.9, text: "Yes")])
        let next = TranscriptionResult(text: "Yes Next", segments: [
            .init(start: 0.1, end: 0.3, text: "Yes"), .init(start: 0.8, end: 1, text: "Next"),
        ])
        let result = try await TranscriptionService().mergeChunkOutcomes([
            .success(chunk(0, start: 0, end: 2), first),
            .success(chunk(1, start: 1.6, end: 3.6), next),
        ])
        #expect(result.text == "Yes Next")
        #expect(result.segments.map(\.text) == ["Yes", "Next"])
    }

    @Test("A failed chunk leaves a gap and cannot cause text deduplication across it")
    func failedGap() async throws {
        let transcript = TranscriptionResult(text: "Yes that works", segments: [.init(start: 0, end: 0.5, text: "Yes that works")])
        let result = try await TranscriptionService().mergeChunkOutcomes([
            .success(chunk(0, start: 0, end: 2), transcript),
            .failed(chunk(1, start: 1.6, end: 3.6), "fixture failure"),
            .success(chunk(2, start: 3.2, end: 5.2), transcript),
        ])
        #expect(result.text == "Yes that works Yes that works")
        #expect(result.segments.count == 2)
        #expect(result.warnings?.count == 1)
    }

    private func chunk(_ index: Int, start: Double, end: Double) -> AudioChunk {
        AudioChunk(index: index, startSeconds: start, endSeconds: end, url: URL(fileURLWithPath: "/unused-\(index).m4a"))
    }
}
