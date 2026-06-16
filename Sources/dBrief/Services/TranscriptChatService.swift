import Foundation
import dBriefWire
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
@Observable
final class TranscriptChatService {
    private(set) var messages: [ChatMessage] = []
    private(set) var isStreaming = false
    private(set) var streamingError: String? = nil

    /// Provides the transcript text at send-time. A closure (rather than a stored
    /// string) so the chat can read a *live, growing* transcript during recording —
    /// each `send()` rebuilds the prompt from the current snapshot. Mutable so a live
    /// chat can be re-pointed at the authoritative transcript when recording finishes
    /// (see `rebindTranscript`).
    private var transcriptProvider: @MainActor () -> String
    private var speakerLabels: [SpeakerLabel]
    private let appSettings: AppSettings
    private let localPlugin: LocalAIPluginService?
    private let aiService = AIService()

    /// On-disk persistence handle. Set via `enablePersistence`; nil for sessions
    /// that have no stable sidecar location yet (e.g. a still-recording live
    /// session, until it finishes and rebinds to the authoritative transcript).
    private var chatStore: ChatStore?
    private var persistenceURL: URL?
    private var saveTask: Task<Void, Never>?
    /// The in-flight initial load from disk. `send()` awaits it so a fast typist
    /// can't append to an empty conversation before persisted history arrives
    /// (which would no-op the load and overwrite the saved file).
    private var loadTask: Task<Void, Never>?
    /// True when `messages` has changed since the last successful write — lets
    /// `flushPendingSave()` skip a redundant write on quit when nothing is dirty.
    private var hasUnsavedChanges = false

    init(
        transcriptProvider: @escaping @MainActor () -> String,
        speakerLabels: [SpeakerLabel],
        appSettings: AppSettings,
        localPlugin: LocalAIPluginService?
    ) {
        self.transcriptProvider = transcriptProvider
        self.speakerLabels = speakerLabels
        self.appSettings = appSettings
        self.localPlugin = localPlugin
    }

    /// Convenience init for a fixed (completed-recording) transcript.
    convenience init(
        transcriptText: String,
        speakerLabels: [SpeakerLabel],
        appSettings: AppSettings,
        localPlugin: LocalAIPluginService?
    ) {
        self.init(
            transcriptProvider: { transcriptText },
            speakerLabels: speakerLabels,
            appSettings: appSettings,
            localPlugin: localPlugin
        )
    }

    func send(_ userText: String) async {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        // Make sure any persisted history has been adopted before we append, so
        // sending before the disk load finishes can't drop the saved conversation.
        await loadTask?.value

        messages.append(ChatMessage(role: .user, content: trimmed))

        var assistantMessage = ChatMessage(role: .assistant, content: "")
        messages.append(assistantMessage)
        let assistantIdx = messages.count - 1

        isStreaming = true
        streamingError = nil

        let systemPrompt = buildSystemPrompt()
        let fullUserMessage = buildContextualUserMessage(currentMessage: trimmed)

        do {
            let stream = await buildStream(systemPrompt: systemPrompt, userMessage: fullUserMessage)
            for try await chunk in stream {
                assistantMessage.content += chunk
                messages[assistantIdx] = assistantMessage
            }
        } catch {
            streamingError = error.localizedDescription
            messages[assistantIdx].content = "Error: \(error.localizedDescription)"
        }

        isStreaming = false
        scheduleSave()
    }

    func clearMessages() {
        messages = []
        streamingError = nil
        // Clearing the conversation removes the on-disk sidecar too.
        saveTask?.cancel()
        hasUnsavedChanges = false
        if let chatStore, let persistenceURL {
            Task { await chatStore.delete(at: persistenceURL) }
        }
    }

    // MARK: - Persistence

    /// Bind this session to an on-disk `<base>.chat.json` sidecar. Idempotent —
    /// safe to call again (e.g. when a live session finishes and gains a stable
    /// finalized audio URL). Does not itself load; call `loadPersisted()` after.
    func enablePersistence(store: ChatStore, url: URL) {
        chatStore = store
        persistenceURL = url
    }

    /// Begin adopting a previously-saved conversation from disk. Tracks the work
    /// in `loadTask` so `send()` can await it before appending. Call after
    /// `enablePersistence`.
    func startLoadingPersisted() {
        loadTask = Task { await loadPersisted() }
    }

    /// Adopt a previously-saved conversation from disk. No-op if persistence
    /// isn't enabled, the sidecar is absent/empty, or this session already has
    /// messages (an in-progress live chat must not be clobbered by an old file).
    func loadPersisted() async {
        guard let chatStore, let persistenceURL, messages.isEmpty else { return }
        guard let history = try? await chatStore.load(from: persistenceURL),
              !history.messages.isEmpty else { return }
        messages = history.messages
    }

    /// Request a save of the current conversation (e.g. after a live chat is
    /// carried over to a now-finalized recording). Debounced like any exchange.
    func persistNow() { scheduleSave() }

