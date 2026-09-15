import Foundation
import Testing
@testable import dBrief

@MainActor @Suite(.serialized)
struct PromptAsyncSessionTests {
    @Test func lateSuggestionCannotOverwriteNewerDraftAndApplyNeedsSave() async throws {
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        try #require(!domain.hasPrefix("com.dbrief.app"))
        let defaults = UserDefaults.standard
        let saved = defaults.persistentDomain(forName: domain)
        defer { if let saved { defaults.setPersistentDomain(saved, forName: domain) }
            else { defaults.removePersistentDomain(forName: domain) } }
        let settings = AppSettings()
        settings.summaryPrompt = "Saved"
        settings.aiEngine = .appleIntelligence
        let backend = DelayedPromptImprover()
        let session = try PromptEditorSession(identity: .init(kind: .summary, scope: .appDefaults),
            store: PromptPreferencesStore(settings: settings), improver: backend)
        let first = Task { await session.improve() }
        while await backend.count < 1 { await Task.yield() }
        session.edit("New draft")
        let second = Task { await session.improve() }
        while await backend.count < 2 { await Task.yield() }
        await backend.finish(1, text: "Second suggestion")
        await second.value
        #expect(session.canApplySuggestion)
        await backend.finish(0, text: "Stale first suggestion")
        await first.value
        #expect(session.suggestion?.response.prompt == "Second suggestion")
        #expect(session.draft.text == "New draft")
        session.applySuggestion()
        #expect(session.draft.text == "Second suggestion")
        #expect(settings.summaryPrompt == "Saved")
        session.undoAIEdit()
        #expect(session.draft.text == "New draft")
        #expect(settings.summaryPrompt == "Saved")
    }

    @Test func configurationChangePermanentlyInvalidatesSuggestion() async throws {
        let settings = AppSettings()
        let backend = DelayedPromptImprover()
        let session = try PromptEditorSession(identity: .init(kind: .summary, scope: .appDefaults),
            store: PromptPreferencesStore(settings: settings), improver: backend)
        let task = Task { await session.improve() }
        while await backend.count < 1 { await Task.yield() }
        await backend.finish(0, text: "Suggestion")
        await task.value
        #expect(session.canApplySuggestion)
        session.configurationChanged()
        #expect(session.suggestion == nil)
        #expect(!session.canApplySuggestion)
    }

    @Test func closingBeforeScheduledPreviewPreventsDispatch() async {
        let backend = DelayedPromptPreview()
        let session = PromptPreviewSession()
        let request = PromptPreviewRequest(identity: .init(kind: .summary, scope: .appDefaults), draftText: "Draft",
            sample: .example, configuration: .appleIntelligence, outputLanguage: .matchInput,
            vocabulary: "", summaryGuidance: "", actionItemsGuidance: "", tagsGuidance: "")
        session.start(request, using: backend)
        session.cancel()
        for _ in 0..<20 { await Task.yield() }
        #expect(!(await backend.started))
        #expect(!session.isRunning)
    }

    @Test func previewCancellationRejectsLateCompletion() async throws {
        let backend = DelayedPromptPreview()
        let session = PromptPreviewSession()
        let request = PromptPreviewRequest(identity: .init(kind: .summary, scope: .appDefaults), draftText: "Draft",
            sample: .example, configuration: .appleIntelligence, outputLanguage: .matchInput,
            vocabulary: "", summaryGuidance: "", actionItemsGuidance: "", tagsGuidance: "")
        let task = Task { await session.run(request, using: backend) }
        while !(await backend.started) { await Task.yield() }
        session.cancel()
        await backend.finish()
        await task.value
        #expect(session.result == nil)
        #expect(!session.isRunning)
    }
}

private actor DelayedPromptImprover: PromptImproving {
    struct Pending { let input: PromptImprovementInput; let continuation: CheckedContinuation<PromptSuggestion, any Error> }
    private var pending: [Pending] = []
    var count: Int { pending.count }
    func improve(_ input: PromptImprovementInput) async throws -> PromptSuggestion {
        try await withCheckedThrowingContinuation { pending.append(.init(input: input, continuation: $0)) }
    }
    func finish(_ index: Int, text: String) {
        let item = pending[index]
        item.continuation.resume(returning: .init(input: item.input, response: .init(prompt: text, changes: ["Clearer"])))
    }
}
private actor DelayedPromptPreview: PromptPreviewing {
    private var continuation: CheckedContinuation<PromptPreviewOutput, any Error>?
    var started: Bool { continuation != nil }
    func run(_ request: PromptPreviewRequest) async throws -> PromptPreviewOutput {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: .summary("Late result")); continuation = nil }
}
