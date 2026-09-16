import Foundation
import dBriefWire

/// Uses only the shared analysis transformation, never recording jobs or persistence.
actor PromptPreviewService: PromptPreviewing {
    private let backends: ProcessingPipeline.AnalysisBackends
    private let completion: any PromptTextCompleting
    init(backends: ProcessingPipeline.AnalysisBackends, completion: any PromptTextCompleting) {
        self.backends = backends; self.completion = completion
    }
    func run(_ request: PromptPreviewRequest) async throws -> PromptPreviewOutput {
        try await PrivacyTrace.$context.withValue(nil) { try await generate(request) }
    }
    private func generate(_ request: PromptPreviewRequest) async throws -> PromptPreviewOutput {
        try Task.checkCancellation()
        guard !request.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PromptPreferencesError.emptyPrompt }
        if request.identity.kind == .spokenSummary {
            guard let summary = request.sample.summary, !summary.isEmpty else { throw PromptPreviewError.missingInsights }
            let input = SpokenSummaryInput.make(summary: summary, actionItems: request.sample.actionItems ?? [],
                                                truncateForAppleIntelligence: request.configuration == .appleIntelligence)
            let text = try await completion.complete(systemPrompt: request.draftText, userMessage: input,
                                                     configuration: request.configuration, stage: .spokenSummaryScript)
            try Task.checkCancellation()
            let script = SpokenSummaryScript.clean(text)
            guard !script.isEmpty else { throw PromptPreviewError.failed("The AI returned an empty script.") }
            return .spokenScript(script)
        }
        guard request.identity.kind != .voiceStyle else { throw PromptPreviewError.unsupportedVoice }
        guard !request.sample.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PromptPreviewError.emptyTranscript }
        let engine: AppSettings.AIEngine
        var endpoint: Endpoint?
        var cli = LocalCLIConfig.default
        switch request.configuration {
        case .appleIntelligence: engine = .appleIntelligence
        case .localModel: engine = .qwenLocal
        case .remote(let value): engine = .remoteEndpoint; endpoint = value
        case .localCLI(let value): engine = .localCLI; cli = value
        }
        let field: ProcessingPipeline.AnalysisField = switch request.identity.kind {
        case .summary: .summary
        case .actionItems: .actionItems
        default: .tags
        }
        let input = ProcessingPipeline.AnalysisRequest(
            transcription: .init(text: request.sample.transcript, segments: [], language: nil), speakerNames: [:],
            participants: request.sample.participants, calendarEvent: request.sample.calendarEvent,
            engine: engine, endpoint: endpoint, fields: [field], outputLanguage: request.outputLanguage,
            vocabulary: request.vocabulary, guidance: request.guidance, localCLIConfig: cli, appleUnavailableReason: nil)
        // analyze() has no file writes. Reuse its exact prompt construction and parsing.
        let result = try await ProcessingPipeline().analyze(input, using: backends)
        if let failure = result.failures[field] { throw PromptPreviewError.fromAnalysisFailure(failure) }
        switch field {
        case .summary: return .summary(result.summary ?? "")
        case .actionItems: return .actionItems(result.actionItems ?? [])
        case .tags: return .tags(result.tags ?? [], sentiment: result.sentiment ?? "")
        }
    }
}
