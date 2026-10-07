import Foundation
import os
import dBriefWire
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Shared with an actor write so retiring a session also rejects saves already
/// enqueued before the recording lock was acquired and subsequently released.
final class RecordingDerivativeValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        valid = false
    }

    func withValidResult<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard valid else { throw CancellationError() }
        return try body()
    }
}

/// How much of the transcript the latest answer was grounded in.
enum ChatCoverage: Equatable, Sendable {
    case full
    /// Long recording: a whole-meeting overview plus excerpts retrieved per question.
    case relevantParts
}

@MainActor
@Observable
final class TranscriptChatService {
    private final class WeakService {
        weak var value: TranscriptChatService?
        init(_ value: TranscriptChatService) { self.value = value }
    }
    private static var activeServices: [WeakService] = []

    static func invalidateForReprocessing(audioURL: URL) {
        let key = audioURL.standardizedFileURL.resolvingSymlinksInPath()
        activeServices.removeAll { $0.value == nil }
        for entry in activeServices {
            guard let service = entry.value, let recording = service.privacyRecording else { continue }
            let source = recording.finalizedAudioURL ?? recording.fileURL
            if source.standardizedFileURL.resolvingSymlinksInPath() == key {
                service.invalidateForReprocessing()
            }
        }
    }

    var isInvalidatedForReprocessing: Bool { invalidated }
    private(set) var messages: [ChatMessage] = []
    private(set) var isStreaming = false
    private(set) var streamingError: String? = nil
    private(set) var streamingNotice: String? = nil
    /// Grounding of the latest answer; nil for engines without long mode.
    private(set) var coverage: ChatCoverage?
    /// Shown inline while the long-recording search index is built.
    private(set) var indexingStatus: String?
    /// Part being checked by a running whole-recording scan; nil otherwise.
    private(set) var scanProgress: (index: Int, total: Int)?
    /// Status line while a scan runs: "Checking part i of n…", then the answer step.
    private(set) var scanStatus: String?
    /// Footer under a finished scan's answer ("Checked the whole recording.").
    private(set) var scanFootnote: (messageID: UUID, text: String)?
    /// The assistant message a running scan writes into, so Stop can mark it stopped.
    private var scanAssistantID: UUID?
    /// A draft belongs to this recording's existing session, so hiding its
    /// inspector does not discard it. It is deliberately not a sidecar field.
    var draftInput = ""
    let speechPlayer = VoicePreviewPlayer()
    private(set) var spokenMessageID: UUID?
    private var speechTask: Task<Void, Never>?

    func copyAnswer(_ message: ChatMessage) async -> Bool {
        await RecordingClipboard.copy(message.displayParts.answer, contextProvider: {
            await self.privacyRecording?.privacyContext()
        })
    }

    func canExportAnswer(_ message: ChatMessage) -> Bool {
        guard !invalidated, message.role == .assistant,
              let current = messages.first(where: { $0.id == message.id }),
              current.role == .assistant,
              !(isStreaming && messages.last?.id == current.id) else { return false }
        return !current.displayParts.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Export only a completed answer still owned by this session. Recheck after
    /// receipt I/O: a save panel can outlive clearing or reprocessing the chat.
    func exportAnswer(_ message: ChatMessage, format: ChatAnswerExportFormat, to destination: URL) async throws {
        guard canExportAnswer(message) else { throw answerExportUnavailable }
        let context = await privacyRecording?.privacyContext()
        try await PrivacyTrace.$context.withValue(context) {
            try await PrivacyTrace.perform(.init(stage: .markdownExport, data: [.text],
                                                 destination: .local(provider: .fileSystem))) {
                guard canExportAnswer(message),
                      let current = messages.first(where: { $0.id == message.id }) else {
                    throw answerExportUnavailable
                }
                try ChatAnswerExport.write(ChatAnswerExport.payload(for: current, format: format), to: destination)
            }
        }
    }

    private var answerExportUnavailable: NSError {
        NSError(domain: "dBrief.AnswerExport", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "This answer is no longer available to export. Wait for it to finish, or reopen the current conversation."])
    }

    func toggleReadAloud(_ message: ChatMessage) {
        if spokenMessageID == message.id, speechTask != nil || speechPlayer.isBusy {
            stopReading()
            return
        }
        stopReading()
        guard !invalidated, message.role == .assistant,
              messages.contains(where: { $0.id == message.id }),
              !(isStreaming && messages.last?.id == message.id),
              !message.speechText.isEmpty else { return }
        spokenMessageID = message.id
        speechTask = Task { [weak self] in
            guard let self else { return }
            let context = await self.privacyRecording?.privacyContext()
            guard !Task.isCancelled, !self.invalidated else { return }
            PrivacyTrace.$context.withValue(context) {
                let tts = self.appSettings.ttsSynthesisParams
                self.speechPlayer.preview(
                    text: message.speechText, engine: tts.engine, voice: tts.voice,
                    language: tts.language, instruction: tts.instruction,
                    model: tts.model, plugin: self.localPlugin
                )
            }
            self.speechTask = nil
        }
    }

