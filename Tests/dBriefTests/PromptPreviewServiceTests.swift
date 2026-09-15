import Foundation
import Testing
import dBriefWire
@testable import dBrief

struct PromptPreviewServiceTests {
    @Test func selectedGuidanceReplacesOnlyOneFieldAndUsesProductionAnalysis() async throws {
        let endpoint = Endpoint(name: "Test", baseURL: "https://example.invalid", modelName: "test")
        let service = PromptPreviewService(backends: .init(summary: { request in
            #expect(request.systemPrompt.contains("Draft summary"))
            #expect(request.transcription.contains("Sam"))
            return "Preview summary"
        }), completion: PreviewCompletion())
        let request = PromptPreviewRequest(identity: .init(kind: .summary, scope: .appDefaults), draftText: "Draft summary",
            sample: .example, configuration: .remote(endpoint), outputLanguage: .matchInput, vocabulary: "",
            summaryGuidance: "Saved summary", actionItemsGuidance: "Saved actions", tagsGuidance: "Saved tags")
        #expect(try await service.run(request) == .summary("Preview summary"))
        #expect(request.actionItemsGuidance == "Saved actions")
    }
    @Test func missingInsightsCannotStartSpokenGeneration() async throws {
        let service = PromptPreviewService(backends: .init(), completion: PreviewCompletion())
        let sample = PromptPreviewSample(id: UUID(), title: "No insights", transcript: "Meeting", summary: nil, actionItems: nil)
        let request = PromptPreviewRequest(identity: .init(kind: .spokenSummary, scope: .appDefaults), draftText: "Draft",
            sample: sample, configuration: .appleIntelligence, outputLanguage: .matchInput, vocabulary: "",
            summaryGuidance: "", actionItemsGuidance: "", tagsGuidance: "")
        await #expect(throws: PromptPreviewError.missingInsights) { try await service.run(request) }
    }
    @Test func spokenInputPreservesExistingFormatting() {
        #expect(SpokenSummaryInput.make(summary: "Summary", actionItems: ["Task"], truncateForAppleIntelligence: false)
                == "MEETING SUMMARY:\nSummary\n\nACTION ITEMS:\n- Task\n")
    }
}
private struct PreviewCompletion: PromptTextCompleting {
    func complete(systemPrompt: String, userMessage: String, configuration: PromptExecutionConfiguration,
                  stage: PrivacyOperation.Stage) async throws -> String { "Spoken preview" }
}

extension PromptPreviewServiceTests {
    private func request(kind: PromptKind = .summary, configuration: PromptExecutionConfiguration = .appleIntelligence,
                         transcript: String = "Short transcript", summary: String = "Saved summary", actions: [String] = []) -> PromptPreviewRequest {
        .init(identity: .init(kind: kind, scope: .appDefaults), draftText: "Draft",
              sample: .init(id: UUID(), title: "Example", transcript: transcript, summary: summary, actionItems: actions),
              configuration: configuration, outputLanguage: .matchInput, vocabulary: "",
              summaryGuidance: "Summary", actionItemsGuidance: "Actions", tagsGuidance: "Tags")
    }

    @Test func preservesKnownContextErrorsAfterPipelineFlattensThem() async {
        let messages = [AIServiceError.contextWindowExceeded.localizedDescription,
                        PromptAIError.contextLimit.localizedDescription,
                        "The transcript is too long for Apple Intelligence. Try a shorter recording or a different AI engine."]
        for message in messages {
            let service = PromptPreviewService(backends: .init(unified: { _ in throw PreviewBackendError(message: message) }), completion: PreviewCompletion())
            await #expect(throws: PromptPreviewError.contextLimit) { try await service.run(request()) }
        }
    }

    @Test func contextLookingBackendTextCannotBypassDiagnosticBoundary() async {
        let secret = "private-recording-secret"
        let messages = [secret,
                        AIServiceError.contextWindowExceeded.localizedDescription + " " + secret,
                        "context window exceeded: " + secret]
        for message in messages {
            let service = PromptPreviewService(backends: .init(unified: { _ in throw PreviewBackendError(message: message) }), completion: PreviewCompletion())
            do {
                _ = try await service.run(request())
                Issue.record("Expected analysis failure")
            } catch {
                #expect(error is PromptPreviewError)
                #expect(error as? PromptPreviewError != .contextLimit)
                #expect(!error.localizedDescription.contains(secret))
            }
        }
    }

    @Test func spokenNoticeUsesSavedInsightsIncludingActionsAndFormatting() async throws {
        let limit = UnifiedInsightsPrompt.foundationModelsCharLimit
        // The summary alone fits. The exact shared envelope and actions push it over budget.
        let preview = request(kind: .spokenSummary, summary: String(repeating: "s", count: limit - 30), actions: [String(repeating: "a", count: 100)])
        #expect(preview.sample.summary!.count < limit)
        #expect(preview.shorteningNotice != nil)
        let completion = SpokenInputProbe()
        _ = try await PromptPreviewService(backends: .init(), completion: completion).run(preview)
        let actual = try #require(await completion.input)
        #expect(actual == SpokenSummaryInput.make(summary: preview.sample.summary!, actionItems: preview.sample.actionItems!, truncateForAppleIntelligence: true))
        #expect(actual.contains(UnifiedInsightsPrompt.truncationSeparator))
    }

    @Test func spokenNoticeIgnoresTranscriptAndOnlyAppleShortensSavedInsights() {
        let long = String(repeating: "x", count: UnifiedInsightsPrompt.transcriptCharLimit + 1)
        #expect(request(kind: .spokenSummary, transcript: long).shorteningNotice == nil)
        let remote = Endpoint(name: "Test", baseURL: "https://example.invalid", modelName: "test")
        let configurations: [PromptExecutionConfiguration] = [.localModel, .remote(remote), .localCLI(.default)]
        for configuration in configurations {
            #expect(request(kind: .spokenSummary, configuration: configuration, transcript: long, summary: long).shorteningNotice == nil)
        }
        #expect(request(kind: .voiceStyle, transcript: long, summary: long).shorteningNotice == nil)
        #expect(request(transcript: long).shorteningNotice != nil)
    }
}

private struct PreviewBackendError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private actor SpokenInputProbe: PromptTextCompleting {
    var input: String?
    func complete(systemPrompt: String, userMessage: String, configuration: PromptExecutionConfiguration,
                  stage: PrivacyOperation.Stage) async throws -> String {
        input = userMessage
        return "Spoken preview"
    }
}
