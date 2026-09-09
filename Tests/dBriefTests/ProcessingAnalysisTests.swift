import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Processing analysis")
struct ProcessingAnalysisTests {
    private func request(engine: AppSettings.AIEngine = .remoteEndpoint,
                         fields: Set<ProcessingPipeline.AnalysisField> = [.summary, .actionItems, .tags]) -> ProcessingPipeline.AnalysisRequest {
        .init(transcription: .init(text: "We agreed", segments: [.init(start: 0, end: 1, text: "We agreed", speaker: "Speaker 1")]),
              speakerNames: ["Speaker 1": "Alice"], participants: ["Alice", "Bob"], calendarEvent: nil,
              engine: engine, endpoint: .init(name: "Fixture", baseURL: "https://synthetic.invalid", modelName: "fixture"),
              fields: fields, outputLanguage: .matchInput, vocabulary: "dBrief", guidance: .init(summary: "SUMMARY", actionItems: "ACTIONS", tags: "TAGS"),
              localCLIConfig: .default, appleUnavailableReason: nil)
    }
    private var unified: LocalInsightsResult {
        .init(titleConcept: "Plan agreed", summary: "Summary", actionItems: ["Do it"], tags: ["planning"], sentiment: "Positive")
    }
    private actor Events {
        var values: [ProcessingPipeline.AnalysisEvent] = []
        func add(_ event: ProcessingPipeline.AnalysisEvent) { values.append(event) }
    }

    @Test func remoteCallsUseReviewedNamesAndVocabularyAndContinueAfterFieldFailure() async throws {
        let events = Events()
        #expect(request().modelName == "fixture")
        #expect(request(engine: .localCLI).modelName == nil)
        let backends = ProcessingPipeline.AnalysisBackends(summary: { input in
            #expect(input.transcription.contains("Alice"))
            #expect(input.systemPrompt.contains("SUMMARY") && input.systemPrompt.contains("dBrief"))
            throw CocoaError(.fileReadUnknown)
        }, actionItems: { input in
            #expect(input.systemPrompt.contains("ACTIONS") && input.systemPrompt.contains("Alice"))
            return ["Do it"]
        }, tags: { input in
            #expect(input.systemPrompt.contains("TAGS") && input.systemPrompt.contains("dBrief"))
            #expect(!input.systemPrompt.contains("Alice"))
            return .init(tags: ["planning"], sentiment: "Positive")
        })
        let output = try await ProcessingPipeline().analyze(request(), using: backends, onEvent: { await events.add($0) })
        #expect(output.summary == nil && output.failures[.summary] != nil)
        #expect(output.actionItems == ["Do it"] && output.tags == ["planning"] && output.sentiment == "Positive")
        #expect(output.duration != nil)
        #expect(output.modelDisplayName == "fixture")
        let values = await events.values
        #expect(values.count == 3)
        #expect(values.dropFirst() == [.actionItems(["Do it"]), .tags(["planning"], "Positive")])
    }

    @Test(arguments: [AppSettings.AIEngine.appleIntelligence, .localCLI])
    func unifiedEnginesRespectRequestedFieldsAndKeepInlineTitle(engine: AppSettings.AIEngine) async throws {
        let result = unified
        let backends = ProcessingPipeline.AnalysisBackends(unified: { input in
            #expect(input.engine == engine)
            #expect(input.transcription.contains("Alice") && input.transcription.contains("Bob"))
            #expect(input.vocabulary == "dBrief" && input.guidance.summary == "SUMMARY")
            return result
        })
        let output = try await ProcessingPipeline().analyze(request(engine: engine, fields: [.actionItems]), using: backends)
        #expect(output.summary == nil && output.tags == nil && output.sentiment == nil)
        #expect(output.actionItems == ["Do it"] && output.titleConcept == "Plan agreed")
        #expect(output.modelDisplayName == (engine == .localCLI ? "Local CLI" : "Apple Intelligence"))
    }

    @Test func streamedJSONIsJoinedDecodedAndPublishedWithFinalSnapshot() async throws {
        let events = Events()
        let json = String(decoding: try JSONEncoder().encode(unified), as: UTF8.self)
        let backends = ProcessingPipeline.AnalysisBackends(stream: { _ in
            AsyncThrowingStream { continuation in
                for character in json { continuation.yield(String(character)) }
                continuation.finish()
            }
        })
        let result = try await ProcessingPipeline().analyze(request(engine: .qwenLocal), using: backends, onEvent: { await events.add($0) })
        #expect(result.summary == "Summary" && result.actionItems == ["Do it"])
        #expect(await events.values.contains(.liveText(json)))
    }