    func stopReading() {
        speechTask?.cancel()
        speechTask = nil
        speechPlayer.stop()
        spokenMessageID = nil
    }

    /// Provides the transcript text at send-time. A closure (rather than a stored
    /// string) so the chat can read a *live, growing* transcript during recording —
    /// each `send()` rebuilds the prompt from the current snapshot. Mutable so a live
    /// chat can be re-pointed at the authoritative transcript when recording finishes
    /// (see `rebindTranscript`).
    private var transcriptProvider: @MainActor () -> String
    private var speakerLabels: [SpeakerLabel]
    private let appSettings: AppSettings
    private let localPlugin: LocalAIPluginService?
    private let aiService: AIService
    private let privacyRecording: Recording?

    /// Speaker-attributed turns of a finished recording (empty for live chat), the
    /// source of retrieval windows in long mode.
    private let chatTurns: [TranscriptTurn]
    /// Analysis sidecar contents. Loaded lazily from `insightsURL` when not supplied,
    /// so a chat built before the viewer finished loading still gets part notes.
    private var insights: RecordingInsights?
    private let insightsURL: URL?
    private var didLoadInsights = false
    private let indexURL: URL?
    private var chatIndex: ChatIndex?
    private var indexTask: Task<ChatIndex?, Never>?
    private let chatIndexStore = ChatIndexStore()
    /// Long-mode system prompt, built once per session: it must stay byte-stable so
    /// the helper's warm Gemma session (keyed on prompt + history) is reused.
    private var longModePrompt: String?

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
    /// True while a saved conversation is read from disk, so the chat view can
    /// hold its empty state instead of flashing it before the history appears.
    private(set) var isLoadingHistory = false
    /// True when `messages` has changed since the last successful write — lets
    /// `flushPendingSave()` skip a redundant write on quit when nothing is dirty.
    private var hasUnsavedChanges = false
    private var invalidated = false
    private let validity = RecordingDerivativeValidity()
    private var sendTask: Task<Void, Never>?
    private var activeSendID: UUID?

    /// Retire this session without deleting the currently published conversation.
    /// A retired session can never republish derivatives after an attempt unlocks.
    func invalidateForReprocessing() {
        stopReading()
        invalidated = true
        validity.invalidate()
        sendTask?.cancel()
        saveTask?.cancel()
        loadTask?.cancel()
        indexTask?.cancel()
        indexTask = nil
        chatIndex = nil
        indexingStatus = nil
        sendTask = nil
        activeSendID = nil
        saveTask = nil
        loadTask = nil
        isLoadingHistory = false
        chatStore = nil
        persistenceURL = nil
        hasUnsavedChanges = false
        isStreaming = false
        clearScanState()
        scanFootnote = nil
    }

    init(
        transcriptProvider: @escaping @MainActor () -> String,
        speakerLabels: [SpeakerLabel],
        appSettings: AppSettings,
        localPlugin: LocalAIPluginService?,
        recording: Recording? = nil,
        aiService: AIService = AIService(),
        turns: [TranscriptTurn] = [],
        insights: RecordingInsights? = nil,
        insightsURL: URL? = nil,
        indexURL: URL? = nil
    ) {
        self.transcriptProvider = transcriptProvider
        self.speakerLabels = speakerLabels
        self.appSettings = appSettings
        self.localPlugin = localPlugin
        self.privacyRecording = recording
        self.aiService = aiService
        self.chatTurns = turns
        self.insights = insights
        self.didLoadInsights = insights != nil
        self.insightsURL = insightsURL
        self.indexURL = indexURL
        Self.activeServices.removeAll { $0.value == nil }
        Self.activeServices.append(WeakService(self))
    }

    /// Convenience init for a fixed (completed-recording) transcript.
    convenience init(
        transcriptText: String,
        speakerLabels: [SpeakerLabel],
        appSettings: AppSettings,
        localPlugin: LocalAIPluginService?,
        recording: Recording? = nil,
        aiService: AIService = AIService(),
        turns: [TranscriptTurn] = [],
        insights: RecordingInsights? = nil,
        insightsURL: URL? = nil,
        indexURL: URL? = nil
    ) {
        self.init(
            transcriptProvider: { transcriptText },
            speakerLabels: speakerLabels,
            appSettings: appSettings,
            localPlugin: localPlugin,
            recording: recording,
            aiService: aiService,
            turns: turns,
            insights: insights,
            insightsURL: insightsURL,
            indexURL: indexURL
        )
    }

    func send(_ userText: String) async {
        await runExclusive(userText) { sendID in await self.sendInRecordingContext(userText, sendID: sendID) }
    }

