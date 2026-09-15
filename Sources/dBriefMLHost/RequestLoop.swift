import Foundation
import dBriefWire

/// The seam the request router dispatches to. `MLOrchestrator` is the real
/// implementation; tests substitute a mock.
protocol MLBackend: Sendable {
    func transcribe(path: String, initialPrompt: String?, config: WhisperRuntimeConfig, safeMode: Bool, unloadAfter: Bool) async throws -> TranscriptionResult
    func diarize(path: String) async throws -> [DiarizedTurn]
    func diarizeWithEmbeddings(path: String) async throws -> (turns: [DiarizedTurn], embeddings: [String: [Float]])
    func analyze(text: String, outputLanguage: OutputLanguage, customVocabulary: String, guidance: InsightsGuidance?) async throws -> LocalInsightsResult
    func analyzeStream(text: String, outputLanguage: OutputLanguage, customVocabulary: String, guidance: InsightsGuidance?, emitToken: @Sendable (String) -> Void) async throws
    func chatStream(systemPrompt: String, userMessage: String, emitToken: @Sendable (String) -> Void) async throws
    func parakeetTranscribe(path: String, modelVariant: String, diarize: Bool) async throws -> TranscriptionResult
    func synthesizeSpeech(text: String, outputPath: String, voice: String?, language: String?, instruction: String?, model: String?, engine: String?) async throws -> SpeechSynthesisResult
    func prepareModels() async
    func downloadWhisper(config: WhisperRuntimeConfig) async throws
    func prewarmWhisper(config: WhisperRuntimeConfig, refresh: Bool) async throws
    func downloadLLM() async throws
    func downloadParakeet(variant: String) async throws
    func isWhisperCached(name: String) async -> Bool
    func isLLMCached() async -> Bool
    func isParakeetCached() async -> Bool
    func fetchWhisperModels(repo: String) async throws -> [String]
    func purgeModels() async throws
    func purgeWhisper() async throws
    func purgeSpeakerKit() async throws
    func purgeQwen() async throws
    func purgeParakeet() async throws
    func memoryPressurePurge() async
    func forceUnload() async
}

/// Maps one inbound request to backend calls and emits tagged events.
/// Channel selection: Parakeet ops use `.parakeet`; everything else `.plugin`.
final class RequestRouter: Sendable {
    private let backend: MLBackend
    private let emit: @Sendable (EventEnvelope) -> Void

    init(backend: MLBackend, emit: @escaping @Sendable (EventEnvelope) -> Void) {
        self.backend = backend
        self.emit = emit
    }

    func handle(_ envelope: RequestEnvelope) async {
        let id = envelope.id
        let channel: MLChannel = {
            switch envelope.request {
            case .parakeetTranscribe, .downloadParakeet, .isParakeetCached, .purgeParakeet: .parakeet
            default: .plugin
            }
        }()
        let emit = self.emit
        func send(_ event: MLEvent) { emit(EventEnvelope(id: id, channel: channel, event: event)) }
        // Self-contained @Sendable token sink for streaming ops (captures only Sendable values).
        let emitToken: @Sendable (String) -> Void = { token in
            emit(EventEnvelope(id: id, channel: channel, event: .token(token)))
        }

        await MLProgress.$sink.withValue({ state in
            emit(EventEnvelope(id: id, channel: channel, event: .state(state)))
        }) {
            await MLPrivacyTrace.$sink.withValue({ event in
                emit(EventEnvelope(id: id, channel: channel, event: .privacy(event)))
            }) {
                send(.privacy(.supported(version: 1)))
                do {
                    try Task.checkCancellation()
                    switch envelope.request {
                    case let .transcribe(path, prompt, config, safeMode, unloadAfter):
                        let r = try await backend.transcribe(path: path, initialPrompt: prompt, config: config, safeMode: safeMode, unloadAfter: unloadAfter)
                        send(.transcriptionResult(r)); send(.finished)
                    case let .diarize(path):
                        send(.diarizeResult(try await backend.diarize(path: path))); send(.finished)
                    case let .diarizeWithEmbeddings(path):
                        let r = try await backend.diarizeWithEmbeddings(path: path)
                        send(.diarizeWithEmbeddingsResult(turns: r.turns, embeddings: r.embeddings)); send(.finished)
                    case let .analyze(text, lang, vocab, guidance):
                        send(.insightsResult(try await backend.analyze(text: text, outputLanguage: lang, customVocabulary: vocab, guidance: guidance))); send(.finished)
                    case let .analyzeStream(text, lang, vocab, guidance):
                        try await backend.analyzeStream(text: text, outputLanguage: lang, customVocabulary: vocab, guidance: guidance, emitToken: emitToken)
                        send(.finished)
                    case let .chatStream(system, user):
                        try await backend.chatStream(systemPrompt: system, userMessage: user, emitToken: emitToken)
                        send(.finished)
                    case let .parakeetTranscribe(path, variant, diarize):
                        send(.transcriptionResult(try await backend.parakeetTranscribe(path: path, modelVariant: variant, diarize: diarize))); send(.finished)
                    case let .synthesizeSpeech(text, outputPath, voice, language, instruction, model, engine):
                        let r = try await backend.synthesizeSpeech(text: text, outputPath: outputPath, voice: voice, language: language, instruction: instruction, model: model, engine: engine)
                        send(.speechResult(r)); send(.finished)
                    case .prepareModels:
                        await backend.prepareModels(); send(.voidResult); send(.finished)
                    case let .downloadWhisper(config):
                        try await backend.downloadWhisper(config: config); send(.voidResult); send(.finished)
                    case let .prewarmWhisper(config, refresh):
                        try await backend.prewarmWhisper(config: config, refresh: refresh); send(.voidResult); send(.finished)
                    case .downloadLLM:
                        try await backend.downloadLLM(); send(.voidResult); send(.finished)
                    case let .downloadParakeet(variant):
                        try await backend.downloadParakeet(variant: variant); send(.voidResult); send(.finished)
                    case let .isWhisperCached(name):
                        send(.boolResult(await backend.isWhisperCached(name: name))); send(.finished)
                    case .isLLMCached:
                        send(.boolResult(await backend.isLLMCached())); send(.finished)
                    case .isParakeetCached:
                        send(.boolResult(await backend.isParakeetCached())); send(.finished)
                    case let .fetchWhisperModels(repo):
                        send(.stringsResult(try await backend.fetchWhisperModels(repo: repo))); send(.finished)
                    case .purgeModels: try await backend.purgeModels(); send(.voidResult); send(.finished)
                    case .purgeWhisper: try await backend.purgeWhisper(); send(.voidResult); send(.finished)
                    case .purgeSpeakerKit: try await backend.purgeSpeakerKit(); send(.voidResult); send(.finished)
                    case .purgeQwen: try await backend.purgeQwen(); send(.voidResult); send(.finished)
                    case .purgeParakeet: try await backend.purgeParakeet(); send(.voidResult); send(.finished)
                    case .memoryPressurePurge: await backend.memoryPressurePurge(); send(.voidResult); send(.finished)
                    case .forceUnload: await backend.forceUnload(); send(.voidResult); send(.finished)
                    case .cancel: break // handled by RequestLoop task cancellation, not the router
                    }
                } catch let w as WireError {
                    send(.error(w))
                } catch {
                    send(.error(WireError(kind: .generic, message: error.localizedDescription)))
                }
            }
        }
    }
}

