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
        // Lifetime: the ChatSession (KV cache) and the ModelContainer are only ever
        // held as locals inside `prepareSession`/`streamTurn`, which have returned
        // or thrown before `drop()` runs below. So on the error path the stored
        // `session` is the last strong reference; `drop()` nils it before
        // `insights.unload()` clears MLX's buffer cache, and the multi-GB buffers
        // are freed before that clear, not parked in the cache afterwards.
        try await prepareSession(systemPrompt: systemPrompt, history: history)
        // Only after a successful load: a failed load leaves any idle drop scheduled.
        idleTask?.cancel()
        idleTask = nil
        let prompt = retrievedContext.isEmpty ? question : retrievedContext + "\n\nQUESTION: " + question
        let answer: String
        do {
            answer = try await streamTurn(prompt, onDelta: onDelta)
        } catch {
            await drop()                       // unknown KV state after an error → rebuild next time
            throw error
        }
        key?.record(question: question, answer: answer)
        scheduleIdleDrop()
    }

    /// Keeps the live session when the key continues; otherwise rebuilds it from `history`.
    private func prepareSession(systemPrompt: String, history: [ChatTurnMessage]) async throws {
        let container = try await insights.loadForChat()
        if session != nil, let key, key.canContinue(systemPrompt: systemPrompt, history: history) { return }
        Logger.ai.info("Gemma chat: rebuilding session (history \(history.count) messages)")
        let replay = history.map { m -> Chat.Message in
            m.role == .user ? .user(m.content) : .assistant(m.content)
        }
        session = ChatSession(container, instructions: systemPrompt, history: replay,
                              generateParameters: insights.chatGenerationParameters())
        key = ChatSessionCacheKey(systemPrompt: systemPrompt, history: history)
    }

    /// Streams one turn on the stored session. Throws on error or cancellation,
    /// always after `synchronize()`, so a half-answered turn is never recorded.
    private func streamTurn(_ prompt: String, onDelta: @Sendable (String) -> Void) async throws -> String {
        guard let session else { throw CancellationError() }   // unreachable: prepareSession set it
        // ChatSession is not Sendable; synchronize() is a nonisolated async call.
        // Safe: the session is only touched under the orchestrator mutex, one turn at a time.
        nonisolated(unsafe) let chat = session
        var answer = ""
        do {
            // A request cancelled during a cold load must not start GPU work.
            try Task.checkCancellation()
            for try await chunk in chat.streamResponse(to: prompt) {
                answer += chunk
                onDelta(chunk)
            }
            // A cancelled stream may end without throwing; treat it as a failure.
            try Task.checkCancellation()
        } catch {
            await chat.synchronize()
            throw error
        }
        await chat.synchronize()
        return answer
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
