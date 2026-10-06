import Foundation
import OSLog
import dBriefWire
import MLXLMCommon

/// One live Gemma chat session kept warm between turns, so a follow-up question
/// only prefills the new turn instead of the whole transcript again. Dropped
/// after `idleTimeout`, or by any other model operation (see
/// `MLOrchestrator.withModelAccess(keepChat:)`).
///
/// Not self-locking: callers serialize `respond`/`drop` through the
/// orchestrator's model mutex. The idle drop therefore does not call `drop()`
/// itself — it hands itself to `onIdle`, which the orchestrator implements by
/// taking that mutex first, so it can never unload under another operation.
actor GemmaChatSessions {
    static let idleTimeout: Duration = .seconds(300)

    private var session: ChatSession?
    private var key: ChatSessionCacheKey?
    private var idleTask: Task<Void, Never>?
    private let insights: MLXInsightsService
    private let idleTimeout: Duration
    private let onIdle: @Sendable (GemmaChatSessions) async -> Void

    init(insights: MLXInsightsService, idleTimeout: Duration = GemmaChatSessions.idleTimeout,
         onIdle: @escaping @Sendable (GemmaChatSessions) async -> Void) {
        self.insights = insights
        self.idleTimeout = idleTimeout
        self.onIdle = onIdle
    }

    /// Answers `question`, reusing the live session when its KV cache already
    /// holds `systemPrompt` + `history`; otherwise rebuilds it from `history`.
    /// `retrievedContext` is prepended to this turn only.
    func respond(systemPrompt: String, history: [ChatTurnMessage], question: String,
                 retrievedContext: String = "", onDelta: @Sendable (String) -> Void) async throws {
        idleTask?.cancel()
        idleTask = nil
        let container = try await insights.loadForChat()
        let live: ChatSession
        if let session, let key, key.canContinue(systemPrompt: systemPrompt, history: history) {
            live = session
        } else {
            Logger.ai.info("Gemma chat: rebuilding session (history \(history.count) messages)")
            let replay = history.map { m -> Chat.Message in
                m.role == .user ? .user(m.content) : .assistant(m.content)
            }
            live = ChatSession(container, instructions: systemPrompt, history: replay,
                               generateParameters: insights.chatGenerationParameters())
            session = live
            key = ChatSessionCacheKey(systemPrompt: systemPrompt, history: history)
        }
        // ChatSession is not Sendable; synchronize() is a nonisolated async call.
        // Safe: the session is only touched under the orchestrator mutex, one turn at a time.
        nonisolated(unsafe) let chat = live
        let prompt = retrievedContext.isEmpty ? question : retrievedContext + "\n\nQUESTION: " + question
        var answer = ""
        do {
            for try await chunk in chat.streamResponse(to: prompt) {
                answer += chunk
                onDelta(chunk)
            }
            // A cancelled stream may end without throwing; treat it as a failure
            // so a half-answered turn is never recorded in the key.
            try Task.checkCancellation()
        } catch {
            await chat.synchronize()
            await drop()                       // unknown KV state after an error → rebuild next time
            throw error
        }
        await chat.synchronize()
        key?.record(question: question, answer: answer)
        scheduleIdleDrop()
    }

    /// Releases the session, its KV cache and the Gemma model. Callers must hold
    /// the orchestrator's model mutex (or own the service exclusively, as the eval does).
    func drop() async {
        idleTask?.cancel()
        idleTask = nil
        let hadSession = session != nil
        session = nil
        key = nil
        if hadSession { await insights.unload() }
    }

    private func scheduleIdleDrop() {
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            Logger.ai.info("Gemma chat: idle timeout, unloading")
            await self.onIdle(self)
        }
    }
}