    /// Runs one exchange (a question or a whole-recording scan) as the session's only
    /// in-flight request, so Stop (`stopGenerating`) cancels either the same way.
    private func runExclusive(_ text: String, _ body: @escaping @Sendable @MainActor (UUID) async -> Void) async {
        guard !invalidated, !Task.isCancelled, sendTask == nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isStreaming else { return }
        let sendID = UUID()
        activeSendID = sendID
        isStreaming = true
        streamingError = nil
        streamingNotice = nil
        let task = Task { [weak self] in
            guard let self, !self.invalidated, self.activeSendID == sendID else { return }
            let context = await self.privacyRecording?.privacyContext()
            guard !self.invalidated, !Task.isCancelled, self.activeSendID == sendID else { return }
            await PrivacyTrace.$context.withValue(context) { await body(sendID) }
        }
        sendTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        // A stopped request may unwind after the user has already sent another.
        guard activeSendID == sendID else { return }
        sendTask = nil
        activeSendID = nil
        isStreaming = false
        clearScanState()
        scheduleSave()
    }

    private func sendInRecordingContext(_ userText: String, sendID: UUID) async {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, activeSendID == sendID else { return }

        // Make sure any persisted history has been adopted before we append, so
        // sending before the disk load finishes can't drop the saved conversation.
        await loadTask?.value
        guard !invalidated, !Task.isCancelled, activeSendID == sendID else { return }

        messages.append(ChatMessage(role: .user, content: trimmed))

        var assistantMessage = ChatMessage(role: .assistant, content: "")
        messages.append(assistantMessage)
        let assistantIdx = messages.count - 1

        var limiter = ChatResponseLimiter()

        do {
            let stream: AsyncThrowingStream<String, Error>
            if resolvedChatEngine == .qwenLocal, let plugin = localPlugin {
                // Gemma keeps a warm session: send structured turns (history excludes the
                // just-appended user message and assistant placeholder) instead of flattened text.
                let history = priorHistory
                let profile = ChatEngineProfile.gemma
                await loadInsightsIfNeeded()
                guard !invalidated, !Task.isCancelled, activeSendID == sendID else { return }
                let overviewText = Self.overview(insights: insights, profile: profile)
                switch Self.chatMode(transcriptTokens: ChatEngineProfile.estimateTokens(transcriptProvider()),
                                     profile: profile, hasOverview: !overviewText.isEmpty,
                                     canRetrieve: !chatTurns.isEmpty) {
                case .fullTranscript:
                    coverage = .full
                    stream = await plugin.chatTurn(systemPrompt: buildSystemPrompt(), history: history, question: trimmed,
                                                   retrievedContext: "")
                case .overviewAndRetrieval, .retrievalOnly:
                    coverage = .relevantParts
                    let found = await excerpts(for: trimmed, profile: profile)
                    guard !invalidated, !Task.isCancelled, activeSendID == sendID else { return }
                    let longPrompt = longModePrompt ?? ChatContextPlanner.longModeSystemPrompt(
                        overview: overviewText, speakerLegend: speakerLegendText)
                    longModePrompt = longPrompt
                    stream = await plugin.chatTurn(systemPrompt: longPrompt, history: history, question: trimmed,
                                                   retrievedContext: ChatContextPlanner.retrievedContextBlock(found))
                }
            } else if resolvedChatEngine == .appleIntelligence {
                stream = await appleStream(question: trimmed, history: priorHistory, sendID: sendID)
            } else {
                coverage = nil
                stream = await buildStream(systemPrompt: buildSystemPrompt(),
                                           userMessage: buildContextualUserMessage(currentMessage: trimmed))
            }
            for try await chunk in stream {
                guard !invalidated, !Task.isCancelled, activeSendID == sendID,
                      messages.indices.contains(assistantIdx), messages[assistantIdx].id == assistantMessage.id else { return }
                assistantMessage.content += limiter.append(chunk)
                messages[assistantIdx] = assistantMessage
                if let reason = limiter.stopReason {
                    streamingNotice = reason.message
                    sendTask?.cancel()
                    return
                }
                // Buffered tokens must not monopolize the main actor and starve Stop.
                await Task.yield()
            }
        } catch {
            guard !invalidated, !Task.isCancelled, activeSendID == sendID,
                  messages.indices.contains(assistantIdx), messages[assistantIdx].id == assistantMessage.id else { return }
            streamingError = error.localizedDescription
            if assistantMessage.content.isEmpty {
                coverage = nil // no "relevant parts" footer under an error
                messages[assistantIdx].content = "Error: \(error.localizedDescription)"
            } else {
                streamingNotice = "Response interrupted: \(error.localizedDescription)"
            }
        }
    }

    func stopGenerating() {
        guard let task = sendTask else { return }
        activeSendID = nil
        sendTask = nil
        isStreaming = false
        task.cancel()
        if let scanID = scanAssistantID, let idx = messages.lastIndex(where: { $0.id == scanID }) {
            // A stopped scan discards its partial findings and any partial answer.
            messages[idx].content = Self.scanStoppedNote
            coverage = nil
            streamingNotice = "Stopped checking the whole recording."
        } else {
            streamingNotice = "Stopped generating."
            if messages.last?.role == .assistant, messages.last?.content.isEmpty == true {
                messages.removeLast()
            }
        }
        clearScanState()
        // Save from the user's action, before the cancelled task unwinds.
        scheduleSave()
    }

