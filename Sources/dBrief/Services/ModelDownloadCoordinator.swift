import Foundation
import dBriefWire

/// Owns download UI state and cancellable attempts. Backend operations remain in
/// the service proxies; this MainActor object only coordinates their async work.
@MainActor @Observable
final class ModelDownloadCoordinator {
    enum Request: Equatable, Sendable {
        case whisper(WhisperRuntimeConfig)
        case parakeet(variant: String)
        case gemma

        var kind: LocalModelKind {
            switch self {
            case .whisper: .whisper
            case .parakeet: .parakeet
            case .gemma: .gemma
            }
        }
    }

    struct Dependencies: Sendable {
        var stateStream: @Sendable (LocalModelKind) -> AsyncStream<LocalAIPluginState>
        var download: @Sendable (Request) async throws -> Void
        var purge: @Sendable (LocalModelKind) async throws -> Void
        var isCached: @Sendable (Request) async -> Bool
        var availableWhisperModels: @Sendable () async -> [String]

        static func live(plugin: LocalAIPluginService, parakeet: ParakeetTranscriptionService) -> Self {
            Self(stateStream: { kind in kind == .parakeet ? parakeet.stateStream : plugin.stateStream },
                 download: { request in
                     switch request {
                     case .whisper(let config): try await plugin.downloadWhisperModel(config: config)
                     case .parakeet(let variant): try await parakeet.prepareModel(variant: variant)
                     case .gemma: try await plugin.downloadLLMModel()
                     }
                 }, purge: { kind in
                     switch kind {
                     case .whisper: try await plugin.purgeWhisperModel()
                     case .parakeet: try await parakeet.purgeModels()
                     case .gemma: try await plugin.purgeQwenModel()
                     }
                 }, isCached: { request in
                     switch request {
                     case .whisper(let config): await plugin.isWhisperModelCached(name: config.modelName)
                     case .parakeet: await parakeet.isModelDownloaded()
                     case .gemma: await plugin.isLLMModelCached()
                     }
                 }, availableWhisperModels: {
                     await plugin.fetchAvailableWhisperModels(repo: "argmaxinc/whisperkit-coreml")
                 })
        }
    }

    private(set) var phases: [LocalModelKind: ModelDownloadPhase] = [:]
    private let dependencies: Dependencies
    @ObservationIgnored private var tasks: [LocalModelKind: Task<Void, Never>] = [:]
    @ObservationIgnored private var observers: [LocalModelKind: Task<Void, Never>] = [:]
    @ObservationIgnored private var attempts: [LocalModelKind: UUID] = [:]
    @ObservationIgnored private var taskAttempts: [LocalModelKind: UUID] = [:]

    init(dependencies: Dependencies) { self.dependencies = dependencies }

    deinit {
        tasks.values.forEach { $0.cancel() }
        observers.values.forEach { $0.cancel() }
    }

    /// The returned handle can be awaited by callers that need completion;
    /// Settings starts the operation and observes phases without waiting.
    @discardableResult
    func start(_ request: Request, forceRedownload: Bool = false) -> Task<Void, Never> {
        let kind = request.kind
        let predecessor = tasks[kind]
        cancel(kind)
        let attempt = UUID()
        attempts[kind] = attempt
        taskAttempts[kind] = attempt
        phases[kind] = .downloading(progress: nil, label: "Starting…")
        let dependencies = self.dependencies
        let task = Task { @MainActor [weak self] in
            // Client cancellation may not stop an already-running helper call.
            // Keep the whole predecessor chain until it settles, even when this
            // attempt is cancelled before dispatch, so successors cannot overlap.
            await predecessor?.value
            defer { self?.releaseTask(kind, attempt: attempt) }
            do {
                try Task.checkCancellation()
                guard self?.attempts[kind] == attempt else { return }
                self?.observe(kind, attempt: attempt)
                if forceRedownload { try? await dependencies.purge(kind) }
                try Task.checkCancellation()
                guard self?.attempts[kind] == attempt else { return }
                try await dependencies.download(request)
                try Task.checkCancellation()
                self?.finish(kind, attempt: attempt, phase: .idle)
            } catch is CancellationError {
                self?.finish(kind, attempt: attempt, phase: .idle)
            } catch {
                self?.finish(kind, attempt: attempt, phase: .failed(error.localizedDescription))
            }
        }
        tasks[kind] = task
        return task
    }

    func cancel(_ kind: LocalModelKind) {
        attempts[kind] = nil
        observers.removeValue(forKey: kind)?.cancel()
        tasks[kind]?.cancel()
        phases[kind] = .idle
    }

    func cancelAll() {
        // Ownership, rather than a progress label, determines what must stop.
        for kind in Array(tasks.keys) { cancel(kind) }
    }

    func isCached(_ request: Request) async -> Bool { await dependencies.isCached(request) }
    func purge(_ kind: LocalModelKind) async throws { try await dependencies.purge(kind) }
    func availableWhisperModels() async -> [String] { await dependencies.availableWhisperModels() }

    private func finish(_ kind: LocalModelKind, attempt: UUID, phase: ModelDownloadPhase) {
        guard attempts[kind] == attempt else { return }
        attempts[kind] = nil
        observers.removeValue(forKey: kind)?.cancel()
        phases[kind] = phase
    }

    private func releaseTask(_ kind: LocalModelKind, attempt: UUID) {
        guard taskAttempts[kind] == attempt else { return }
        tasks[kind] = nil
        taskAttempts[kind] = nil
    }

    private func observe(_ kind: LocalModelKind, attempt: UUID) {
        let stream = dependencies.stateStream(kind)
        observers[kind] = Task { @MainActor [weak self] in
            for await state in stream {
                guard !Task.isCancelled, let self, self.attempts[kind] == attempt else { return }
                if Self.belongs(state, to: kind), let phase = ModelDownloadPhase.from(pluginState: state) {
                    self.phases[kind] = phase
                }
            }
        }
    }

    private static func belongs(_ state: LocalAIPluginState, to kind: LocalModelKind) -> Bool {
        guard case .downloading(_, let stage) = state else { return false }
        switch kind {
        case .whisper: return [.whisperModel, .whisperModelLoading, .speakerKitModel].contains(stage)
        case .parakeet: return [.parakeetModel, .parakeetModelLoading].contains(stage)
        case .gemma: return stage == .llmModel
        }
    }
}
