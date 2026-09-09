import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Processing transcript persistence")
struct ProcessingTranscriptPersistenceTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private var transcript: TranscriptionResult {
        .init(text: "hello", segments: [.init(start: 1, end: 2, text: "hello",
            words: [.init(word: "hello", start: 1, end: 2, probability: 0.9, speaker: "Speaker 1")], speaker: "Speaker 1")],
            language: "en", warnings: ["test warning"], speakerCount: 1, inferenceTime: 3, diarizationTime: 4,
            speakerEmbeddings: ["Speaker 1": [1, 0, 0]])
    }

    @Test func atomicWriteRoundTripsAllTranscriptEvidence() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("recording.transcript.json")
        let pipeline = ProcessingPipeline()
        try await pipeline.saveTranscript(transcript, to: url)
        let saved = try #require(try await pipeline.loadTranscript(from: url))
        #expect(saved.text == "hello" && saved.language == "en")
        #expect(saved.segments.first?.start == 1 && saved.segments.first?.words?.first?.end == 2)
        #expect(saved.segments.first?.words?.first?.speaker == "Speaker 1")
        #expect(saved.warnings == transcript.warnings && saved.speakerCount == 1)
        #expect(saved.inferenceTime == 3 && saved.diarizationTime == 4)
        #expect(saved.speakerEmbeddings == transcript.speakerEmbeddings)
    }

    @Test func absentAndCorruptLoadsRemainOptionalAndLeaveFilesUntouched() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = ProcessingPipeline()
        let missing = root.appendingPathComponent("missing.json")
        #expect(try await pipeline.loadTranscript(from: missing) == nil)
        #expect(try await pipeline.loadTranscript(from: nil) == nil)
        let corrupt = root.appendingPathComponent("corrupt.json")
        let data = Data("unreadable transcript".utf8)
        try data.write(to: corrupt)
        #expect(try await pipeline.loadTranscript(from: corrupt) == nil)
        #expect(try Data(contentsOf: corrupt) == data)
        await #expect(throws: ProcessingPipeline.TranscriptPersistenceError.self) {
            try await pipeline.saveTranscript(transcript, to: nil)
        }
    }

    @Test func verificationRejectsAlteredTimingEvenWhenTextAndSegmentCountMatch() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("recording.json")
        let changed = TranscriptionResult(text: "hello", segments: [.init(start: 100, end: 200, text: "hello")])
        let pipeline = ProcessingPipeline(transcriptFiles: .init(write: { _, target in
            try JSONEncoder().encode(changed).write(to: target, options: .atomic)
        }))
        await #expect(throws: ProcessingPipeline.TranscriptPersistenceError.self) {
            try await pipeline.saveTranscript(transcript, to: url)
        }
    }

    @Test func writeFailureDoesNotAcknowledgeOrReplaceExistingTranscript() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("recording.json")
        let original = try JSONEncoder().encode(transcript)
        try original.write(to: url)
        let pipeline = ProcessingPipeline(transcriptFiles: .init(write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }))
        await #expect(throws: CocoaError.self) { try await pipeline.saveTranscript(.init(text: "replacement", segments: []), to: url) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func cancellationDuringWriteRetainsAtomicFileButDoesNotAcknowledgeCheckpoint() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("recording.json")
        let pipeline = ProcessingPipeline(transcriptFiles: .init(write: { bytes, target in
            try bytes.write(to: target, options: .atomic)
            withUnsafeCurrentTask { $0?.cancel() }
        }))
        let result = transcript
        let operation = Task { try await pipeline.saveTranscript(result, to: url) }
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(try JSONDecoder().decode(TranscriptionResult.self, from: Data(contentsOf: url)).text == "hello")
    }

    @Test @MainActor func fileReadsAndWritesExecuteOffMainThread() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("recording.json")
        let pipeline = ProcessingPipeline(transcriptFiles: .init(read: { source in
            #expect(!Thread.isMainThread)
            return try Data(contentsOf: source)
        }, write: { bytes, target in
            #expect(!Thread.isMainThread)
            try bytes.write(to: target, options: .atomic)
        }))
        try await pipeline.saveTranscript(transcript, to: url)
        #expect(try await pipeline.loadTranscript(from: url)?.text == "hello")
    }
    @Test(arguments: ["load", "save"])
    func alreadyCancelledPersistenceNeverTouchesFiles(operation: String) async {
        let pipeline = ProcessingPipeline(transcriptFiles: .init(read: { _ in
            Issue.record("Cancelled load must not read")
            return Data()
        }, write: { _, _ in Issue.record("Cancelled save must not write") },
        changed: { Issue.record("Cancelled work must not announce a change before touching storage") }))
        let result = transcript
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let url = URL(fileURLWithPath: "/synthetic/transcript.json")
            if operation == "save" { try await pipeline.saveTranscript(result, to: url) }
            else { _ = try await pipeline.loadTranscript(from: url) }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancelledReadDoesNotMasqueradeAsMissingOrReturnAStaleTranscript() async throws {
        let bytes = try JSONEncoder().encode(transcript)
        let pipeline = ProcessingPipeline(transcriptFiles: .init(read: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return bytes
        }))
        let task = Task { try await pipeline.loadTranscript(from: URL(fileURLWithPath: "/synthetic/transcript.json")) }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

}
