import AppKit
import Foundation
import Observation

/// All editable content lives here, not in Settings bindings.
@MainActor @Observable
final class PromptEditorSession {
    let preview = PromptPreviewSession()
    let identity: PromptIdentity
    let store: PromptPreferencesStore
    private(set) var draft: PromptDraft
    var errorMessage: String?
    var improvementRequest = "" {
        didSet { if oldValue != improvementRequest { cancelImprovement() } }
    }
    private(set) var suggestion: PromptSuggestion?
    private(set) var isImproving = false
    private(set) var improvementError: String?
    var panel: Panel = .none
    enum Panel: String, CaseIterable { case none = "Editor", improve = "Improve with AI", preview = "Try prompt" }
    @ObservationIgnored var undoManager: UndoManager? = UndoManager()
    @ObservationIgnored private let improver: (any PromptImproving)?
    @ObservationIgnored private var improvementTask: Task<PromptSuggestion, Error>?
    @ObservationIgnored private var improvementID = UUID()
    private var beforeAI: PromptDraft?
    private var appliedAIText: String?

    init(identity: PromptIdentity, store: PromptPreferencesStore, improver: (any PromptImproving)? = nil) throws {
        self.identity = identity
        self.store = store
        self.improver = improver
        self.draft = PromptDraft(snapshot: try store.load(identity))
    }
    var configuration: PromptExecutionConfiguration? { try? PromptConfigurationResolver.resolve(identity: identity, settings: store.settings) }
    var configurationError: String? {
        do { _ = try PromptConfigurationResolver.resolve(identity: identity, settings: store.settings); return nil }
        catch { return error.localizedDescription }
    }
    var canApplySuggestion: Bool {
        guard let suggestion else { return false }
        return suggestion.input.originalPrompt == draft.text && suggestion.input.identity == identity
            && suggestion.input.request == improvementRequest && suggestion.input.configuration == configuration
    }
    var canUndoAI: Bool { beforeAI != nil && appliedAIText == draft.text }

    func edit(_ text: String) {
        guard draft.text != text else { return }
        replace(.custom(text), actionName: "Edit prompt")
    }
    /// Used by templates/restoration/AI. Native text synchronization does not register a second undo.
    func replace(_ value: PromptValue, actionName: String) {
        let previous = draft.value
        guard previous != value else { return }
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.replace(previous, actionName: actionName) }
        }
        undoManager?.setActionName(actionName)
        draft.value = value
        errorMessage = nil
        cancelImprovement()
    }
    func applyText(_ text: String) { replace(.custom(text), actionName: "Replace prompt") }
    func restoreDefault() {
        replace(identity.scope == .appDefaults ? .custom(draft.baseline.factoryText) : .inherited, actionName: "Restore prompt")
    }
    func save() throws {
        do {
            draft = PromptDraft(snapshot: try store.save(draft))
            errorMessage = nil
            beforeAI = nil
            appliedAIText = nil
        } catch { errorMessage = error.localizedDescription; throw error }
    }
    func reloadSaved() throws {
        draft = PromptDraft(snapshot: try store.load(identity))
        undoManager?.removeAllActions()
        suggestion = nil
        beforeAI = nil
        appliedAIText = nil
        errorMessage = nil
        cancelWork()
    }
    func improve() async {
        cancelImprovement()
        guard let improver else { return }
        let config: PromptExecutionConfiguration
        do { config = try PromptConfigurationResolver.resolve(identity: identity, settings: store.settings) }
        catch { improvementError = error.localizedDescription; return }
        let input = PromptImprovementInput(identity: identity, originalPrompt: draft.text, request: improvementRequest, configuration: config)
        let id = UUID()
        improvementID = id
        isImproving = true
        improvementError = nil
        suggestion = nil
        let task = Task { try await improver.improve(input) }
        improvementTask = task
        defer { if improvementID == id { isImproving = false; improvementTask = nil } }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard improvementID == id, !Task.isCancelled, !task.isCancelled,
                  draft.text == input.originalPrompt, improvementRequest == input.request, configuration == input.configuration else { return }
            suggestion = result
        } catch {
            if improvementID == id && !Task.isCancelled && !task.isCancelled {
                if error is PromptImprovementError || error is PromptAIError {
                    improvementError = error.localizedDescription
                } else { improvementError = SettingsErrorSanitizer.details(for: error.localizedDescription) }
            }
        }
        if improvementID == id { isImproving = false; improvementTask = nil }
    }
    func cancelImprovement() {
        improvementID = UUID()
        improvementTask?.cancel()
        improvementTask = nil
        isImproving = false
    }
    func configurationChanged() { cancelImprovement(); suggestion = nil; improvementError = nil }
    func applySuggestion() {
        guard canApplySuggestion, let suggestion else { return }
        beforeAI = draft
        appliedAIText = suggestion.response.prompt
        replace(.custom(suggestion.response.prompt), actionName: "Improve prompt with AI")
        self.suggestion = nil
    }
    func discardSuggestion() { suggestion = nil }
    func undoAIEdit() {
        guard canUndoAI, let beforeAI else { return }
        replace(beforeAI.value, actionName: "Undo AI edit")
        self.beforeAI = nil
        appliedAIText = nil
    }
    func cancelWork() { cancelImprovement(); preview.cancel() }
}
