import Foundation
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
    let speechPlayer = VoicePreviewPlayer()
    private(set) var spokenMessageID: UUID?
    private var speechTask: Task<Void, Never>?

    func copyAnswer(_ message: ChatMessage) async -> Bool {
        await RecordingClipboard.copy(message.displayParts.answer, contextProvider: {
            await self.privacyRecording?.privacyContext()
        })
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

    /// Captured synchronously for each immutable evidence request.
    private var contextProvider: TranscriptContextProvider
    private let appSettings: AppSettings
    private let localPlugin: LocalAIPluginService?
    private let aiService: AIService
    private let resourceAdmission: LiveModelJobAdmission?
    private let privacyRecording: Recording?

    /// On-disk persistence handle. Set via `enablePersistence`; nil for sessions
    /// that have no stable sidecar location yet (e.g. a still-recording live
    /// session, until it finishes and rebinds to the authoritative transcript).
    private var chatStore: ChatStore?
    private var persistenceURL: URL?
    private var saveTask: Task<Void, Never>?
    /// The in-flight initial load from disk. `send()` awaits it so a fast typist
    /// can't append to an empty conversation before persisted history arrives
    /// (which would no-op the load and overwrite the saved file).
    private var loadTask: Task<ChatHistory?, Never>?
    private var conversationGeneration: UInt64 = 0
    /// True when `messages` has changed since the last successful write — lets
    /// `flushPendingSave()` skip a redundant write on quit when nothing is dirty.
    private var hasUnsavedChanges = false
    private var invalidated = false
    private let validity = RecordingDerivativeValidity()
    private var sendTask: Task<TranscriptChatSendResult, Never>?
    private var activeSendID: UUID?

    /// Retire this session without deleting the currently published conversation.
    /// A retired session can never republish derivatives after an attempt unlocks.
    func invalidateForReprocessing() {
        stopReading()
        invalidated = true
        conversationGeneration &+= 1
        validity.invalidate()
        sendTask?.cancel()
        saveTask?.cancel()
        loadTask?.cancel()
        sendTask = nil
        activeSendID = nil
        saveTask = nil
        loadTask = nil
        chatStore = nil
        persistenceURL = nil
        hasUnsavedChanges = false
        isStreaming = false
    }

    init(
        contextProvider: TranscriptContextProvider,
        appSettings: AppSettings,
        localPlugin: LocalAIPluginService?,
        recording: Recording? = nil,
        aiService: AIService = AIService()
    ) {
        self.contextProvider = contextProvider
        self.appSettings = appSettings
        self.localPlugin = localPlugin
        self.resourceAdmission = localPlugin?.connection.resourceAdmission
        self.privacyRecording = recording
        self.aiService = aiService
        Self.activeServices.removeAll { $0.value == nil }
        Self.activeServices.append(WeakService(self))
    }

    convenience init(
        transcriptProvider: @escaping @MainActor () -> String,
        speakerLabels: [SpeakerLabel], appSettings: AppSettings,
        localPlugin: LocalAIPluginService?, recording: Recording? = nil, aiService: AIService = AIService()
    ) {
        let recordingID = recording?.id
        self.init(contextProvider: .value {
            .legacy(text: transcriptProvider(), recordingID: recordingID, speakerLabels: speakerLabels)
        }, appSettings: appSettings, localPlugin: localPlugin, recording: recording, aiService: aiService)
    }

    /// Convenience init for a fixed (completed-recording) transcript.
    convenience init(
        transcriptText: String,
        speakerLabels: [SpeakerLabel],
        appSettings: AppSettings,
        localPlugin: LocalAIPluginService?,
        recording: Recording? = nil,
        aiService: AIService = AIService()
    ) {
        self.init(
            transcriptProvider: { transcriptText },
            speakerLabels: speakerLabels,
            appSettings: appSettings,
            localPlugin: localPlugin,
            recording: recording,
            aiService: aiService
        )
    }

    @discardableResult
    func send(_ userText: String, onAccepted: (@MainActor () -> Void)? = nil) async -> TranscriptChatSendResult {
        guard !invalidated, !Task.isCancelled, sendTask == nil,
              !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isStreaming else { return .notAccepted }
        // Capture mutable owners and settings before the first suspension.
        let frozenProvider = contextProvider.freeze()
        let route = FrozenChatRoute(settings: appSettings)
        let language = appSettings.outputLanguage
        let question = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let priorMessages = messages, initialLoad = loadTask, generation = conversationGeneration
        let sendID = UUID()
        activeSendID = sendID
        isStreaming = true
        streamingError = nil
        streamingNotice = nil
        let task = Task { [weak self] () -> TranscriptChatSendResult in
            guard let self, self.accepts(sendID, generation: generation) else { return .notAccepted }
            do {
                // The captured provider's atomic snapshot is the first evidence operation.
                let snapshot = try await frozenProvider.snapshot()
                guard self.accepts(sendID, generation: generation), !Task.isCancelled else { return .notAccepted }
                if let owner = self.privacyRecording?.id, snapshot.source.recordingID != owner {
                    throw TranscriptContextError.recordingMismatch
                }
                guard !snapshot.segments.isEmpty else {
                    self.streamingNotice = "Waiting for transcript"
                    return .waitingForTranscript
                }
                let loaded = await initialLoad?.value
                guard self.accepts(sendID, generation: generation), !Task.isCancelled else { return .notAccepted }
                let history = priorMessages.isEmpty ? (loaded?.messages ?? []) : priorMessages
                let assistantID = UUID()
                let build = Task.detached(priority: .userInitiated) {
                    try TranscriptContextBuilder.build(snapshot: snapshot, route: route.basis, budget: route.budget,
                        language: language, question: question, history: history, answerID: assistantID)
                }
                let prepared = try await withTaskCancellationHandler { try await build.value } onCancel: { build.cancel() }
                let context = await self.privacyRecording?.privacyContext()
                guard self.accepts(sendID, generation: generation), !Task.isCancelled else { return .notAccepted }
                return await PrivacyTrace.$context.withValue(context) {
                    await self.sendInRecordingContext(question, prepared: prepared, route: route,
                        history: history, assistantID: assistantID, sendID: sendID, generation: generation, onAccepted: onAccepted)
                }
            } catch {
                guard self.accepts(sendID, generation: generation), !Task.isCancelled else { return .notAccepted }
                if (error as? TranscriptContextError) == .waitingForTranscript {
                    self.streamingNotice = "Waiting for transcript"; return .waitingForTranscript
                }
                self.streamingError = error.localizedDescription
                return .notAccepted
            }
        }
        sendTask = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        // A stopped request may unwind after the user has already sent another.
        guard activeSendID == sendID else { return result }
        sendTask = nil
        activeSendID = nil
        isStreaming = false
        scheduleSave()
        return result
    }

    private func accepts(_ sendID: UUID, generation: UInt64) -> Bool {
        !invalidated && activeSendID == sendID && conversationGeneration == generation
    }

    private func sendInRecordingContext(_ question: String, prepared: PreparedTranscriptChat, route: FrozenChatRoute,
        history: [ChatMessage], assistantID: UUID, sendID: UUID, generation: UInt64,
        onAccepted: (@MainActor () -> Void)?) async -> TranscriptChatSendResult {
        guard accepts(sendID, generation: generation), !Task.isCancelled else { return .notAccepted }
        messages = history
        messages.append(ChatMessage(role: .user, content: question))
        var assistantMessage = ChatMessage(id: assistantID, role: .assistant, content: "", basis: prepared.basis, outcome: .streaming)
        messages.append(assistantMessage)
        let assistantIdx = messages.count - 1
        onAccepted?()
        guard accepts(sendID, generation: generation), !Task.isCancelled else { return .accepted }
        var limiter = ChatResponseLimiter()

        do {
            let stream = await buildStream(prepared: prepared, route: route)
            for try await chunk in stream {
                guard accepts(sendID, generation: generation),
                      messages.indices.contains(assistantIdx), messages[assistantIdx].id == assistantMessage.id else { return .accepted }
                if Task.isCancelled { assistantMessage.outcome = .interrupted; break }
                assistantMessage.content += limiter.append(chunk)
                messages[assistantIdx] = assistantMessage
                if let reason = limiter.stopReason {
                    streamingNotice = reason.message
                    assistantMessage.outcome = .limited
                    sendTask?.cancel()
                    break
                }
                // Buffered tokens must not monopolize the main actor and starve Stop.
                await Task.yield()
            }
            if assistantMessage.outcome == .streaming {
                assistantMessage.outcome = Task.isCancelled ? .interrupted : .completed
            }
        } catch {
            guard accepts(sendID, generation: generation),
                  messages.indices.contains(assistantIdx), messages[assistantIdx].id == assistantMessage.id else { return .accepted }
            if Task.isCancelled || error is CancellationError {
                assistantMessage.outcome = .interrupted
                streamingNotice = "Stopped generating."
            } else if let end = ChatStreamEndError.classify(error) {
                assistantMessage.outcome = end == .truncated ? .truncated : .unconfirmed
                streamingNotice = end.localizedDescription
            } else {
                assistantMessage.outcome = .failed
                streamingError = error.localizedDescription
                if assistantMessage.content.isEmpty { assistantMessage.content = "Error: \(error.localizedDescription)" }
                else { streamingNotice = "Response interrupted: \(error.localizedDescription)" }
            }
        }
        guard accepts(sendID, generation: generation),
              messages.indices.contains(assistantIdx), messages[assistantIdx].id == assistantMessage.id else { return .accepted }
        assistantMessage.referenceResolution = ChatReferenceParser.resolve(assistantMessage.rawAnswerText, basis: prepared.basis)
        messages[assistantIdx] = assistantMessage
        return .accepted
    }

    func stopGenerating() {
        guard let task = sendTask else { return }
        activeSendID = nil
        sendTask = nil
        isStreaming = false
        task.cancel()
        streamingNotice = "Stopped generating."
        if let index = messages.indices.last, messages[index].role == .assistant,
           messages[index].outcome == .streaming {
            messages[index].outcome = .interrupted
            if let basis = messages[index].basis {
                messages[index].referenceResolution = ChatReferenceParser.resolve(messages[index].rawAnswerText, basis: basis)
            }
        }
        if messages.last?.role == .assistant, messages.last?.content.isEmpty == true {
            messages.removeLast()
        }
        // Save from the user's action, before the cancelled task unwinds.
        scheduleSave()
    }

    func clearMessages() {
        guard !invalidated, !isStreaming else { return }
        stopReading()
        conversationGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
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
    func startLoadingPersisted(load: (@Sendable () async throws -> ChatHistory?)? = nil) {
        guard !invalidated else { return }
        loadTask?.cancel()
        let generation = conversationGeneration
        let store = chatStore, url = persistenceURL
        loadTask = Task { [weak self] in
            let history: ChatHistory?
            if let load { history = try? await load() }
            else if let store, let url { history = try? await store.load(from: url) }
            else { history = nil }
            guard let self, !self.invalidated, !Task.isCancelled, self.conversationGeneration == generation else { return nil }
            if self.messages.isEmpty, let history { self.messages = history.messages }
            return history
        }
    }

    /// Adopt a previously-saved conversation from disk. No-op if persistence
    /// isn't enabled, the sidecar is absent/empty, or this session already has
    /// messages (an in-progress live chat must not be clobbered by an old file).
    func loadPersisted() async {
        guard !invalidated, messages.isEmpty else { return }
        startLoadingPersisted()
        _ = await loadTask?.value
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
        let history = ChatHistory(messages: messages, engine: lastAnswerEngine)
        try? await chatStore.save(history, to: persistenceURL, validity: validity)
        hasUnsavedChanges = false
    }

    /// Debounced write of the current conversation. Coalesces rapid exchanges
    /// into a single atomic save and snapshots `messages` on the main actor so
    /// the actor write sees a consistent value.
    private func scheduleSave() {
        guard !invalidated, let chatStore, let persistenceURL, !messages.isEmpty else { return }
        hasUnsavedChanges = true
        let snapshot = messages
        let engine = lastAnswerEngine
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
        let recordingID = privacyRecording?.id
        contextProvider = .value { .legacy(text: text, recordingID: recordingID, speakerLabels: speakerLabels) }
    }

    func rebindContextProvider(_ provider: TranscriptContextProvider) { contextProvider = provider }

    private var lastAnswerEngine: String? { messages.last(where: { $0.basis != nil })?.basis?.route.engine }

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
        let resources = resourceAdmission?.policy
        Task { @MainActor in
            // prewarm has no awaitable native-return receipt. An immutable
            // eligible live catalog therefore disables this optional operation.
            guard await resources?.hasProfiles != true else { return }
            if #available(macOS 26, *) { LanguageModelSession().prewarm() }
        }
        #endif
    }

    // MARK: - Private

    private func buildStream(prepared: PreparedTranscriptChat, route: FrozenChatRoute) async -> AsyncThrowingStream<String, Error> {
        let systemPrompt = prepared.systemPrompt, userMessage = prepared.userMessage
        switch route.engine {
        case .localCLI:
            return errorStream("Local CLI does not support chat. Choose a chat fallback engine in Settings → AI Analysis.")
        case .qwenLocal:
            guard let plugin = localPlugin else { return errorStream("Local AI plugin not available") }
            return await plugin.chatStream(systemPrompt: systemPrompt, userMessage: userMessage)
        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                let permit: LiveResourceJobLease?
                do { permit = try await resourceAdmission?.acquire(owner: UUID(), job: .localChat(model: "apple-intelligence"), wait: false) }
                catch { return AsyncThrowingStream { $0.finish(throwing: error) } }
                let resources = resourceAdmission?.policy
                return AsyncThrowingStream { continuation in
                    let task = Task {
                        // Admission lasts through actual native return, including cancellation.
                        defer { if let permit { Task { await resources?.releaseJob(permit) } } }
                        do {
                            try Task.checkCancellation()
                            if #available(macOS 26.4, *) {
                                let model = SystemLanguageModel.default
                                let instructions = try await model.tokenCount(for: Instructions(systemPrompt))
                                let prompt = try await model.tokenCount(for: userMessage)
                                guard instructions <= route.budget.inputAllowance,
                                      prompt <= route.budget.inputAllowance - instructions,
                                      instructions + prompt + route.budget.outputTokens + route.budget.templateReserve <= model.contextSize else {
                                    throw TranscriptContextError.noEvidenceFits
                                }
                            }
                            let session = LanguageModelSession(instructions: systemPrompt)
                            let options = GenerationOptions(temperature: 0.5, maximumResponseTokens: route.budget.outputTokens)
                            let response = try await PrivacyTrace.perform(.init(stage: .chat, data: [.text, .metadata], destination: .local(provider: .appleIntelligence))) {
                                try await session.respond(to: userMessage, options: options)
                            }
                            try Task.checkCancellation()
                            continuation.yield(response.content)
                            // This SDK's response has no stop-vs-length terminal fact.
                            // Preserve output but never manufacture a completed-history fact.
                            continuation.finish(throwing: ChatStreamEndError.unconfirmed)
                        } catch { continuation.finish(throwing: error) }
                    }
                    continuation.onTermination = { @Sendable _ in task.cancel() }
                }
            }
            #endif
            return errorStream("Apple Intelligence requires macOS 26 or later")
        case .remoteEndpoint:
            guard let endpoint = route.endpoint else { return errorStream("No AI endpoint configured. Add one in Settings → AI.") }
            return aiService.streamChat(systemPrompt: systemPrompt, userMessage: userMessage, endpoint: endpoint)
        }
    }

    private func errorStream(_ message: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: NSError(domain: "TranscriptChatService", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]))
        }
    }
}

