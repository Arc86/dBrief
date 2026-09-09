import Foundation
import dBriefWire

extension ProcessingPipeline {
    enum AnalysisField: String, Sendable, CaseIterable { case summary, actionItems, tags }
    struct AnalysisRequest: Sendable {
        var transcription: TranscriptionResult
        var speakerNames: [String: String]
        var participants: [String]
        var calendarEvent: CalendarEvent?
        var engine: AppSettings.AIEngine
        var endpoint: Endpoint?
        var fields: Set<AnalysisField>
        var outputLanguage: OutputLanguage
        var vocabulary: String
        var guidance: InsightsGuidance
        var localCLIConfig: LocalCLIConfig
        var appleUnavailableReason: String?

        /// Request identity used for generation, separate from friendly labels.
        /// A free-form CLI command does not disclose a trustworthy model identity.
        var modelName: String? {
            switch engine {
            case .appleIntelligence: return "Apple Intelligence"
            case .qwenLocal: return "gemma-4-e4b-4bit (MLX)"
            case .localCLI: return nil
            case .remoteEndpoint:
                guard let name = endpoint?.modelName, !name.isEmpty else { return nil }
                return name
            }
        }
    }
    struct RemoteAnalysisRequest: Sendable {
        let transcription: String
        let endpoint: Endpoint
        let systemPrompt: String
    }
    struct UnifiedAnalysisRequest: Sendable {
        let engine: AppSettings.AIEngine
        let transcription: String
        let outputLanguage: OutputLanguage
        let vocabulary: String
        let guidance: InsightsGuidance
        let localCLIConfig: LocalCLIConfig
    }
    struct AnalysisOutput: Sendable {
        var summary: String?
        var actionItems: [String]?
        var tags: [String]?
        var sentiment: String?
        var titleConcept: String?
        var failures: [AnalysisField: String] = [:]
        var duration: TimeInterval?
        var modelDisplayName: String?
    }
    enum AnalysisEvent: Sendable, Equatable {
        case summary(String), actionItems([String]), tags([String], String)
        case titleConcept(String), failed(AnalysisField, String), liveText(String)
    }
    struct AnalysisBackends: Sendable {
        var summary: @Sendable (RemoteAnalysisRequest) async throws -> String = { _ in throw AIServiceError.invalidEndpoint }
        var actionItems: @Sendable (RemoteAnalysisRequest) async throws -> [String] = { _ in throw AIServiceError.invalidEndpoint }
        var tags: @Sendable (RemoteAnalysisRequest) async throws -> AIService.TagsResult = { _ in throw AIServiceError.invalidEndpoint }
        var unified: @Sendable (UnifiedAnalysisRequest) async throws -> LocalInsightsResult = { _ in throw AIServiceError.invalidEndpoint }
        var stream: @Sendable (UnifiedAnalysisRequest) async throws -> AsyncThrowingStream<String, Error> = { _ in throw AIServiceError.invalidEndpoint }

