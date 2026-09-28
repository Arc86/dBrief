import Testing
@testable import dBrief

@Suite("Onboarding model preparation")
struct OnboardingModelPlanTests {
    @Test("prepares only the selected transcription model and local AI")
    func selectedModels() {
        #expect(OnboardingModelPlan.requiredModels(transcription: .localWhisper, ai: .qwenLocal, chatFallback: .appleIntelligence) == [.whisper, .gemma])
        #expect(OnboardingModelPlan.requiredModels(transcription: .parakeetLocal, ai: .appleIntelligence, chatFallback: .qwenLocal) == [.parakeet])
        #expect(OnboardingModelPlan.requiredModels(transcription: .remoteEndpoint, ai: .remoteEndpoint, chatFallback: .qwenLocal).isEmpty)
    }

    @Test("includes the local chat model when analysis uses a CLI")
    func cliChatFallback() {
        #expect(OnboardingModelPlan.requiredModels(transcription: .appleSpeech, ai: .localCLI, chatFallback: .qwenLocal) == [.gemma])
        #expect(OnboardingModelPlan.requiredModels(transcription: .appleSpeech, ai: .localCLI, chatFallback: .remoteEndpoint).isEmpty)
    }

    @Test("cached models are ready but an active download must finish preparation")
    func pendingModels() {
        #expect(OnboardingModelPlan.pendingModels(required: [.whisper, .gemma], cached: [.whisper: true], phases: [:]) == [.gemma])
        #expect(OnboardingModelPlan.pendingModels(required: [.whisper], cached: [.whisper: true], phases: [.whisper: .downloading(progress: nil, label: "Loading…")]) == [.whisper])
        #expect(OnboardingModelPlan.pendingModels(required: [.gemma], cached: [.gemma: true], phases: [.gemma: .failed("Load failed")]) == [.gemma])
        #expect(OnboardingModelPlan.pendingModels(required: [.whisper, .gemma], cached: [.whisper: true, .gemma: true], phases: [:]).isEmpty)
    }
}
