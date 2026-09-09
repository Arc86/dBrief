import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Processing pipeline transcription")
struct ProcessingPipelineTests {
    @Test(arguments: [false, true])
    func singleFileKeepsEngineRequestAndAppliesCleanup(removeFillers: Bool) async throws {
        let pipeline = ProcessingPipeline(duration: { _ in Issue.record("Single-file transcription must not probe segment duration"); return 0 })
        let audio = URL(fileURLWithPath: "/synthetic/master.wav")
        let result = try await pipeline.transcribe(.init(audioURL: audio, segmentURLs: []),
            options: .init(removeFillerWords: removeFillers, ignoredSegments: []), using: { request in
                #expect(request.url == audio && request.segmentIndex == nil && request.segmentCount == nil)
                return .init(text: "um [BLANK_AUDIO] hello", segments: [], language: "en", inferenceTime: 3)
            }, onEvent: { _ in Issue.record("No segment/correction events for a plain single file") })
        #expect(result.transcription.text == (removeFillers ? "hello" : "um hello"))
        #expect(result.transcription.inferenceTime == 3)
        #expect(result.spellCorrectionTime == nil)
    }

    @Test func segmentsSortAndAccumulateOffsetsLanguageWarningsAndTimings() async throws {
        let root = URL(fileURLWithPath: "/synthetic")
        let paths = (1...4).map { root.appendingPathComponent("part\($0).wav") }
        let audit = PipelineAudit()
        let pipeline = ProcessingPipeline(duration: { $0 == paths[0] ? 10 : 0 })
        let result = try await pipeline.transcribe(.init(audioURL: root.appendingPathComponent("master.wav"), segmentURLs: Array(paths.reversed())),
            options: .init(removeFillerWords: false, ignoredSegments: []), using: { request in
                await audit.record(request)
                let n = try #require(request.segmentIndex)
                #expect(request.segmentCount == 4)
                if n == 3 { return .init(text: "", segments: []) }
                return .init(text: "part \(n)", segments: [.init(start: 0, end: n == 2 ? 7 : 1, text: "part \(n)")],
                    language: n == 1 ? "" : n == 2 ? "nl" : "en", warnings: n == 2 ? nil : ["warning"],
                    inferenceTime: n == 1 ? nil : Double(n), diarizationTime: n == 1 ? 1 : nil)
            }, onEvent: { await audit.record($0) })
        #expect(await audit.requests.map(\.url) == paths)
        #expect(await audit.events == (1...4).map { .transcribingSegment(index: $0, count: 4) })
        #expect(result.transcription.segments.map(\.start) == [0, 10, 18])
        #expect(result.transcription.language == "nl")
        #expect(result.transcription.warnings == ["Segment 1: warning", "Segment 4: warning"])
        #expect(result.transcription.inferenceTime == 6)
        #expect(result.transcription.diarizationTime == 1)
    }

    @Test func correctionReceivesCleanedTranscriptAndPreservesPrivacyContext() async throws {
        let audit = PipelineAudit()
        let clock = PipelineClock()
        let pipeline = ProcessingPipeline(now: { clock.next() })
        let context = PrivacyTrace.Context(receiptURL: URL(fileURLWithPath: "/synthetic/receipt.json"),
            store: PrivacyReceiptStore(), runID: UUID(), recordingID: UUID())
        let output = try await PrivacyTrace.$context.withValue(context) {
            try await pipeline.transcribe(.init(audioURL: URL(fileURLWithPath: "/synthetic/audio.wav"), segmentURLs: []),
                options: .init(removeFillerWords: true, ignoredSegments: ["thanks for watching"]), using: { _ in
                    #expect(PrivacyTrace.context?.runID == context.runID)
                    return .init(text: "um hello Thanks for watching", segments: [
                        .init(start: 0, end: 1, text: "um hello"), .init(start: 1, end: 2, text: "Thanks for watching")])
                }, correct: { cleaned in
                    #expect(PrivacyTrace.context?.runID == context.runID)
                    #expect(cleaned.text == "hello")
                    #expect(cleaned.segments.count == 1)
                    return .init(text: "corrected", segments: cleaned.segments)
                }, onEvent: { event in
                    #expect(PrivacyTrace.context?.recordingID == context.recordingID)
                    await audit.record(event)
                })
        }
        #expect(output.transcription.text == "corrected")
        #expect(output.spellCorrectionTime == 5)
        #expect(await audit.events == [.correctingVocabulary])
    }

