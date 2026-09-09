import Foundation
import Testing
@testable import dBrief

@Suite("Processing diagnostics")
struct ProcessingDiagnosticsTests {
    private func journal() -> DurabilityJournal {
        DurabilityJournal(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("processing-diagnostics-\(UUID())"))
    }

    @Test @MainActor func typedEventsPersistOffMainWithOnlyAggregateFacts() async throws {
        let journal = journal()
        defer { try? FileManager.default.removeItem(at: journal.journalURL.deletingLastPathComponent()) }
        let recordingID = UUID()
        let timestamp = Date(timeIntervalSince1970: 100)
        let pipeline = ProcessingPipeline(now: { timestamp })
        let write: @Sendable (DurabilityEvent) -> Void = {
            #expect(!Thread.isMainThread)
            journal.record($0)
        }
        await pipeline.recordProcessingDiagnostic(.started(transcribe: true, summary: false, actionItems: true, tags: false),
                                                   recordingID: recordingID, record: write)
        let error = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [
            NSLocalizedDescriptionKey: "private meeting text", NSFilePathErrorKey: "/private/recording.m4a",
            "token": "secret-value"
        ])
        await pipeline.recordProcessingDiagnostic(.transcriptionFailed(.init(error: error)), recordingID: recordingID, record: write)
        await pipeline.recordProcessingDiagnostic(.completed(stepCount: 5, failedStepCount: 2), recordingID: recordingID, record: write)
        let events = journal.recentEvents()
        #expect(events.map(\.name) == ["processing_started", "transcription", "processing_completed"])
        #expect(events.map(\.outcome) == [.started, .failed, .warning])
        #expect(events.allSatisfy { $0.sessionID == recordingID && $0.timestamp == timestamp })
        #expect(events.first?.measurements == ["transcriptionRequested": 1, "summaryRequested": 0,
                                                "actionItemsRequested": 1, "tagsRequested": 0])
        #expect(events[1].failure == .init(error: error))
        #expect(events[1].measurements.isEmpty)
        #expect(events.last?.measurements == ["stepCount": 5, "failedStepCount": 2])
        let bytes = try String(contentsOf: journal.journalURL, encoding: .utf8)
        for forbidden in ["private meeting text", "/private/recording.m4a", "secret-value"] {
            #expect(!bytes.contains(forbidden))
        }
    }

    @Test func successfulCompletionHasNoFailureFingerprint() async throws {
        let journal = journal()
        defer { try? FileManager.default.removeItem(at: journal.journalURL.deletingLastPathComponent()) }
        await ProcessingPipeline().recordProcessingDiagnostic(.completed(stepCount: 3, failedStepCount: 0),
                                                               recordingID: UUID(), record: { journal.record($0) })
        let event = try #require(journal.recentEvents().first)
        #expect(event.outcome == .succeeded)
        #expect(event.failure == nil)
        #expect(event.measurements == ["stepCount": 3, "failedStepCount": 0])
    }

    @Test @MainActor func cancelledCallerStillRecordsCapturedSessionWithPrivacyContext() async throws {
        let journal = journal()
        defer { try? FileManager.default.removeItem(at: journal.journalURL.deletingLastPathComponent()) }
        let recordingID = UUID()
        let context = PrivacyTrace.Context(receiptURL: journal.journalURL.deletingLastPathComponent()
            .appendingPathComponent("receipt.privacy.json"), recordingID: recordingID)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await PrivacyTrace.$context.withValue(context) {
                await ProcessingPipeline().recordProcessingDiagnostic(.completed(stepCount: 1, failedStepCount: 0),
                    recordingID: recordingID, record: {
                        #expect(!Thread.isMainThread)
                        #expect(Task.isCancelled)
                        #expect(PrivacyTrace.context?.runID == context.runID)
                        journal.record($0)
                    })
            }
        }
        await task.value
        #expect(journal.recentEvents().map(\.sessionID) == [recordingID])
    }
}