enum TranscriptChatSendResult: Equatable { case accepted, waitingForTranscript, notAccepted }

/// Transient request routing holds credentials only for dispatch. Basis is nonsecret.
private struct FrozenChatRoute: Sendable {
    let engine: AppSettings.AIEngine
    let endpoint: Endpoint?
    let basis: ChatRouteBasis
    let budget: ChatContextBudget

    @MainActor init(settings: AppSettings) {
        engine = settings.effectiveAIEngine == .localCLI ? settings.chatFallbackEngine : settings.effectiveAIEngine
        var selected = engine == .remoteEndpoint ? settings.effectiveDefaultAIEndpoint : nil
        let output: Int, context: Int
        switch engine {
        case .appleIntelligence: output = 512; context = 4_096
        case .qwenLocal: output = ChatGenerationPolicy.maximumOutputTokens; context = ChatGenerationPolicy.applicationContextTokens
        case .remoteEndpoint:
            output = min(selected?.resolvedMaxOutputTokens ?? 4_096, 4_096); context = 16_384
            selected?.maxOutputTokens = output
        case .localCLI: output = 512; context = 4_096
        }
        endpoint = selected
        budget = .init(contextTokens: context, outputTokens: output, templateReserve: 256)
        var origin: String?
        if let selected, let url = URLComponents(string: selected.baseURL), let scheme = url.scheme, let host = url.host {
            var sanitized = URLComponents(); sanitized.scheme = scheme; sanitized.host = host; sanitized.port = url.port
            origin = sanitized.string
        }
        basis = .init(engine: engine.rawValue, endpointID: selected?.id, provider: selected?.provider.rawValue,
                      origin: origin, model: selected?.modelName ?? (engine == .qwenLocal ? ChatGenerationPolicy.modelID : nil))
    }
}
