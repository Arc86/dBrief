import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Transcript chat actual frozen dispatch", .serialized)
@MainActor
struct TranscriptChatSnapshotTests {
    @Test(arguments: ["stop", "invalidate"], ["remote", "local"])
    func acceptanceCallbackRetirementCannotDispatchEvidence(action: String, route: String) async throws {
        let settings = AppSettings(), saved = ChatSettingsRestore(settings)
        defer { saved.restore(settings) }
        let profile = MeetingProfile(name: "Retired acceptance fixture")
        settings.profiles = [profile]; settings.activeProfileId = profile.id; settings.automaticProfileId = nil
        settings.aiEngine = route == "remote" ? .remoteEndpoint : .qwenLocal
        settings.aiEndpoints = [Endpoint(name: "Retired", baseURL: "https://freeze-chat.invalid", modelName: "fixture")]
        settings.defaultAIEndpointId = settings.aiEndpoints[0].id
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FrozenChatProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        FrozenChatProtocol.requests.reset()
        let policy = LiveModelResourcePolicy(profiles: []), probe = RetiredChatAdmissionProbe()
        let connection = MLHostConnection(binaryURL: URL(fileURLWithPath: "/private/tmp/never-launch-retired-chat-\(UUID())"),
            supportBase: FileManager.default.temporaryDirectory, resourceAdmission: .init(policy: policy, measurement: {
                await probe.record()
                throw MLHostError.resourceDeferred
            }))
        let service = TranscriptChatService(transcriptText: "Private committed evidence", speakerLabels: [], appSettings: settings,
            localPlugin: LocalAIPluginService(connection: connection), aiService: AIService(session: session))
        var accepted = false
        #expect(await service.send("Question", onAccepted: {
            accepted = true
            if action == "stop" { service.stopGenerating() }
            else { service.invalidateForReprocessing() }
        }) == .accepted)
        for _ in 0..<100 { await Task.yield() }
        #expect(accepted && !service.isStreaming)
        #expect(FrozenChatProtocol.requests.values.isEmpty)
        #expect(await probe.calls == 0)
        #expect(await policy.jobCount == 0)
        await connection.shutdown()
        service.invalidateForReprocessing()
    }

    @Test(arguments: ["length", "missing", "malformed", "error"])
    func actualRemoteIncompleteAnswersNeverEnterLaterConversation(mode: String) async throws {
        let settings = AppSettings(), saved = ChatSettingsRestore(settings)
        defer { saved.restore(settings) }
        let profile = MeetingProfile(name: "Incomplete chat fixture")
        settings.profiles = [profile]; settings.activeProfileId = profile.id; settings.automaticProfileId = nil
        settings.aiEngine = .remoteEndpoint
        settings.aiEndpoints = [Endpoint(name: "Incomplete", baseURL: "https://\(mode)-completion-chat.invalid", modelName: "fixture")]
        settings.defaultAIEndpointId = settings.aiEndpoints[0].id
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FrozenChatProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        FrozenChatProtocol.requests.reset()
        let service = TranscriptChatService(transcriptText: "Evidence", speakerLabels: [], appSettings: settings,
            localPlugin: nil, aiService: AIService(session: session))
        await service.send("First question")
        let first = try #require(service.messages.last)
        #expect(first.outcome == (mode == "length" ? .truncated : mode == "error" ? .failed : .unconfirmed))
        #expect(first.content == "Partial proof")
        await service.send("Second question")
        let request = try #require(FrozenChatProtocol.requests.values.last)
        let body = String(decoding: request.body, as: UTF8.self)
        #expect(!body.contains("Partial proof"))
        #expect(body.components(separatedBy: "Second question").count == 2)
    }

    @Test func routeLanguageProviderAndHistoryAreFrozenBeforeSnapshotAwait() async throws {
        let settings = AppSettings(), saved = ChatSettingsRestore(settings)
        defer { saved.restore(settings) }
        let profile = MeetingProfile(name: "Frozen chat fixture")
        settings.profiles = [profile]; settings.automaticProfileId = nil; settings.activeProfileId = profile.id
        settings.aiEngine = .localCLI; settings.chatFallbackEngine = .remoteEndpoint; settings.outputLanguage = .english
        let endpoint = Endpoint(name: "Frozen", baseURL: "https://freeze-chat.invalid", modelName: "original", apiKey: "fixture-secret", maxOutputTokens: 20_000)
        settings.aiEndpoints = [endpoint]; settings.defaultAIEndpointId = endpoint.id
        let gate = ChatSnapshotGate()
        let original = TranscriptContextSnapshot.legacy(text: "Original committed evidence", recordingID: UUID(), speakerLabels: [])
        let provider = TranscriptContextProvider { .init(snapshot: { await gate.hold(); return original }) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FrozenChatProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        FrozenChatProtocol.requests.reset()
        let service = TranscriptChatService(contextProvider: provider, appSettings: settings, localPlugin: nil, aiService: AIService(session: session))
        service.startLoadingPersisted(load: { ChatHistory(messages: [ChatMessage(role: .assistant, content: "Loaded history", outcome: .completed)]) })
        let send = Task { await service.send("Question") }
        do { try await gate.waitForArrival() }
        catch {
            send.cancel()
            await gate.release()
            _ = await send.value
            service.invalidateForReprocessing()
            throw error
        }
        settings.aiEngine = .appleIntelligence; settings.chatFallbackEngine = .qwenLocal; settings.outputLanguage = .dutch
        settings.aiEndpoints = [Endpoint(name: "Changed", baseURL: "https://other.invalid", modelName: "changed")]
        service.rebindTranscript(text: "Changed source", speakerLabels: [])
        await gate.release()
        #expect(await send.value == .accepted)
        let request = try #require(FrozenChatProtocol.requests.values.first)
        let object = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(request.host == "freeze-chat.invalid" && object["model"] as? String == "original")
        #expect(object["max_tokens"] as? Int == 4_096)
        let body = String(decoding: request.body, as: UTF8.self)
        #expect(body.contains("Original committed evidence") && body.contains("Loaded history") && body.contains("English"))
        #expect(!body.contains("Changed source") && !body.contains("Dutch"))
        let answer = try #require(service.messages.last)
        #expect(answer.outcome == .completed && answer.basis?.route.endpointID == endpoint.id)
        let encoded = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
        #expect(!encoded.contains("fixture-secret"))
        #expect(answer.basis?.budget.outputTokens == 4_096)
    }

    @Test func emptyCommittedContextRetainsDraftAndNeverDispatches() async {
        let settings = AppSettings()
        let service = TranscriptChatService(transcriptText: "", speakerLabels: [], appSettings: settings, localPlugin: nil)
        var accepted = false
        #expect(await service.send("Keep my question", onAccepted: { accepted = true }) == .waitingForTranscript)
        #expect(!accepted && service.messages.isEmpty && !service.isStreaming)
        #expect(service.streamingNotice == "Waiting for transcript")
    }

    @Test func clearedConversationRejectsHeldOldHistoryLoad() async throws {
        let settings = AppSettings(), gate = ChatSnapshotGate()
        let service = TranscriptChatService(transcriptText: "Evidence", speakerLabels: [], appSettings: settings, localPlugin: nil)
        service.startLoadingPersisted(load: {
            await gate.hold()
            return ChatHistory(messages: [ChatMessage(role: .assistant, content: "Must not resurrect")])
        })
        do { try await gate.waitForArrival() }
        catch {
            service.invalidateForReprocessing()
            await gate.release()
            throw error
        }
        service.clearMessages()
        await gate.release()
        for _ in 0..<10 { await Task.yield() }
        #expect(service.messages.isEmpty)
    }
}

