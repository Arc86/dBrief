import Foundation
import Testing
import dBriefWire
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
        session.engineSelection = .localModel
        let first = Task { await session.improve() }
        while await backend.count < 1 { await Task.yield() }
        #expect(await backend.hasProgressSink(0))
        #expect(session.improvementProgress == .preparingModel)
        await backend.emit(.downloading(progress: 0.42, stage: .llmModel), at: 0)
        try await waitUntil { session.improvementProgress == .downloadingModel(0.42) }
        session.edit("New draft")
        let second = Task { await session.improve() }
        while await backend.count < 2 { await Task.yield() }
        await backend.emit(.downloading(progress: nil, stage: .llmModelLoading), at: 1)
        try await waitUntil { session.improvementProgress == .loadingModel }
        await backend.emit(.downloading(progress: 0.9, stage: .llmModel), at: 0)
        for _ in 0..<20 { await Task.yield() }
        #expect(session.improvementProgress == .loadingModel)
        await backend.emit(.analyzing, at: 1)
        try await waitUntil { session.improvementProgress == .generating }
        await backend.finish(1, text: "Second suggestion")
        await second.value
        #expect(session.canApplySuggestion)
        #expect(session.improvementProgress == nil)
        await backend.emit(.downloading(progress: 0.95, stage: .llmModel), at: 1)
        await backend.finish(0, text: "Stale first suggestion")
        await first.value
        #expect(session.improvementProgress == nil)
        #expect(session.suggestion?.response.prompt == "Second suggestion")
        #expect(session.suggestion?.input.configuration == .localModel)
        #expect(settings.aiEngine == .appleIntelligence)
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
        session.engineSelection = .localModel
        session.engineSelection = .configured
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
        #expect(await backend.hasProgressSink)
        await backend.emit(.downloading(progress: 0.5, stage: .llmModel))
        try await waitUntil { session.progress == .downloadingModel(0.5) }
        session.cancel()
        await backend.emit(.downloading(progress: nil, stage: .llmModelLoading))
        await backend.finish()
        await task.value
        #expect(session.result == nil)
        #expect(!session.isRunning)
        #expect(session.progress == nil)
    }

    @Test func progressStaysWithItsOwnWindow() async throws {
        let store = PromptPreferencesStore(settings: AppSettings())
        let backend = DelayedPromptImprover()
        let first = try PromptEditorSession(identity: .init(kind: .summary, scope: .appDefaults), store: store, improver: backend)
        let second = try PromptEditorSession(identity: .init(kind: .tags, scope: .appDefaults), store: store, improver: backend)
        first.engineSelection = .localModel
        second.engineSelection = .appleIntelligence
        let one = Task { await first.improve() }
        while await backend.count < 1 { await Task.yield() }
        let two = Task { await second.improve() }
        while await backend.count < 2 { await Task.yield() }
        #expect(second.improvementProgress == .generating)
        await backend.emit(.downloading(progress: 0.2, stage: .llmModel), at: 0)
        try await waitUntil { first.improvementProgress == .downloadingModel(0.2) }
        #expect(second.improvementProgress == .generating)
        first.engineSelection = .appleIntelligence
        await backend.emit(.downloading(progress: 0.7, stage: .llmModel), at: 0)
        await backend.finish(0, text: "Cancelled")
        await backend.finish(1, text: "Second")
        await one.value
        await two.value
        #expect(first.improvementProgress == nil)
        #expect(first.suggestion == nil)
        #expect(second.improvementProgress == nil)
        #expect(second.suggestion?.response.prompt == "Second")
    }

    @Test(arguments: [false, true]) func previewClearsProgressOnCompletionOrFailure(failure: Bool) async throws {
        let backend = DelayedPromptPreview()
        let session = PromptPreviewSession()
        let request = PromptPreviewRequest(identity: .init(kind: .summary, scope: .appDefaults), draftText: "Draft",
            sample: .example, configuration: .localModel, outputLanguage: .matchInput,
            vocabulary: "", summaryGuidance: "", actionItemsGuidance: "", tagsGuidance: "")
        let task = Task { await session.run(request, using: backend) }
        while !(await backend.started) { await Task.yield() }
        #expect(session.progress == .preparingModel)
        await backend.emit(.downloading(progress: nil, stage: .llmModel))
        try await waitUntil { session.progress == .downloadingModel(nil) }
        await backend.emit(.downloading(progress: 0.75, stage: .llmModel))
        try await waitUntil { session.progress == .downloadingModel(0.75) }
        await backend.emit(.downloading(progress: nil, stage: .llmModelLoading))
        try await waitUntil { session.progress == .loadingModel }
        await backend.emit(.analyzing)
        try await waitUntil { session.progress == .generating }
        await backend.finish(failure: failure)
        await task.value
        #expect(session.progress == nil)
        #expect(!session.isRunning)
        #expect((session.errorMessage != nil) == failure)
        #expect((session.result != nil) != failure)
        await backend.emit(.downloading(progress: 1, stage: .llmModel))
        for _ in 0..<20 { await Task.yield() }
        #expect(session.progress == nil)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }
}

private actor DelayedPromptImprover: PromptImproving {
    struct Pending { let input: PromptImprovementInput; let sink: MLProgress.Sink?; let continuation: CheckedContinuation<PromptSuggestion, any Error> }
    private var pending: [Pending] = []
    var count: Int { pending.count }
    func hasProgressSink(_ index: Int) -> Bool { pending[index].sink != nil }
    func emit(_ state: LocalAIPluginState, at index: Int) { pending[index].sink?(state) }
    func improve(_ input: PromptImprovementInput) async throws -> PromptSuggestion {
        try await withCheckedThrowingContinuation { pending.append(.init(input: input, sink: MLProgress.sink, continuation: $0)) }
    }
    func finish(_ index: Int, text: String) {
        let item = pending[index]
        item.continuation.resume(returning: .init(input: item.input, response: .init(prompt: text, changes: ["Clearer"])))
    }
}
private actor DelayedPromptPreview: PromptPreviewing {
    private var continuation: CheckedContinuation<PromptPreviewOutput, any Error>?
    private var sink: MLProgress.Sink?
    var hasProgressSink: Bool { sink != nil }
    func emit(_ state: LocalAIPluginState) { sink?(state) }
    var started: Bool { continuation != nil }
    func run(_ request: PromptPreviewRequest) async throws -> PromptPreviewOutput {
        sink = MLProgress.sink
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(failure: Bool = false) {
        if failure { continuation?.resume(throwing: PromptPreviewError.failed("Synthetic failure")) }
        else { continuation?.resume(returning: .summary("Late result")) }
        continuation = nil
    }
}