    /// Write the current conversation immediately if it has unsaved changes,
    /// bypassing the debounce. Called on app termination so the most recent
    /// exchange isn't lost when the user quits within the debounce window.
    func flushPendingSave() async {
        saveTask?.cancel()
        guard hasUnsavedChanges, let chatStore, let persistenceURL, !messages.isEmpty else { return }
        let history = ChatHistory(messages: messages, engine: appSettings.effectiveAIEngine.rawValue)
        try? await chatStore.save(history, to: persistenceURL)
        hasUnsavedChanges = false
    }

    /// Debounced write of the current conversation. Coalesces rapid exchanges
    /// into a single atomic save and snapshots `messages` on the main actor so
    /// the actor write sees a consistent value.
    private func scheduleSave() {
        guard let chatStore, let persistenceURL, !messages.isEmpty else { return }
        hasUnsavedChanges = true
        let snapshot = messages
        let engine = appSettings.effectiveAIEngine.rawValue
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let history = ChatHistory(messages: snapshot, engine: engine)
            try? await chatStore.save(history, to: persistenceURL)
            hasUnsavedChanges = false
        }
    }

    /// Re-point this chat at a fixed transcript while keeping the conversation so far.
    /// Used when a live recording finishes: the in-memory live preview is gone, so the
    /// chat switches to the authoritative on-disk transcript, but the live Q&A history
    /// is preserved (those earlier answers were grounded in the rough live preview).
    func rebindTranscript(text: String, speakerLabels: [SpeakerLabel]) {
        transcriptProvider = { text }
        self.speakerLabels = speakerLabels
    }

    /// True once the conversation has at least one exchange — used to decide whether a
    /// finished recording should preserve and reopen the carried-over live chat.
    var hasHistory: Bool { !messages.isEmpty }

    /// Warms the on-device model when the chat panel opens so the first answer streams
    /// sooner. No-op unless Apple Intelligence is the active (or fallback) chat engine.
    func prewarm() {
        let engine = appSettings.effectiveAIEngine == .localCLI
            ? appSettings.chatFallbackEngine
            : appSettings.effectiveAIEngine
        guard engine == .appleIntelligence else { return }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            LanguageModelSession().prewarm()
        }
        #endif
    }

    // MARK: - Private

    private func buildStream(systemPrompt: String, userMessage: String) async -> AsyncThrowingStream<String, Error> {
        // The Local CLI is one-shot and can't stream chat, so route to the
        // user-selected fallback engine instead.
        let engine = appSettings.effectiveAIEngine == .localCLI
            ? appSettings.chatFallbackEngine
            : appSettings.effectiveAIEngine

        switch engine {

        case .localCLI:
            return errorStream("Local CLI does not support chat. Choose a chat fallback engine in Settings → AI & Models.")

        case .qwenLocal:
            guard let plugin = localPlugin else {
                return errorStream("Local AI plugin not available")
            }
            return await plugin.chatStream(systemPrompt: systemPrompt, userMessage: userMessage)

        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                return AsyncThrowingStream { continuation in
                    Task {
                        do {
                            let session = LanguageModelSession(instructions: systemPrompt)
                            let options = GenerationOptions(temperature: 0.5)
                            let response = try await session.respond(to: userMessage, options: options)
                            continuation.yield(response.content)
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            }
            #endif
            return errorStream("Apple Intelligence requires macOS 26 or later")

        case .remoteEndpoint:
            guard let endpoint = appSettings.effectiveDefaultAIEndpoint else {
                return errorStream("No AI endpoint configured. Add one in Settings → AI.")
            }
            return aiService.streamChat(systemPrompt: systemPrompt, userMessage: userMessage, endpoint: endpoint)
        }
    }

    private func errorStream(_ message: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: NSError(
                domain: "TranscriptChatService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
        }
    }

    private func buildSystemPrompt() -> String {
        let engine = appSettings.effectiveAIEngine == .localCLI
            ? appSettings.chatFallbackEngine
            : appSettings.effectiveAIEngine
        // Apple Intelligence (FoundationModels) has a ~4096-token context window — a full
        // transcript in the instructions overflows it and chat errors out immediately.
        // Truncate for that engine; Gemma (128K) and remote endpoints keep the full text.
        let transcriptText = transcriptProvider()
        let transcript = engine == .appleIntelligence
            ? UnifiedInsightsPrompt.truncateForFoundationModels(transcriptText)
            : transcriptText

        var prompt = "You are an intelligent assistant helping analyze a meeting transcript.\n\n"
        prompt += "TRANSCRIPT:\n\(transcript)\n"
        if !speakerLabels.isEmpty {
            prompt += "\nSPEAKER LEGEND:\n"
            for label in speakerLabels {
                prompt += "- \(label.id): \(label.displayName)\n"
            }
        }
        prompt += "\nAnswer the user's questions concisely. When asked to format or transform the transcript, do so directly without preamble."
        return prompt
    }

    private func buildContextualUserMessage(currentMessage: String) -> String {
        let history = messages.dropLast()  // exclude the assistant placeholder we just added
        guard !history.isEmpty else { return currentMessage }

        // Include conversation history as plain text for backends that are single-turn
        var context = "Previous conversation:\n"
        for msg in history {
            let prefix = msg.role == .user ? "User: " : "Assistant: "
            context += "\(prefix)\(msg.content)\n\n"
        }
        return "\(context)Current question: \(currentMessage)"
    }
}