        static func live(ai: AIService, plugin: LocalAIPluginService, cli: LocalCLIService) -> Self {
            .init(summary: { try await ai.generateSummary(transcription: $0.transcription, endpoint: $0.endpoint, systemPrompt: $0.systemPrompt) },
                  actionItems: { try await ai.extractActionItems(transcription: $0.transcription, endpoint: $0.endpoint, systemPrompt: $0.systemPrompt) },
                  tags: { try await ai.analyzeTags(transcription: $0.transcription, endpoint: $0.endpoint, systemPrompt: $0.systemPrompt) },
                  unified: { input in
                      if input.engine == .localCLI {
                          return try await cli.analyze(transcript: input.transcription, outputLanguage: input.outputLanguage,
                              config: input.localCLIConfig, customVocabulary: input.vocabulary,
                              summaryGuidance: input.guidance.summary, actionItemsGuidance: input.guidance.actionItems,
                              tagsGuidance: input.guidance.tags)
                      }
                      #if canImport(FoundationModels)
                      if #available(macOS 26, *) {
                          return try await LocalAIService().analyzeTranscript(input.transcription, outputLanguage: input.outputLanguage,
                              customVocabulary: input.vocabulary, summaryGuidance: input.guidance.summary,
                              actionItemsGuidance: input.guidance.actionItems, tagsGuidance: input.guidance.tags)
                      }
                      #endif
                      throw AIServiceError.invalidEndpoint // Availability is reported before routing here.
                  }, stream: { input in
                      await plugin.analyzeTranscriptStream(input.transcription, outputLanguage: input.outputLanguage,
                                                           customVocabulary: input.vocabulary, guidance: input.guidance)
                  })
        }
    }

    /// Shared by normal/review-resumed processing and AI retry. Backend errors are
    /// field outcomes; cancellation exits the stage before another call or event.
    func analyze(_ request: AnalysisRequest, using backends: AnalysisBackends,
                 onEvent: @Sendable (AnalysisEvent) async -> Void = { _ in }) async throws -> AnalysisOutput {
        try Task.checkCancellation()
        var output = AnalysisOutput(modelDisplayName: analysisModelDisplayName(for: request))
        guard !request.fields.isEmpty else { return output }
        let start = now()
        let transcription = request.transcription.textForLLM(speakerNames: request.speakerNames)
        let roster = AnalysisRoster.hint(participants: request.participants, attendees: request.calendarEvent?.attendeeNames ?? [])
        let vocabulary = UnifiedInsightsPrompt.vocabularyBlock(request.vocabulary)
        let unavailable: String? = if request.engine == .appleIntelligence {
            request.appleUnavailableReason
        } else if request.engine == .remoteEndpoint && request.endpoint == nil {
            AIServiceError.invalidEndpoint.localizedDescription
        } else { nil }
        if let unavailable {
            for field in AnalysisField.allCases where request.fields.contains(field) {
                output.failures[field] = unavailable
                try await sendAnalysisEvent(.failed(field, unavailable), to: onEvent)
            }
            return output
        }
        if request.engine == .remoteEndpoint, let endpoint = request.endpoint {
            func input(_ prompt: String?, withContext: Bool = true) -> RemoteAnalysisRequest {
                let base = prompt ?? ""
                return .init(transcription: transcription, endpoint: endpoint,
                    systemPrompt: (withContext ? CalendarEvent.augment(prompt: base, with: request.calendarEvent, roster: roster) : base) + vocabulary)
            }
            if request.fields.contains(.summary) {
                do {
                    try Task.checkCancellation()
                    let value = try await backends.summary(input(request.guidance.summary))
                    try await sendAnalysisEvent(.summary(value), to: onEvent)
                    output.summary = value
                } catch {
                    try checkAnalysisCancellation(error)
                    output.failures[.summary] = error.localizedDescription
                    try await sendAnalysisEvent(.failed(.summary, error.localizedDescription), to: onEvent)
                }
            }
            if request.fields.contains(.actionItems) {
                do {
                    try Task.checkCancellation()
                    let value = try await backends.actionItems(input(request.guidance.actionItems))
                    try await sendAnalysisEvent(.actionItems(value), to: onEvent)
                    output.actionItems = value
                } catch {
                    try checkAnalysisCancellation(error)
                    output.failures[.actionItems] = error.localizedDescription
                    try await sendAnalysisEvent(.failed(.actionItems, error.localizedDescription), to: onEvent)
                }
            }
            if request.fields.contains(.tags) {
                do {
                    try Task.checkCancellation()
                    let value = try await backends.tags(input(request.guidance.tags, withContext: false))
                    try await sendAnalysisEvent(.tags(value.tags, value.sentiment), to: onEvent)
                    output.tags = value.tags
                    output.sentiment = value.sentiment
                } catch {
                    try checkAnalysisCancellation(error)
                    output.failures[.tags] = error.localizedDescription
                    try await sendAnalysisEvent(.failed(.tags, error.localizedDescription), to: onEvent)
                }
            }
        } else {
            let input = UnifiedAnalysisRequest(engine: request.engine,
                transcription: CalendarEvent.augment(prompt: transcription, with: request.calendarEvent, roster: roster),
                outputLanguage: request.outputLanguage, vocabulary: request.vocabulary, guidance: request.guidance,
                localCLIConfig: request.localCLIConfig)
            do {
                try Task.checkCancellation()
                let insights: LocalInsightsResult
                if request.engine == .qwenLocal {
                    let stream = try await backends.stream(input)
                    try Task.checkCancellation()
                    var chunks: [String] = []
                    var lastUIUpdate = ContinuousClock.now
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        chunks.append(chunk)
                        let time = ContinuousClock.now
                        if time - lastUIUpdate >= .milliseconds(200) {
                            try await sendAnalysisEvent(.liveText(chunks.joined()), to: onEvent)
                            lastUIUpdate = time
                        }
                    }
                    let json = chunks.joined()
                    try await sendAnalysisEvent(.liveText(json), to: onEvent)
                    insights = try LocalInsightsDecoder.decodeAndNormalize(json)
                } else {
                    insights = try await backends.unified(input)
                }
                try Task.checkCancellation()
                if request.fields.contains(.summary) {
                    try await sendAnalysisEvent(.summary(insights.summary), to: onEvent)
                    output.summary = insights.summary
                }
                try await sendAnalysisEvent(.titleConcept(insights.titleConcept), to: onEvent)
                output.titleConcept = insights.titleConcept
                if request.fields.contains(.actionItems) {
                    try await sendAnalysisEvent(.actionItems(insights.actionItems), to: onEvent)
                    output.actionItems = insights.actionItems
                }
                if request.fields.contains(.tags) {
                    try await sendAnalysisEvent(.tags(insights.tags, insights.sentiment), to: onEvent)
                    output.tags = insights.tags
                    output.sentiment = insights.sentiment
                }
            } catch {
                try checkAnalysisCancellation(error)
                for field in AnalysisField.allCases where request.fields.contains(field) {
                    output.failures[field] = error.localizedDescription
                    try await sendAnalysisEvent(.failed(field, error.localizedDescription), to: onEvent)
                }
            }
        }
        try Task.checkCancellation()
        if output.summary != nil || output.actionItems != nil || output.tags != nil {
            output.duration = now().timeIntervalSince(start)
        }
        return output
    }

    private func sendAnalysisEvent(_ event: AnalysisEvent, to callback: @Sendable (AnalysisEvent) async -> Void) async throws {
        try Task.checkCancellation()
        await callback(event)
        try Task.checkCancellation()
    }

    private func checkAnalysisCancellation(_ error: Error) throws {
        try Task.checkCancellation()
        if error is CancellationError { throw error }
    }

    private func analysisModelDisplayName(for request: AnalysisRequest) -> String {
        switch request.engine {
        case .appleIntelligence: return "Apple Intelligence"
        case .qwenLocal: return "Gemma 4 E4B Local"
        case .localCLI: return "Local CLI"
        case .remoteEndpoint:
            let name = request.endpoint?.modelName.trimmingCharacters(in: .whitespaces) ?? ""
            return name.isEmpty ? "Remote Endpoint" : name
        }
    }

}
