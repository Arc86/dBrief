import Foundation
import dBriefWire

/// The three local models that can be explicitly downloaded from Settings.
enum LocalModelKind: Hashable, Sendable, CaseIterable {
    case whisper
    case parakeet
    case gemma
}

/// UI-facing download state for a single local model.
enum ModelDownloadPhase: Equatable, Sendable {
    case idle
    /// `progress == nil` means indeterminate (e.g. compiling/loading a cached model).
    case downloading(progress: Double?, label: String)
    case failed(String)

    /// Pure mapping from a service `LocalAIPluginState` to a download phase.
    /// Returns `nil` for states that are not download progress (the caller
    /// should leave the current phase unchanged).
    static func from(pluginState state: LocalAIPluginState) -> ModelDownloadPhase? {
        switch state {
        case .downloading(let progress, let stage):
            return .downloading(progress: progress, label: stage.downloadLabel)
        case .idle, .transcribing, .newSegments, .diarizing, .analyzing, .analyzingPart:
            return nil
        }
    }
}

extension DownloadStage {
    /// Short user-facing label for the inline progress row.
    var downloadLabel: String {
        switch self {
        case .whisperModel, .llmModel, .parakeetModel, .ttsModel, .kokoroTTSModel:
            return "Downloading…"
        case .llmModelPreparing:
            return "Preparing…"
        case .llmModelLoading, .whisperModelLoading, .parakeetModelLoading, .ttsModelLoading, .kokoroTTSModelLoading:
            return "Loading…"
        case .speakerKitModel:
            return "Downloading speakers…"
        case .embeddingModel:
            return "Downloading search model…"
        }
    }
}
