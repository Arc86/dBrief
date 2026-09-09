import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Local execution privacy evidence")
struct LocalPrivacyTests {
    private func fixture() throws -> PrivacyTrace.Context {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("local-privacy-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return PrivacyTrace.Context(receiptURL: folder.appendingPathComponent("receipt.json"),
                                    store: PrivacyReceiptStore(gapDirectoryURL: folder.appendingPathComponent("gaps")))
    }
    private var operation: PrivacyOperation {
        .init(stage: .chat, data: [.text], destination: .local(provider: .localModel))
    }

    @Test func helperCrashAndRetryRemainSeparateAttempts() async throws {
        let context = try fixture()
        let folder = context.receiptURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let connection = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
            supportBase: folder, environment: ["STUB_MODE": "crash-once", "STUB_FLAG_1": folder.appendingPathComponent("crashed").path])
        let service = LocalAIPluginService(connection: connection)
        let result = try await PrivacyTrace.$context.withValue(context) {
            try await service.transcribe(fileURL: folder.appendingPathComponent("private-name.wav"),
                                         initialPrompt: "Secret terminology", whisperConfig: .default)
        }
        await connection.shutdown()
        #expect(result.text == "recovered")
        let receipt = try #require(try await context.store.load(from: context.receiptURL))
        #expect(receipt.attempts.map(\.outcome) == [.failed, .succeeded])
        #expect(receipt.attempts.allSatisfy { $0.operation.stage == .transcription
            && $0.operation.destination.provider == .whisper
            && $0.operation.destination.location == .local
            && $0.operation.destination.model == WhisperRuntimeConfig.default.modelName
            && $0.operation.data.contains(.text) })
        let json = try String(contentsOf: context.receiptURL, encoding: .utf8)
        #expect(!json.contains("private-name") && !json.contains("Secret terminology") && !json.contains("recovered"))
    }

    @Test func cliIsExternallyManagedAndEmptyTranscriptDoesNotInvokeIt() async throws {
        let context = try fixture()
        defer { try? FileManager.default.removeItem(at: context.receiptURL.deletingLastPathComponent()) }
        let service = LocalCLIService()
        let json = #"{"title_concept":"T","summary":"S","action_items":[],"tags":[],"sentiment":"Neutral"}"#
        let config = LocalCLIConfig(command: "printf '%s' '\(json)'", timeoutSeconds: 10)
        _ = try await PrivacyTrace.$context.withValue(context) {
            try await service.analyze(transcript: " ", outputLanguage: .matchInput, config: config)
        }
        #expect(try await context.store.load(from: context.receiptURL) == nil)
        _ = try await PrivacyTrace.$context.withValue(context) {
            try await service.analyze(transcript: "Private transcript", outputLanguage: .matchInput, config: config)
        }
        let receipt = try #require(try await context.store.load(from: context.receiptURL))
        #expect(receipt.attempts.count == 1)
        #expect(receipt.attempts[0].operation.destination == .externallyManaged(provider: .localCLI))
        #expect(receipt.attempts[0].outcome == .succeeded)
        let stored = try String(contentsOf: context.receiptURL, encoding: .utf8)
        #expect(!stored.contains("printf") && !stored.contains("Private transcript"))
    }

    @Test func streamFailureDoesNotBecomeSuccessAfterPartialOutput() async throws {
        let context = try fixture()
        defer { try? FileManager.default.removeItem(at: context.receiptURL.deletingLastPathComponent()) }
        let stream = PrivacyTrace.$context.withValue(context) {
            PrivacyTrace.stream(operation) {
                AsyncThrowingStream<String, Error> { continuation in
                    continuation.yield("private answer")
                    continuation.finish(throwing: URLError(.networkConnectionLost))
                }
            }
        }
        await #expect(throws: URLError.self) {
            for try await _ in stream { }
        }
        let receipt = try #require(try await context.store.load(from: context.receiptURL))
        #expect(receipt.attempts.map(\.outcome) == [.failed])
        #expect(receipt.attempts[0].runID == context.runID)
    }

    @Test func cancelledTaskDoesNotStartAnOperation() async throws {
        let context = try fixture()
        defer { try? FileManager.default.removeItem(at: context.receiptURL.deletingLastPathComponent()) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await PrivacyTrace.$context.withValue(context) {
                try await PrivacyTrace.perform(operation) { Issue.record("Cancelled body ran") }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await context.store.load(from: context.receiptURL) == nil)
    }

    @Test func stoppingStreamCancelsUpstreamAndRecordsCancellation() async throws {
        let context = try fixture()
        defer { try? FileManager.default.removeItem(at: context.receiptURL.deletingLastPathComponent()) }
        let (upstream, producer) = AsyncThrowingStream<String, Error>.makeStream()
        let (events, signal) = AsyncStream<String>.makeStream()
        producer.onTermination = { _ in signal.yield("terminated") }
        let stream = PrivacyTrace.$context.withValue(context) {
            PrivacyTrace.stream(operation) { upstream }
        }
        let consumer = Task {
            for try await _ in stream { signal.yield("received") }
        }
        producer.yield("private answer")
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == "received")
        consumer.cancel()
        _ = await consumer.result
        #expect(await iterator.next() == "terminated")
        // Cancellation returns to the consumer before asynchronous receipt I/O
        // finishes. Bound the observation instead of assuming task scheduling.
        for _ in 0..<100 {
            if try await context.store.load(from: context.receiptURL)?.attempts.first?.finishedAt != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let receipt = try #require(try await context.store.load(from: context.receiptURL))
        #expect(receipt.attempts.map(\.outcome) == [.cancelled])
        #expect(!receipt.hasGaps)
    }

    @Test(arguments: [false, true])
    func localChatUsesItsActualPurpose(spelling: Bool) async throws {
        let context = try fixture()
        let folder = context.receiptURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let connection = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
                                          supportBase: folder, environment: ["STUB_MODE": "echo"])
        let service = LocalAIPluginService(connection: connection)
        try await PrivacyTrace.$context.withValue(context) {
            let stream = await service.chatStream(systemPrompt: "secret instructions", userMessage: "secret text",
                                                  stage: spelling ? .spelling : .chat)
            for try await _ in stream { }
        }
        await connection.shutdown()
        let receipt = try #require(try await context.store.load(from: context.receiptURL))
        #expect(receipt.attempts.count == 1)
        #expect(receipt.attempts[0].operation.stage == (spelling ? .spelling : .chat))
        #expect(receipt.attempts[0].operation.destination == .local(provider: .localModel))
        #expect(receipt.attempts[0].outcome == .succeeded)
    }

    @Test func callbackCompletionSurvivesMigrationAndIgnoresLateTerminalCallbacks() async throws {
        let context = try fixture()
        let folder = context.receiptURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let token = await PrivacyTrace.begin(operation, in: context)
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        let completion = PrivacyTrace.Completion { outcome in
            startedSignal.yield(())
            for await _ in release { break }
            await PrivacyTrace.finish(token, outcome: outcome)
        }
        let target = folder.appendingPathComponent("final.json")
        try await context.store.transfer(from: context.receiptURL, to: target)
        completion.record(.failed)
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        // A cancelled/finished recognizer can still deliver a late callback.
        // Hold the first observation's persistence until both later terminal
        // observations arrive; they must not reorder or replace that outcome.
        completion.record(.succeeded)
        completion.record(.cancelled)
        releaseSignal.yield(())
        await completion.finish(.cancelled)
        let receipt = try #require(try await context.store.load(from: target))
        #expect(receipt.attempts.map(\.outcome) == [.failed])
        #expect(!receipt.hasGaps)
    }

    @Test(arguments: ["kokoro", "qwen3"])
    func speechSynthesisUsesTheActualEngineAndModelPolicy(engine: String) async throws {
        let context = try fixture()
        let folder = context.receiptURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let connection = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
                                          supportBase: folder, environment: ["STUB_MODE": "speech"])
        let plugin = LocalAIPluginService(connection: connection)
        _ = try await PrivacyTrace.$context.withValue(context) {
            try await plugin.synthesizeSpeech(text: "Private spoken script", outputPath: folder.appendingPathComponent("private.wav").path,
                                               instruction: "Private voice direction", model: "invalid-model", engine: engine)
        }
        await connection.shutdown()
        let receipt = try #require(try await context.store.load(from: context.receiptURL))
        let attempt = try #require(receipt.attempts.first)
        #expect(receipt.attempts.count == 1)
        #expect(attempt.operation.stage == .speechSynthesis)
        #expect(attempt.operation.destination.provider == (engine == "kokoro" ? .kokoro : .ttsKit))
        // Kokoro ignores model-size input; TTSKit resolves invalid values to 1.7B.
        #expect(attempt.operation.destination.model == (engine == "kokoro" ? nil : "1.7b"))
        #expect(attempt.outcome == .succeeded)
        let stored = try String(contentsOf: context.receiptURL, encoding: .utf8)
        #expect(!stored.contains("Private") && !stored.contains("private.wav") && !stored.contains("invalid-model"))
    }
}
