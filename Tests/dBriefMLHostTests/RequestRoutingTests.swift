import Testing
import Foundation
import dBriefWire
@testable import dBriefMLHost

actor MockBackend: MLBackend {
    let exercisePrivacy: Bool
    let exerciseProgress: Bool
    var savedProgressSinks: [MLProgress.Sink] = []
    init(exercisePrivacy: Bool = false, exerciseProgress: Bool = false) {
        self.exercisePrivacy = exercisePrivacy
        self.exerciseProgress = exerciseProgress
    }
    private func captureProgress() {
        if exerciseProgress, let sink = MLProgress.sink {
            savedProgressSinks.append(sink)
            sink(.transcribing)
        }
    }
    func savedProgress() -> [MLProgress.Sink] { savedProgressSinks }
    func transcribe(path: String, initialPrompt: String?, config: WhisperRuntimeConfig, safeMode: Bool, unloadAfter: Bool) async throws -> TranscriptionResult {
        captureProgress()
        if exercisePrivacy {
            // Match the production best-effort speaker stage: retain its failure
            // even though the parent transcription subsequently returns a value.
            do {
                try await MLPrivacyTrace.perform(.speakerDiarization) {
                    throw WireError(kind: .diarizationFailed, message: "private diagnostic")
                }
            } catch { }
        }
        return TranscriptionResult(text: "mock:\(path):safe=\(safeMode):unload=\(unloadAfter)")
    }
    func diarize(path: String) async throws -> [DiarizedTurn] { [] }
    func diarizeWithEmbeddings(path: String) async throws -> (turns: [DiarizedTurn], embeddings: [String: [Float]]) { ([], [:]) }
    func analyze(text: String, outputLanguage: OutputLanguage, customVocabulary: String, guidance: InsightsGuidance?) async throws -> LocalInsightsResult {
        LocalInsightsResult(summary: "s", actionItems: [], tags: [], sentiment: "Neutral")
    }
    func analyzeStream(text: String, outputLanguage: OutputLanguage, customVocabulary: String, guidance: InsightsGuidance?, emitToken: @Sendable (String) -> Void) async throws { captureProgress(); emitToken("a"); emitToken("b") }
    func chatStream(systemPrompt: String, userMessage: String, emitToken: @Sendable (String) -> Void) async throws { emitToken("hi") }
    func parakeetTranscribe(path: String, modelVariant: String, diarize: Bool) async throws -> TranscriptionResult { captureProgress(); return TranscriptionResult(text: "pk") }
    func synthesizeSpeech(text: String, outputPath: String, voice: String?, language: String?, instruction: String?, model: String?, engine: String?) async throws -> SpeechSynthesisResult {
        SpeechSynthesisResult(outputPath: outputPath, durationSeconds: 1.0, sampleRate: 24000)
    }
    func prepareModels() async {}
    func downloadWhisper(config: WhisperRuntimeConfig) async throws {}
    func downloadLLM() async throws {}
    func downloadParakeet(variant: String) async throws {}
    func isWhisperCached(name: String) async -> Bool { true }
    func isLLMCached() async -> Bool { false }
    func isParakeetCached() async -> Bool { true }
    func fetchWhisperModels(repo: String) async throws -> [String] { ["openai_whisper-small"] }
    func purgeModels() async throws {}
    func purgeWhisper() async throws {}
    func purgeSpeakerKit() async throws {}
    func purgeQwen() async throws {}
    func purgeParakeet() async throws {}
    func memoryPressurePurge() async {}
    func forceUnload() async {}
    func prewarmWhisper(config: WhisperRuntimeConfig, refresh: Bool) async throws {}
}