    @Test func unavailableOrUnrequestedAnalysisNeverCallsBackend() async throws {
        let backends = ProcessingPipeline.AnalysisBackends(summary: { _ in Issue.record("Unexpected remote call"); return "" },
            unified: { _ in Issue.record("Unexpected unified call"); return unified })
        let pipeline = ProcessingPipeline()
        let empty = try await pipeline.analyze(request(fields: []), using: backends)
        #expect(empty.duration == nil && empty.failures.isEmpty)
        var apple = request(engine: .appleIntelligence)
        apple.appleUnavailableReason = "Unavailable fixture"
        let unavailable = try await pipeline.analyze(apple, using: backends)
        #expect(unavailable.failures.count == 3 && unavailable.duration == nil)
        var remote = request()
        remote.endpoint = nil
        #expect(try await pipeline.analyze(remote, using: backends).failures.count == 3)
    }

    @Test func cancellationAfterBackendOrEventPreventsLaterRemoteCalls() async throws {
        for cancelInEvent in [false, true] {
            let backends = ProcessingPipeline.AnalysisBackends(summary: { _ in
                if !cancelInEvent { withUnsafeCurrentTask { $0?.cancel() } }
                return "Summary"
            }, actionItems: { _ in Issue.record("Cancelled analysis called the next backend"); return [] })
            let input = request()
            let task = Task {
                try await ProcessingPipeline().analyze(input, using: backends, onEvent: { _ in
                    if cancelInEvent { withUnsafeCurrentTask { $0?.cancel() } }
                    else { Issue.record("Cancelled backend published a result") }
                })
            }
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        }
    }

    @Test func malformedStreamFailsAllSelectedFieldsWithoutPartialOutput() async throws {
        let backends = ProcessingPipeline.AnalysisBackends(stream: { _ in
            AsyncThrowingStream { $0.yield("not JSON"); $0.finish() }
        })
        let output = try await ProcessingPipeline().analyze(request(engine: .qwenLocal), using: backends)
        #expect(output.failures.count == 3 && output.summary == nil && output.duration == nil)
    }
    @Test @MainActor func actorWorkAndBackendEventsKeepTheOriginatingPrivacyScope() async throws {
        let context = PrivacyTrace.Context(receiptURL: URL(fileURLWithPath: "/synthetic/analysis.privacy.json"), recordingID: UUID())
        let pipeline = ProcessingPipeline(now: {
            #expect(!Thread.isMainThread)
            #expect(PrivacyTrace.context?.runID == context.runID)
            return Date()
        })
        let backends = ProcessingPipeline.AnalysisBackends(summary: { _ in
            #expect(PrivacyTrace.context?.runID == context.runID)
            return "Summary"
        })
        let input = request(fields: [.summary])
        let result = try await PrivacyTrace.$context.withValue(context) {
            try await pipeline.analyze(input, using: backends, onEvent: { @MainActor event in
                MainActor.preconditionIsolated()
                #expect(PrivacyTrace.context?.recordingID == context.recordingID)
                #expect(event == .summary("Summary"))
            })
        }
        #expect(result.summary == "Summary" && result.duration != nil)
    }

    @Test(arguments: ["beforeStart", "streamSnapshot", "backendCancellation"])
    func cancellationNeverAdvancesTheAnalysisStage(boundary: String) async throws {
        let result = unified
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        let backends = ProcessingPipeline.AnalysisBackends(summary: { _ in
            if boundary != "backendCancellation" { Issue.record("Pre-cancelled work called a backend") }
            throw CancellationError()
        }, actionItems: { _ in Issue.record("Backend cancellation must stop subsequent fields"); return [] }, stream: { _ in
            AsyncThrowingStream { $0.yield(json); $0.finish() }
        })
        let input = request(engine: boundary == "streamSnapshot" ? .qwenLocal : .remoteEndpoint)
        let task = Task {
            if boundary == "beforeStart" { withUnsafeCurrentTask { $0?.cancel() } }
            return try await ProcessingPipeline().analyze(input, using: backends, onEvent: { event in
                if boundary == "streamSnapshot", case .liveText = event {
                    withUnsafeCurrentTask { $0?.cancel() }
                } else { Issue.record("Cancelled analysis emitted a result or failure event") }
            })
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

}
