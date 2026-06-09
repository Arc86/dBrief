import Foundation
import dBriefWire

/// The seam the request router dispatches to. `MLOrchestrator` is the real
/// implementation; tests substitute a mock.
protocol MLBackend: Sendable {
    func transcribe(path: String, initialPrompt: String?, config: WhisperRuntimeConfig, safeMode: Bool) async throws -> TranscriptionResult
    func diarize(path: String) async throws -> [DiarizedTurn]
    func analyze(text: String, outputLanguage: OutputLanguage) async throws -> LocalInsightsResult
    func analyzeStream(text: String, outputLanguage: OutputLanguage, emitToken: @Sendable (String) -> Void) async throws
    func chatStream(systemPrompt: String, userMessage: String, emitToken: @Sendable (String) -> Void) async throws
    func parakeetTranscribe(path: String, modelVariant: String) async throws -> TranscriptionResult
    func synthesizeSpeech(text: String, outputPath: String, voice: String?, language: String?) async throws -> SpeechSynthesisResult
    func prepareModels() async
    func downloadWhisper(config: WhisperRuntimeConfig) async throws
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

        do {
            switch envelope.request {
            case let .transcribe(path, prompt, config, safeMode):
                let r = try await backend.transcribe(path: path, initialPrompt: prompt, config: config, safeMode: safeMode)
                send(.transcriptionResult(r)); send(.finished)
            case let .diarize(path):
                send(.diarizeResult(try await backend.diarize(path: path))); send(.finished)
            case let .analyze(text, lang):
                send(.insightsResult(try await backend.analyze(text: text, outputLanguage: lang))); send(.finished)
            case let .analyzeStream(text, lang):
                try await backend.analyzeStream(text: text, outputLanguage: lang, emitToken: emitToken)
                send(.finished)
            case let .chatStream(system, user):
                try await backend.chatStream(systemPrompt: system, userMessage: user, emitToken: emitToken)
                send(.finished)
            case let .parakeetTranscribe(path, variant):
                send(.transcriptionResult(try await backend.parakeetTranscribe(path: path, modelVariant: variant))); send(.finished)
            case let .synthesizeSpeech(text, outputPath, voice, language):
                let r = try await backend.synthesizeSpeech(text: text, outputPath: outputPath, voice: voice, language: language)
                send(.speechResult(r)); send(.finished)
            case .prepareModels:
                await backend.prepareModels(); send(.voidResult); send(.finished)
            case let .downloadWhisper(config):
                try await backend.downloadWhisper(config: config); send(.voidResult); send(.finished)
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

/// Serializes writes to the output pipe so concurrent request tasks never
/// interleave their frames.
actor StdoutWriter {
    private let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func send(_ envelope: EventEnvelope) {
        guard let payload = try? JSONEncoder().encode(envelope) else { return }
        handle.write(FrameCodec.encode(payload))
    }
}

/// Reads framed requests from stdin, dispatches each on its own task (tracked
/// by id so `.cancel` can stop it), and writes event frames to stdout.
final class RequestLoop: @unchecked Sendable {
    private let router: RequestRouter
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let lock = NSLock()

    init(backend: MLBackend, writer: StdoutWriter) {
        self.router = RequestRouter(backend: backend) { env in
            Task { await writer.send(env) }
        }
    }

    /// Blocks reading stdin until EOF (parent closed the pipe / is quitting).
    func run(input: FileHandle) async {
        var reader = FrameReader()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }   // EOF
            reader.append(chunk)
            for frame in reader.drainFrames() {
                guard let env = try? JSONDecoder().decode(RequestEnvelope.self, from: frame) else { continue }
                if case .cancel = env.request { cancel(env.id); continue }
                let task = Task { await self.router.handle(env) }
                store(task, for: env.id)
            }
        }
    }

    private func store(_ task: Task<Void, Never>, for id: UUID) {
        lock.lock(); tasks[id] = task; lock.unlock()
    }
    private func cancel(_ id: UUID) {
        lock.lock(); let t = tasks.removeValue(forKey: id); lock.unlock(); t?.cancel()
    }
}
