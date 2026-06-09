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
        case .idle, .transcribing, .newSegments, .diarizing, .analyzing:
            return nil
        }
    }
}

extension DownloadStage {
    /// Short user-facing label for the inline progress row.
    var downloadLabel: String {
        switch self {
        case .whisperModel, .llmModel, .parakeetModel:
            return "Downloading…"
        case .whisperModelLoading, .parakeetModelLoading:
            return "Loading…"
        case .speakerKitModel:
            return "Downloading speakers…"
        }
    }
}

/// One row in the "Need some help?" engine comparison.
struct EngineGuideEntry: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}

/// Static guidance shown in the transcription settings disclosure.
enum TranscriptionEngineGuide {
    static let entries: [EngineGuideEntry] = [
        EngineGuideEntry(title: "Whisper Large v3 Turbo",
                         detail: "Recommended. Multilingual and fast on Apple Silicon."),
        EngineGuideEntry(title: "Whisper Tiny",
                         detail: "Low memory, runs anywhere, but less accurate."),
        EngineGuideEntry(title: "Whisper Distil",
                         detail: "English-only, fast, smaller download."),
        EngineGuideEntry(title: "Parakeet",
                         detail: "Strong on clear, low-jargon speech. No diarization or language selection."),
        EngineGuideEntry(title: "Apple Speech",
                         detail: "Built in, no download. Lower quality than Whisper."),
        EngineGuideEntry(title: "Remote",
                         detail: "Bring your own Whisper server or API endpoint."),
    ]
}