private actor RetiredChatAdmissionProbe {
    private(set) var calls = 0
    func record() { calls += 1 }
}

private actor ChatSnapshotGate {
    private var arrived = false, released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() async { arrived = true; if !released { await withCheckedContinuation { waiter = $0 } } }
    func waitForArrival() async throws {
        let deadline = ContinuousClock.now + TestTiming.asyncDeadline
        while !arrived, ContinuousClock.now < deadline { await Task.yield() }
        try #require(arrived)
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

@MainActor
private struct ChatSettingsRestore {
    let engine: AppSettings.AIEngine, fallback: AppSettings.AIEngine, endpoints: [Endpoint], endpoint: UUID?, profiles: [MeetingProfile], active: UUID, automatic: UUID?, automaticOwner: UUID?, language: OutputLanguage
    init(_ settings: AppSettings) {
        engine = settings.aiEngine; fallback = settings.chatFallbackEngine; endpoints = settings.aiEndpoints
        endpoint = settings.defaultAIEndpointId; profiles = settings.profiles; active = settings.activeProfileId
        automatic = settings.automaticProfileId; automaticOwner = settings.automaticProfileRecordingID; language = settings.outputLanguage
    }
    func restore(_ settings: AppSettings) {
        settings.aiEngine = engine; settings.chatFallbackEngine = fallback; settings.aiEndpoints = endpoints
        settings.defaultAIEndpointId = endpoint; settings.profiles = profiles; settings.activeProfileId = active
        settings.automaticProfileId = automatic; settings.automaticProfileRecordingID = automaticOwner; settings.outputLanguage = language
    }
}

private final class FrozenChatProtocol: URLProtocol, @unchecked Sendable {
    struct Request: Sendable { let host: String; let body: Data }
    final class Requests: @unchecked Sendable {
        private let lock = NSLock(); private var storage: [Request] = []
        var values: [Request] { lock.lock(); defer { lock.unlock() }; return storage }
        func append(_ value: Request) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
        func reset() { lock.lock(); defer { lock.unlock() }; storage = [] }
    }
    static let requests = Requests()
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "freeze-chat.invalid" || request.url?.host?.hasSuffix("-completion-chat.invalid") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
        }
        Self.requests.append(.init(host: request.url!.host!, body: body))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        let host = request.url!.host!
        let payload: String
        if host.hasSuffix("-completion-chat.invalid") {
            let partial = "data: {\"choices\":[{\"delta\":{\"content\":\"Partial proof\"}}]}\n\n"
            if host.hasPrefix("length-") { payload = partial + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\ndata: [DONE]\n\n" }
            else if host.hasPrefix("missing-") { payload = partial + "data: [DONE]\n\n" }
            else if host.hasPrefix("malformed-") { payload = partial + "data: {broken\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n" }
            else { payload = partial + "data: {\"error\":{\"message\":\"fixture failed\"}}\n\n" }
        } else {
            payload = "data: {\"choices\":[{\"delta\":{\"content\":\"Answer\"}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        }
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
