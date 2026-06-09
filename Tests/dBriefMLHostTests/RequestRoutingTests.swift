import Testing
import Foundation
import dBriefWire
@testable import dBriefMLHost

actor MockBackend: MLBackend {
    func transcribe(path: String, initialPrompt: String?, config: WhisperRuntimeConfig, safeMode: Bool) async throws -> TranscriptionResult {
        TranscriptionResult(text: "mock:\(path):safe=\(safeMode)")
    }
    func diarize(path: String) async throws -> [DiarizedTurn] { [] }
    func analyze(text: String, outputLanguage: OutputLanguage) async throws -> LocalInsightsResult {
        LocalInsightsResult(summary: "s", actionItems: [], tags: [], sentiment: "Neutral")
    }
    func analyzeStream(text: String, outputLanguage: OutputLanguage, emitToken: @Sendable (String) -> Void) async throws { emitToken("a"); emitToken("b") }
    func chatStream(systemPrompt: String, userMessage: String, emitToken: @Sendable (String) -> Void) async throws { emitToken("hi") }
    func parakeetTranscribe(path: String, modelVariant: String, diarize: Bool) async throws -> TranscriptionResult { TranscriptionResult(text: "pk") }
    func synthesizeSpeech(text: String, outputPath: String, voice: String?, language: String?) async throws -> SpeechSynthesisResult {
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
}

@Suite struct RequestRoutingTests {
    @Test func transcribeEmitsResultThenFinished() async throws {
        let collected = EventCollector()
        let router = RequestRouter(backend: MockBackend()) { env in collected.append(env) }
        let id = UUID()
        await router.handle(RequestEnvelope(id: id,
            request: .transcribe(path: "/x.m4a", initialPrompt: nil, config: .default, safeMode: true)))
        let events = collected.events
        guard case let .transcriptionResult(tr) = events.first?.event else {
            Issue.record("expected result first"); return
        }
        #expect(tr.text == "mock:/x.m4a:safe=true")
        #expect(events.last.map { if case .finished = $0.event { true } else { false } } == true)
        #expect(events.allSatisfy { $0.id == id })
    }

    @Test func streamEmitsTokensThenFinished() async throws {
        let collected = EventCollector()
        let router = RequestRouter(backend: MockBackend()) { env in collected.append(env) }
        await router.handle(RequestEnvelope(id: UUID(),
            request: .analyzeStream(text: "t", outputLanguage: .matchInput)))
        let tokens = collected.events.compactMap { if case let .token(s) = $0.event { s } else { nil } }
        #expect(tokens == ["a", "b"])
        #expect(collected.events.last.map { if case .finished = $0.event { true } else { false } } == true)
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