/// Serializes writes to the output pipe AND preserves emission order. Events are
/// drained by a single task from an ordered queue, so a request's result frame
/// can never be overtaken on the wire by the trailing `.finished` (which would
/// make the parent drop the reply and leak its awaiting continuation). `send` is
/// synchronous and order-preserving, so callers must NOT wrap it in a `Task`.
final class StdoutWriter: @unchecked Sendable {
    private let continuation: AsyncStream<EventEnvelope>.Continuation
    private let drain: Task<Void, Never>

    init(_ handle: FileHandle) {
        let (stream, continuation) = AsyncStream<EventEnvelope>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        self.drain = Task {
            let encoder = JSONEncoder()   // reused across frames; single drain task
            for await envelope in stream {
                guard let payload = try? encoder.encode(envelope) else { continue }
                handle.write(FrameCodec.encode(payload))
            }
        }
    }

    func send(_ envelope: EventEnvelope) {
        continuation.yield(envelope)
    }
}

/// Reads framed requests from stdin, dispatches each on its own task (tracked
/// by id so `.cancel` can stop it), and writes event frames to stdout.
final class RequestLoop: @unchecked Sendable {
    private let router: RequestRouter
    private let backend: MLBackend
    private let writer: StdoutWriter
    private let diagnostics: MLLifecycleDiagnostics?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var shutdownTask: Task<Void, Never>?
    private var acceptingRequests = true
    private let lock = NSLock()

    init(backend: MLBackend, writer: StdoutWriter, diagnostics: MLLifecycleDiagnostics? = nil) {
        self.backend = backend
        self.writer = writer
        self.diagnostics = diagnostics
        self.router = RequestRouter(backend: backend) { env in writer.send(env) }
    }

    /// Blocks reading stdin until EOF (parent closed the pipe / is quitting).
    func run(input: FileHandle) async {
        var reader = FrameReader()
        let decoder = JSONDecoder()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            reader.append(chunk)
            for frame in reader.drainFrames() {
                guard let env = try? decoder.decode(RequestEnvelope.self, from: frame) else { continue }
                submit(env)
            }
        }
        await stop().value
    }

    /// Registration and shutdown share a synchronous lock: no request can slip
    /// between the shutdown snapshot and admission being closed.
    @discardableResult
    func submit(_ env: RequestEnvelope) -> Bool {
        if case .forceUnload = env.request {
            let shutdown = stop()
            Task { [writer] in
                await shutdown.value
                writer.send(EventEnvelope(id: env.id, channel: .plugin, event: .voidResult))
                writer.send(EventEnvelope(id: env.id, channel: .plugin, event: .finished))
            }
            return true
        }
        return lock.withLock {
            guard acceptingRequests else {
                // A late caller still needs a terminal reply; silently dropping
                // the request would leave its IPC continuation suspended forever.
                if case .cancel = env.request { return false }
                writer.send(EventEnvelope(id: env.id, channel: .plugin,
                    event: .error(WireError(kind: .generic, message: "ML helper is shutting down"))))
                return false
            }
            if case .cancel = env.request {
                // Retain the task until it unwinds, so shutdown can await it.
                tasks[env.id]?.cancel()
                return true
            }
            guard tasks[env.id] == nil else { return false }
            tasks[env.id] = Task {
                await self.router.handle(env)
                self.finished(env.id)
            }
            return true
        }
    }

    private func finished(_ id: UUID) {
        _ = lock.withLock { tasks.removeValue(forKey: id) }
    }

    /// Shared by explicit shutdown, SIGTERM and stdin EOF. Cleanup starts only
    /// after every admitted task has finished, including cancelled requests.
    func stop() -> Task<Void, Never> {
        lock.withLock {
            if let shutdownTask { return shutdownTask }
            acceptingRequests = false
            let running = Array(tasks.values)
            for task in running { task.cancel() }
            let task = Task { [backend, diagnostics] in
                diagnostics?.record(.shutdownRequested)
                for task in running { await task.value }
                await backend.forceUnload()
                diagnostics?.record(.shutdownCompleted)
            }
            shutdownTask = task
            return task
        }
    }
}
