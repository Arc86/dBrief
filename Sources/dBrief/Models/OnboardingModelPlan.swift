import Foundation

/// Models onboarding must prepare for transcription, analysis and transcript chat.
enum OnboardingModelPlan {
    static func requiredModels(
        transcription: AppSettings.TranscriptionEngine,
        ai: AppSettings.AIEngine,
        chatFallback: AppSettings.AIEngine
    ) -> [LocalModelKind] {
        var models: [LocalModelKind] = []
        switch transcription {
        case .localWhisper: models.append(.whisper)
        case .parakeetLocal: models.append(.parakeet)
        case .appleSpeech, .remoteEndpoint: break
        }
        if ai == .qwenLocal || (ai == .localCLI && chatFallback == .qwenLocal) {
            models.append(.gemma)
        }
        return models
    }

    static func pendingModels(
        required: [LocalModelKind],
        cached: [LocalModelKind: Bool],
        phases: [LocalModelKind: ModelDownloadPhase]
    ) -> [LocalModelKind] {
        required.filter { kind in
            // Files in the cache alone do not establish successful preparation.
            guard phases[kind] == nil || phases[kind] == .idle else { return true }
            return cached[kind] != true
        }
    }
}