@Suite struct RequestRoutingTests {
    @Test func progressRetainsRequestIdentityOutsideOriginatingTask() async throws {
        let collected = EventCollector()
        let backend = MockBackend(exerciseProgress: true)
        let router = RequestRouter(backend: backend) { collected.append($0) }
        let first = UUID(), second = UUID(), third = UUID()
        await router.handle(.init(id: first, request: .transcribe(path: "/synthetic.wav", initialPrompt: nil,
            config: .default, safeMode: false, unloadAfter: false)))
        await router.handle(.init(id: second, request: .parakeetTranscribe(path: "/synthetic.wav", modelVariant: "v2", diarize: false)))
        await router.handle(.init(id: third, request: .analyzeStream(text: "Synthetic", outputLanguage: .matchInput,
            customVocabulary: "", guidance: nil)))
        let callbacks = await backend.savedProgress()
        #expect(callbacks.count == 3)
        // Third-party SDK callbacks need not run in the task that installed them.
        await Task.detached { for callback in callbacks { callback(.diarizing) } }.value
        let states = collected.events.filter { if case .state = $0.event { true } else { false } }
        #expect(states.map(\.id) == [first, second, third, first, second, third])
        #expect(states.map(\.channel) == [.plugin, .parakeet, .plugin, .plugin, .parakeet, .plugin])
        #expect(MLProgress.sink == nil)
    }
    @Test func nestedStageFailureIsEmittedBeforeSuccessfulParentResult() async throws {
        let collected = EventCollector()
        let router = RequestRouter(backend: MockBackend(exercisePrivacy: true)) { collected.append($0) }
        let id = UUID()
        await router.handle(.init(id: id, request: .transcribe(path: "/private.wav", initialPrompt: nil,
                                                             config: .default, safeMode: false, unloadAfter: true)))
        let events = collected.events
        #expect(events.count == 5)
        guard case .privacy(.supported(version: 1)) = events[0].event,
              case .privacy(.started(let attempt, .speakerDiarization)) = events[1].event,
              case .privacy(.finished(let finished, .failed)) = events[2].event,
              case .transcriptionResult = events[3].event,
              case .finished = events[4].event else {
            Issue.record("Expected ordered nested failure followed by parent success"); return
        }
        #expect(attempt == finished)
        #expect(events.allSatisfy { $0.id == id && $0.channel == .plugin })
        let evidence = try JSONEncoder().encode(Array(events.prefix(3)))
        #expect(!String(decoding: evidence, as: UTF8.self).contains("private"))
    }
    @Test func transcribeEmitsResultThenFinished() async throws {
        let collected = EventCollector()
        let router = RequestRouter(backend: MockBackend()) { env in collected.append(env) }
        let id = UUID()
        await router.handle(RequestEnvelope(id: id,
            request: .transcribe(path: "/x.m4a", initialPrompt: nil, config: .default, safeMode: true, unloadAfter: false)))
        let events = collected.events.filter { if case .privacy = $0.event { false } else { true } }
        guard case let .transcriptionResult(tr) = events.first?.event else {
            Issue.record("expected result first"); return
        }
        #expect(tr.text == "mock:/x.m4a:safe=true:unload=false")
        #expect(events.last.map { if case .finished = $0.event { true } else { false } } == true)
        #expect(events.allSatisfy { $0.id == id })
    }

    @Test func streamEmitsTokensThenFinished() async throws {
        let collected = EventCollector()
        let router = RequestRouter(backend: MockBackend()) { env in collected.append(env) }
        await router.handle(RequestEnvelope(id: UUID(),
            request: .analyzeStream(text: "t", outputLanguage: .matchInput, customVocabulary: "", guidance: nil)))
        let tokens = collected.events.compactMap { if case let .token(s) = $0.event { s } else { nil } }
        #expect(tokens == ["a", "b"])
        #expect(collected.events.last.map { if case .finished = $0.event { true } else { false } } == true)
    }

    @Test func prewarmEmitsVoidThenFinishedOnPluginChannel() async {
        let collected = EventCollector()
        let router = RequestRouter(backend: MockBackend()) { collected.append($0) }
        await router.handle(RequestEnvelope(id: UUID(),
            request: .prewarmWhisper(config: .default, refresh: false)))
        #expect(collected.events.contains { if case .voidResult = $0.event { true } else { false } })
        #expect(collected.events.last.map { if case .finished = $0.event { true } else { false } } == true)
        #expect(collected.events.allSatisfy { $0.channel == .plugin })
    }

    @Test func parakeetUsesParakeetChannel() async throws {
        let collected = EventCollector()
        let router = RequestRouter(backend: MockBackend()) { env in collected.append(env) }
        await router.handle(RequestEnvelope(id: UUID(),
            request: .parakeetTranscribe(path: "/p.m4a", modelVariant: "v2", diarize: false)))
        #expect(collected.events.allSatisfy { $0.channel == .parakeet })
    }
}

final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [EventEnvelope] = []
    func append(_ e: EventEnvelope) { lock.lock(); _events.append(e); lock.unlock() }
    var events: [EventEnvelope] { lock.lock(); defer { lock.unlock() }; return _events }
}
