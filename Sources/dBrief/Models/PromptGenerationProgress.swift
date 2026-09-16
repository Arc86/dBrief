import dBriefWire

/// Progress belongs to an individual prompt request, never the shared download stream.
enum PromptGenerationProgress: Equatable, Sendable {
    case preparingModel
    case downloadingModel(Double?)
    case loadingModel
    case generating

    static func initial(for configuration: PromptExecutionConfiguration) -> Self {
        configuration == .localModel ? .preparingModel : .generating
    }

    static func from(_ state: LocalAIPluginState) -> Self? {
        switch state {
        case .analyzing: return .generating
        case .downloading(_, .llmModelPreparing): return .preparingModel
        case .downloading(let fraction, .llmModel):
            let progress = fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
            return .downloadingModel(progress)
        case .downloading(_, .llmModelLoading): return .loadingModel
        default: return nil
        }
    }
}