    func clearMessages() {
        guard !invalidated, !isStreaming else { return }
        stopReading()
        messages = []
        streamingError = nil
        streamingNotice = nil
        // Clearing the conversation removes the on-disk sidecar too.
        saveTask?.cancel()
        hasUnsavedChanges = false
        if let chatStore, let persistenceURL {
            saveTask = Task {
                guard !invalidated, !Task.isCancelled else { return }
                await chatStore.delete(at: persistenceURL, validity: validity)
            }
        }
    }

    // MARK: - Persistence

    /// Bind this session to an on-disk `<base>.chat.json` sidecar. Idempotent —
    /// safe to call again (e.g. when a live session finishes and gains a stable
    /// finalized audio URL). Does not itself load; call `loadPersisted()` after.
    func enablePersistence(store: ChatStore, url: URL) {
        guard !invalidated else { return }
        chatStore = store
        persistenceURL = url
    }

    /// Begin adopting a previously-saved conversation from disk. Tracks the work
    /// in `loadTask` so `send()` can await it before appending. Call after
    /// `enablePersistence`.
    func startLoadingPersisted() {
        guard !invalidated else { return }
        isLoadingHistory = true
        loadTask = Task {
            await loadPersisted()
            isLoadingHistory = false
        }
    }

    /// Adopt a previously-saved conversation from disk. No-op if persistence
    /// isn't enabled, the sidecar is absent/empty, or this session already has
    /// messages (an in-progress live chat must not be clobbered by an old file).
    func loadPersisted() async {
        guard let chatStore, let persistenceURL, messages.isEmpty else { return }
        guard let history = try? await chatStore.load(from: persistenceURL),
              !history.messages.isEmpty, !invalidated, !Task.isCancelled else { return }
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
        guard !invalidated, !Task.isCancelled, hasUnsavedChanges, let chatStore, let persistenceURL, !messages.isEmpty else { return }
        let history = ChatHistory(messages: messages, engine: appSettings.effectiveAIEngine.rawValue)
        try? await chatStore.save(history, to: persistenceURL, validity: validity)
        hasUnsavedChanges = false
    }

    /// Debounced write of the current conversation. Coalesces rapid exchanges
    /// into a single atomic save and snapshots `messages` on the main actor so
    /// the actor write sees a consistent value.
    private func scheduleSave() {
        guard !invalidated, !Task.isCancelled, let chatStore, let persistenceURL, !messages.isEmpty else { return }
        hasUnsavedChanges = true
        let snapshot = messages
        let engine = appSettings.effectiveAIEngine.rawValue
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !invalidated, !Task.isCancelled else { return }
            let history = ChatHistory(messages: snapshot, engine: engine)
            try? await chatStore.save(history, to: persistenceURL, validity: validity)
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
        longModePrompt = nil
    }

    /// True once the conversation has at least one exchange — used to decide whether a
    /// finished recording should preserve and reopen the carried-over live chat.
    var hasHistory: Bool { !messages.isEmpty }

    /// Whether this session's messages are backed by an on-disk sidecar. A live
    /// (in-progress recording) session has no sidecar until the recording
    /// finalizes, so its history exists only in memory — it must never be
    /// evicted from `TranscriptChatStore` or the carried-over Q&A is lost.
    var isPersistenceEnabled: Bool { chatStore != nil && persistenceURL != nil }

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

    /// The engine chat actually runs on: Local CLI can't stream, so it maps to the fallback.
    private var resolvedChatEngine: AppSettings.AIEngine {
        appSettings.effectiveAIEngine == .localCLI ? appSettings.chatFallbackEngine : appSettings.effectiveAIEngine
    }