    @Test func providerFailureStopsBeforeLaterSegmentsOrCorrection() async throws {
        let pipeline = ProcessingPipeline(duration: { _ in 0 }), audit = PipelineAudit()
        let operation = {
            try await pipeline.transcribe(.init(audioURL: URL(fileURLWithPath: "/master.wav"),
                segmentURLs: [URL(fileURLWithPath: "/part1.wav"), URL(fileURLWithPath: "/part2.wav")]),
                options: .init(removeFillerWords: false, ignoredSegments: []), using: { request in
                    await audit.record(request)
                    throw PipelineTestError.failure
                }, correct: { input in Issue.record("Failed transcription must not reach correction"); return input })
        }
        await #expect(throws: PipelineTestError.self) { try await operation() }
        #expect(await audit.requests.count == 1)
    }

    @Test(arguments: ["event", "provider", "duration", "correction"])
    func cancellationStopsAtAwaitedStageBoundaries(stage: String) async throws {
        let pipeline = ProcessingPipeline(duration: { _ in
            if stage == "duration" { withUnsafeCurrentTask { $0?.cancel() } }
            return 0
        }), audit = PipelineAudit()
        let operation = Task {
            try await pipeline.transcribe(.init(audioURL: URL(fileURLWithPath: "/master.wav"),
                segmentURLs: [URL(fileURLWithPath: "/part1.wav"), URL(fileURLWithPath: "/part2.wav")]),
                options: .init(removeFillerWords: false, ignoredSegments: []), using: { request in
                    await audit.record(request)
                    if stage == "provider" { withUnsafeCurrentTask { $0?.cancel() } }
                    return .init(text: "hello", segments: [])
                }, correct: { input in
                    #expect(stage == "correction")
                    withUnsafeCurrentTask { $0?.cancel() }
                    return input
                }, onEvent: { _ in
                    if stage == "event" { withUnsafeCurrentTask { $0?.cancel() } }
                })
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(await audit.requests.count == (stage == "event" ? 0 : stage == "correction" ? 2 : 1))
    }
    @Test @MainActor func actorResumesOffMainThreadAroundUIBoundCallbacks() async throws {
        let pipeline = ProcessingPipeline(now: {
            #expect(!Thread.isMainThread)
            return Date(timeIntervalSince1970: 100)
        })
        let result = try await pipeline.transcribe(.init(audioURL: URL(fileURLWithPath: "/synthetic.wav"), segmentURLs: []),
            options: .init(removeFillerWords: false, ignoredSegments: []), using: { @MainActor _ in
                MainActor.preconditionIsolated()
                return .init(text: "hello", segments: [])
            }, correct: { @MainActor value in
                MainActor.preconditionIsolated()
                return value
            })
        #expect(result.transcription.text == "hello")
        #expect(result.spellCorrectionTime == 0)
    }

    @Test func cancellationDuringSynchronousCleanupCannotReturnAPublishableTranscript() async {
        let pipeline = ProcessingPipeline(cleanup: { result, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return result
        })
        let operation = Task {
            try await pipeline.transcribe(.init(audioURL: URL(fileURLWithPath: "/synthetic.wav"), segmentURLs: []),
                options: .init(removeFillerWords: false, ignoredSegments: []),
                using: { _ in .init(text: "hello", segments: []) })
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
    }

}

private enum PipelineTestError: Error { case failure }
private actor PipelineAudit {
    private(set) var requests: [ProcessingPipeline.AudioRequest] = []
    private(set) var events: [ProcessingPipeline.Event] = []
    func record(_ request: ProcessingPipeline.AudioRequest) { requests.append(request) }
    func record(_ event: ProcessingPipeline.Event) { events.append(event) }
}
private final class PipelineClock: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var tick = 0.0
    func next() -> Date { lock.withLock { defer { tick += 5 }; return Date(timeIntervalSince1970: tick) } }
}