    private func buildStream(systemPrompt: String, userMessage: String) async -> AsyncThrowingStream<String, Error> {
        // The Local CLI is one-shot and can't stream chat, so route to the
        // user-selected fallback engine instead.
        let engine = appSettings.effectiveAIEngine == .localCLI
            ? appSettings.chatFallbackEngine
            : appSettings.effectiveAIEngine

        switch engine {

        case .localCLI:
            return errorStream("Local CLI does not support chat. Choose a chat fallback engine in Settings → AI Analysis.")

        case .qwenLocal:
            guard let plugin = localPlugin else {
                return errorStream("Local AI plugin not available")
            }
            return await plugin.chatStream(systemPrompt: systemPrompt, userMessage: userMessage)

        case .appleIntelligence:
            // Routed to `appleStream` by `sendInRecordingContext` (fresh session per question).
            return errorStream("Apple Intelligence chat is not available here")

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
        fullTranscriptSystemPrompt(transcriptProvider())
    }

    /// Instructions carrying the whole transcript. Apple Intelligence reaches this only
    /// when the transcript fits its profile; longer ones use long mode instead.
    /// `recentPartOnly`: a live recording too long for Apple Intelligence, cut to its end.
    private func fullTranscriptSystemPrompt(_ transcript: String, recentPartOnly: Bool = false) -> String {
        var prompt = "You are an assistant analyzing a meeting transcript. "
        prompt += recentPartOnly
            ? "Only the most recent part of the transcript fits below; if a question is about an earlier part, say so plainly. "
            : "The complete transcript is included in full below — you already have it. "
        prompt += "Never ask the user to provide the transcript; always answer from the text between the markers.\n\n"
        prompt += "===== TRANSCRIPT START =====\n\(transcript)\n===== TRANSCRIPT END =====\n\nEach line starts with [hh:mm:ss] and the speaker's name. When you answer, cite the timestamp(s) you relied on, like [00:12:34].\n"
        if !speakerLabels.isEmpty {
            prompt += "\nSPEAKER LEGEND:\n\(speakerLegendText)\n"
        }
        prompt += "\nAnswer concisely in the transcript's language. When asked to summarize, list "
        prompt += "action items, or transform the transcript, do so directly from the text above — "
        prompt += "without preamble and without asking for more information."
        return prompt
    }

    /// One "- id: name" line per speaker, shared by the full and long-mode prompts.
    private var speakerLegendText: String {
        speakerLabels.map { "- \($0.id): \($0.displayName)" }.joined(separator: "\n")
    }

    // MARK: - Long recordings (overview + retrieval)

    /// Long mode needs retrieval windows; without turns (live chat, no segments) a
    /// long transcript keeps today's full-transcript behaviour.
    static func chatMode(transcriptTokens: Int, profile: ChatEngineProfile, hasOverview: Bool,
                         canRetrieve: Bool) -> ChatMode {
        guard canRetrieve else { return .fullTranscript }
        return ChatContextPlanner.mode(transcriptTokens: transcriptTokens, profile: profile, hasOverview: hasOverview)
    }

    /// Whole-meeting overview from the insights sidecar. Part notes are used only
    /// when they describe the current transcript (not a pre-retranscription one).
    static func overview(insights: RecordingInsights?, profile: ChatEngineProfile) -> String {
        let notes = insights?.basedOnPreviousTranscript == true ? nil : insights?.partNotes
        return ChatOverview.make(notes: notes, summary: insights?.summary, actionItems: insights?.actionItems ?? [],
                                 budget: profile.overviewTokens, countTokens: ChatEngineProfile.estimateTokens)
    }

    /// Reads the insights sidecar once (never `Recording.partNotes`, which can be
    /// stale after a retry). A missing or unreadable sidecar means no overview.
    private func loadInsightsIfNeeded() async {
        guard !didLoadInsights else { return }
        didLoadInsights = true
        guard let insightsURL else { return }
        do {
            insights = try await InsightsStore().load(from: insightsURL)
        } catch {
            Logger.ai.warning("Chat: insights sidecar unreadable, no overview: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The chat index, built once per session (a failed build is retried by the next
    /// question). The build runs in its own task so
    /// stopping a question doesn't abandon it (the next question reuses it), and a
    /// later question waits for the same build instead of starting a second one.
    private func ensureIndex() async -> ChatIndex? {
        if let chatIndex { return chatIndex }
        if indexTask == nil {
            guard let indexURL, let plugin = localPlugin, !chatTurns.isEmpty else { return nil }
            let windows = TranscriptRetrieval.windows(chatTurns, targetTokens: 350, overlapTurns: 1,
                                                      countTokens: ChatEngineProfile.estimateTokens)
            let store = chatIndexStore
            indexTask = Task { [weak self] in
                do {
                    return try await store.index(for: windows, at: indexURL) { [weak self] texts in
                        // Only when embedding runs, not when a saved index loads.
                        await self?.showIndexingStatus()
                        return try await plugin.embed(texts, role: .document)
                    }
                } catch {
                    if Task.isCancelled { return nil } // retired session
                    Logger.ai.warning("Chat index unavailable, using keyword search only: \(error.localizedDescription, privacy: .public)")
                    return ChatIndex(windows: windows, vectors: [], model: "none") // BM25-only, never saved
                }
            }
        }
        guard let task = indexTask else { return nil }
        let index = await task.value
        indexingStatus = nil
        if indexTask == task { indexTask = nil }
        // The BM25-only fallback answers this question; the next one retries the build.
        if let index, index.dims > 0, !invalidated { chatIndex = index }
        return index
    }

    private func showIndexingStatus() {
        guard !invalidated else { return }
        indexingStatus = "Preparing chat for this long recording… (the first time downloads a ~480 MB on-device search model)"
    }

    /// Transcript excerpts for one question: cosine (when the index has vectors)
    /// and BM25 rankings fused with RRF, with neighbours, within the excerpt budget.
    private func excerpts(for question: String, profile: ChatEngineProfile) async -> String {
        guard let index = await ensureIndex() else { return "" }
        let vectors = index.vectors
        var queryVector: [Float]?
        if !vectors.isEmpty, let plugin = localPlugin {
            do {
                queryVector = try await plugin.embed([question], role: .query).first
            } catch {
                Logger.ai.warning("Chat query embedding failed, using keyword search only: \(error.localizedDescription, privacy: .public)")
            }
        }
        return TranscriptRetrieval.hybridExcerpts(question: question, queryVector: queryVector, windows: index.windows,
                                                  vectors: vectors, budgetTokens: profile.excerptTokens,
                                                  countTokens: ChatEngineProfile.estimateTokens)
    }

    /// Complete Q&A pairs before the in-flight question (excludes the just-appended
    /// user message and assistant placeholder).
    private var priorHistory: [ChatTurnMessage] {
        Self.modelHistory(from: Array(messages.dropLast(2)))
    }

    /// Q&A pairs fed to the model. A stopped scan or an "Error: …" reply is not an
    /// answer: its content maps to "", so `history(from:)` drops the pair.
    nonisolated static func modelHistory(from messages: [ChatMessage]) -> [ChatTurnMessage] {
        ChatContextPlanner.history(from: messages.map { message in
            let notAnAnswer = message.role == .assistant
                && (message.content == scanStoppedNote || message.content.hasPrefix("Error: "))
            return (role: message.role == .user ? ChatTurnMessage.Role.user : .assistant,
                    content: notAnAnswer ? "" : message.content)
        })
    }

    /// Apple Intelligence chat: a fresh session per question, sized by its profile. The
    /// whole transcript when it fits; otherwise the overview + excerpts for the question,
    /// plus compact history. One overflow retry with a shrunk profile.
    private func appleStream(question: String, history: [ChatTurnMessage],
                             sendID: UUID) async -> AsyncThrowingStream<String, Error> {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            await loadInsightsIfNeeded()
            var attempt: AppleChatAttempt = .first
            while true {
                guard !invalidated, !Task.isCancelled, activeSendID == sendID else { return errorStream("Cancelled") }
                let baseProfile = AppleChatBackend.profile
                let profile = attempt == .first ? baseProfile : baseProfile.shrunk()
                let historyText = ChatContextPlanner.compactHistory(history, budget: profile.historyTokens,
                                                                    countTokens: ChatEngineProfile.estimateTokens)
                let transcript = transcriptProvider()
                let overviewText = Self.overview(insights: insights, profile: profile)
                let instructions: String
                let prompt: String
                let transcriptTokens = await AppleChatBackend.tokenCount(transcript)
                switch Self.chatMode(transcriptTokens: transcriptTokens, profile: profile,
                                     hasOverview: !overviewText.isEmpty, canRetrieve: !chatTurns.isEmpty) {
                case .fullTranscript where transcriptTokens <= profile.fullTranscriptTokens:
                    coverage = .full
                    instructions = fullTranscriptSystemPrompt(transcript)
                    prompt = ChatContextPlanner.freshSessionPrompt(history: historyText, excerpts: "", question: question)
                case .fullTranscript:
                    // Too long and nothing to retrieve from (live chat): the most recent part.
                    coverage = .relevantParts
                    let budget = attempt == .first ? profile.fullTranscriptTokens : profile.fullTranscriptTokens / 2
                    instructions = fullTranscriptSystemPrompt(AppleChatContext.recentTail(
                        transcript, budgetTokens: budget, countTokens: ChatEngineProfile.estimateTokens),
                                                              recentPartOnly: true)
                    prompt = ChatContextPlanner.freshSessionPrompt(history: historyText, excerpts: "", question: question)
                case .overviewAndRetrieval, .retrievalOnly:
                    coverage = .relevantParts
                    instructions = ChatContextPlanner.longModeSystemPrompt(overview: overviewText,
                                                                          speakerLegend: speakerLegendText)
                    let found = await excerpts(for: question, profile: profile)
                    prompt = ChatContextPlanner.freshSessionPrompt(history: historyText, excerpts: found, question: question)
                }
                guard !invalidated, !Task.isCancelled, activeSendID == sendID else { return errorStream("Cancelled") }
                do {
                    let answer = try await AppleChatBackend.respond(instructions: instructions, prompt: prompt)
                    return AsyncThrowingStream { continuation in
                        continuation.yield(answer)
                        continuation.finish()
                    }
                } catch {
                    guard let next = AppleChatAttempt.next(after: error, attempt: attempt,
                                                           isOverflow: AppleChatBackend.isContextOverflow) else {
                        if !Task.isCancelled {
                            let kind = AppleGenerationFailure.classify(error)?.description ?? String(describing: type(of: error))
                            Logger.ai.warning("Apple Intelligence chat failed (\(kind, privacy: .public))")
                        }
                        return errorStream(AppleChatBackend.userMessage(for: error))
                    }
                    Logger.ai.info("Apple Intelligence chat overflowed; retrying with a smaller context")
                    attempt = next
                }
            }
        }
        #endif
        return errorStream("Apple Intelligence requires macOS 26 or later")
    }

    // MARK: - Whole-recording scan ("Check the whole recording")

    nonisolated static let scanStoppedNote = "Stopped. The whole-recording check was cancelled before it finished, so there is no answer."

    private enum ScanEngine {
        case gemma(LocalAIPluginService)
        case appleIntelligence
    }

    /// A scan failure whose message is already user-facing.
    private struct ScanFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Answers `question` from every part of the transcript, not just the retrieved
    /// excerpts: each part (sized by the engine's `scanPartTokens`) is asked for its
    /// evidence, non-NONE findings are kept, and the answer is written from them,
    /// one group at a time when they don't fit one prompt. Persisted like any exchange.
    func scanWholeRecording(for question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        await runExclusive(trimmed) { sendID in await self.scanInRecordingContext(trimmed, sendID: sendID) }
    }

    private func clearScanState() {
        scanProgress = nil
        scanStatus = nil
        scanAssistantID = nil
    }

    /// Throws when this scan was stopped, superseded, or its session retired.
    private func checkScan(_ sendID: UUID) throws {
        guard !invalidated, !Task.isCancelled, activeSendID == sendID else { throw CancellationError() }
    }

    private func scanEngine() throws -> (engine: ScanEngine, profile: ChatEngineProfile) {
        switch resolvedChatEngine {
        case .qwenLocal:
            guard let plugin = localPlugin else { throw ScanFailure(message: "Local AI plugin not available") }
            return (.gemma(plugin), .gemma)
        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(macOS 26, *) { return (.appleIntelligence, AppleChatBackend.profile) }
            #endif
            throw ScanFailure(message: "Apple Intelligence requires macOS 26 or later")
        case .remoteEndpoint, .localCLI:
            throw ScanFailure(message: "Checking the whole recording needs Gemma or Apple Intelligence as the chat engine.")
        }
    }

    private func scanInRecordingContext(_ question: String, sendID: UUID) async {
        guard !question.isEmpty, activeSendID == sendID else { return }
        await loadTask?.value
        guard !invalidated, !Task.isCancelled, activeSendID == sendID else { return }

        messages.append(ChatMessage(role: .user, content: question))
        let placeholder = ChatMessage(role: .assistant, content: "")
        let assistantID = placeholder.id
        messages.append(placeholder)
        scanAssistantID = assistantID
        coverage = nil // no "relevant parts" footer while the scan answer streams
        scanFootnote = nil
        var usesApple = false

        func publish(_ text: String) {
            guard let idx = messages.lastIndex(where: { $0.id == assistantID }) else { return }
            messages[idx].content = text
        }

        do {
            let (engine, profile) = try scanEngine()
            if case .appleIntelligence = engine { usesApple = true }
            let parts = TranscriptChunkPlanner.plan(transcriptProvider(), maxTokensPerChunk: profile.scanPartTokens,
                                                    overlapLines: 1, countTokens: ChatEngineProfile.estimateTokens)

            // Map: evidence per part. Findings live only here, so a stopped scan drops them.
            var findings: [(part: TranscriptChunk, text: String)] = []
            var declinedParts = 0
            for part in parts {
                try checkScan(sendID)
                scanProgress = (part.index, part.total)
                scanStatus = "Checking part \(part.index) of \(part.total)…"
                let texts: [String]
                switch engine {
                case .gemma(let plugin):
                    let prompt = ChatContextPlanner.scanPartPrompt(question: question, part: part)
                    texts = [try await gemmaText(plugin, system: prompt.system, user: prompt.user, sendID: sendID).text]
                case .appleIntelligence:
                    #if canImport(FoundationModels)
                    if #available(macOS 26, *) {
                        let result = try await appleScanPart(question: question, part: part, sendID: sendID)
                        texts = result.texts
                        if result.declined { declinedParts += 1 }
                    } else { texts = [] }
                    #else
                    texts = []
                    #endif
                }
                for text in texts {
                    let answer = ChatMessage(role: .assistant, content: text).displayParts.answer // drop <think>
                    if !answer.isEmpty, !ChatContextPlanner.isNoneFinding(answer) { findings.append((part, answer)) }
                }
            }
            try checkScan(sendID)
            if declinedParts > 0 {
                Logger.ai.info("Whole-recording scan: Apple Intelligence declined \(declinedParts, privacy: .public) of \(parts.count, privacy: .public) parts")
            }

            // Reduce: answer from the findings, per group when they don't fit one prompt.
            scanProgress = nil
            scanStatus = "Writing the answer from what was found…"
            var budget = profile.scanFindingsTokens
            var answer = ""
            var evidenceShortened = false
            answerLoop: while true {
                let grouped = ChatContextPlanner.scanFinalPromptsReport(
                    question: question, findings: findings, budget: budget, countTokens: ChatEngineProfile.estimateTokens)
                let prompts = grouped.prompts
                evidenceShortened = grouped.clipped
                answer = ""
                do {
                    for prompt in prompts {
                        let heading = prompt.label.isEmpty ? "" : (answer.isEmpty ? "" : "\n\n") + "**\(prompt.label)**\n\n"
                        switch engine {
                        case .gemma(let plugin):
                            let prefix = answer + heading
                            let result = try await gemmaText(plugin, system: prompt.system, user: prompt.user,
                                                             sendID: sendID) { publish(prefix + $0) }
                            answer = prefix + result.text
                            if let reason = result.stopReason { streamingNotice = reason.message }
                        case .appleIntelligence:
                            #if canImport(FoundationModels)
                            if #available(macOS 26, *) {
                                let text = try await AppleChatBackend.respond(instructions: prompt.system, prompt: prompt.user)
                                try checkScan(sendID)
                                answer += heading + text
                                publish(answer)
                            }
                            #endif
                        }
                    }
                    break answerLoop
                } catch {
                    // Estimated tokens can undercount: regroup once at half the budget.
                    guard usesApple, budget == profile.scanFindingsTokens, isAppleOverflow(error) else { throw error }
                    try checkScan(sendID)
                    Logger.ai.info("Whole-recording scan: answer step overflowed; regrouping findings")
                    publish("") // drop answers of the abandoned grouping
                    budget /= 2
                }
            }
            try checkScan(sendID)
            if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ScanFailure(message: "The model returned an empty answer.")
            }
            publish(answer)
            coverage = .full
            var note = "Checked the whole recording."
            if declinedParts > 0 {
                note += " Apple Intelligence declined to read \(declinedParts) of \(parts.count) parts, so anything in them may be missing."
            }
            if evidenceShortened { note += " Some long evidence was shortened." }
            scanFootnote = (assistantID, note)
        } catch {
            guard !invalidated, !Task.isCancelled, activeSendID == sendID,
                  messages.contains(where: { $0.id == assistantID }) else { return }
            let message: String
            if let failure = error as? ScanFailure {
                message = failure.message
            } else if usesApple {
                message = appleUserMessage(for: error)
            } else {
                message = error.localizedDescription
            }
            streamingError = message
            coverage = nil
            publish("Error: \(message)")
        }
    }

    /// One prompt through Gemma's ONE-SHOT `chatStream`, never `chatTurn`: scan prompts
    /// must not enter the warm chat session. The helper runs `chatStream` with
    /// `keepChat: false`, which drops that warm session, so the next normal question
    /// rebuilds it (a one-time prefill); the scan itself never reads or extends it.
    private func gemmaText(_ plugin: LocalAIPluginService, system: String, user: String, sendID: UUID,
                           onText: (String) -> Void = { _ in }) async throws
        -> (text: String, stopReason: ChatResponseLimiter.StopReason?) {
        var limiter = ChatResponseLimiter()
        var text = ""
        for try await chunk in await plugin.chatStream(systemPrompt: system, userMessage: user) {
            try checkScan(sendID) // Stop cancels inside a part, not only between parts
            text += limiter.append(chunk)
            onText(text)
            if limiter.stopReason != nil { break }
            await Task.yield()
        }
        try checkScan(sendID)
        return (text, limiter.stopReason)
    }

    private func isAppleOverflow(_ error: Error) -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return AppleGenerationFailure.classify(error) == .overflow }
        #endif
        return false
    }

    private func appleUserMessage(for error: Error) -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return AppleChatBackend.userMessage(for: error) }
        #endif
        return error.localizedDescription
    }

    #if canImport(FoundationModels)
    /// One part on Apple Intelligence. An overflowing part is re-split once with the
    /// planner (into roughly halves) and each piece asked; a piece that still overflows
    /// fails the scan loudly, so no part is ever skipped. A refusal or guardrail counts
    /// as "no findings" for that part (`declined`), never as a failed scan.
    @available(macOS 26, *)
    private func appleScanPart(question: String, part: TranscriptChunk,
                               sendID: UUID) async throws -> (texts: [String], declined: Bool) {
        /// nil when the model declined the piece.
        func ask(_ piece: TranscriptChunk) async throws -> String? {
            let prompt = ChatContextPlanner.scanPartPrompt(question: question, part: piece)
            do {
                let text = try await AppleChatBackend.respond(instructions: prompt.system, prompt: prompt.user)
                try checkScan(sendID)
                return text
            } catch {
                switch AppleGenerationFailure.classify(error) {
                case .refusal?, .guardrail?:
                    try checkScan(sendID)
                    return nil
                default:
                    throw error
                }
            }
        }
        do {
            guard let text = try await ask(part) else { return ([], true) }
            return ([text], false)
        } catch where AppleGenerationFailure.classify(error) == .overflow {
            try checkScan(sendID)
            let tokens = ChatEngineProfile.estimateTokens(part.text)
            // Pieces keep the part's own "PART i OF n" label; the planner splits on line boundaries.
            let pieces = TranscriptChunkPlanner.plan(part.text, maxTokensPerChunk: max(1, tokens * 55 / 100), overlapLines: 0,
                                                     countTokens: ChatEngineProfile.estimateTokens)
                .map { TranscriptChunk(index: part.index, total: part.total, text: $0.text) }
            Logger.ai.info("Whole-recording scan: part overflowed; retrying it as \(pieces.count, privacy: .public) pieces")
            var texts: [String] = []
            var declined = false
            for piece in pieces {
                try checkScan(sendID)
                do {
                    if let text = try await ask(piece) { texts.append(text) } else { declined = true }
                } catch where !(error is CancellationError) && !Task.isCancelled {
                    throw ScanFailure(message: "Checking the whole recording stopped at part \(part.index) of \(part.total). "
                                      + AppleChatBackend.userMessage(for: error))
                }
            }
            return (texts, declined)
        }
    }
    #endif

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
