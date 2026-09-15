import Foundation
import Testing
@testable import dBrief

struct PromptAIServiceTests {
    actor Calls {
        var values: [String] = []
        func record(_ value: String) -> String { values.append(value); return "Reply" }
    }
    @Test func dispatchesOnlySelectedProvider() async throws {
        let calls = Calls()
        let service = PromptAIService(apple: { _, _, _ in await calls.record("apple") }, local: { _, _, _ in await calls.record("local") }, remote: { _, _, _, _ in await calls.record("remote") }, cli: { _, _, _, _ in await calls.record("cli") })
        let routes: [PromptExecutionConfiguration] = [.appleIntelligence, .localModel, .remote(.init(name: "Test", baseURL: "https://example.invalid", modelName: "test")), .localCLI(.init(command: "cat", timeoutSeconds: 10))]
        for route in routes {
            #expect(try await service.complete(systemPrompt: "s", userMessage: "u", configuration: route, stage: .promptImprovement) == "Reply")
        }
        #expect(await calls.values == ["apple", "local", "remote", "cli"])
    }
    @Test func rejectsPartialOrEmptyResults() async {
        for output in [" ", String(repeating: "x", count: 65_537), String(repeating: "A substantive repeated line\n", count: 10)] {
            let service = PromptAIService(apple: { _, _, _ in output }, local: { _, _, _ in output }, remote: { _, _, _, _ in output }, cli: { _, _, _, _ in output })
            await #expect(throws: PromptAIError.self) {
                _ = try await service.complete(systemPrompt: "s", userMessage: "u", configuration: .localModel, stage: .promptImprovement)
            }
        }
    }
    @Test func missingHelperHasActionableError() async {
        let service = PromptAIService(aiService: AIService(), localCLIService: LocalCLIService(), localPlugin: nil)
        await #expect(throws: PromptAIError.self) {
            _ = try await service.complete(systemPrompt: "s", userMessage: "u", configuration: .localModel, stage: .promptImprovement)
        }
    }
    @Test func diagnosticsDoNotContainCredentialsOrCommands() {
        let route = PromptExecutionConfiguration.remote(.init(name: "Test", baseURL: "https://user:secret@example.invalid/path?token=hidden", modelName: "m", apiKey: "key-secret"))
        #expect(!String(describing: route).contains("secret"))
        #expect(!route.destinationDescription.contains("hidden"))
        #expect(!String(describing: PromptExecutionConfiguration.localCLI(.init(command: "secret-command", timeoutSeconds: 10))).contains("secret-command"))
    }
}

@MainActor @Suite(.serialized)
struct PromptAIConfigurationTests {
    private func withSettings(_ body: (AppSettings) throws -> Void) throws {
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        try #require(!domain.hasPrefix("com.dbrief.app"))
        let defaults = UserDefaults.standard
        let saved = defaults.persistentDomain(forName: domain)
        defer {
            if let saved { defaults.setPersistentDomain(saved, forName: domain) }
            else { defaults.removePersistentDomain(forName: domain) }
        }
        try body(AppSettings())
    }
    @Test func inactiveProfileAndGlobalPromptsResolveExplicitly() throws {
        try withSettings { settings in
            let shared = Endpoint(name: "Shared", baseURL: "https://shared.invalid", modelName: "shared")
            let own = Endpoint(name: "Own", baseURL: "https://own.invalid", modelName: "own")
            let active = MeetingProfile(name: "Active", overrides: .init(aiEngine: .localCLI))
            let edited = MeetingProfile(name: "Edited", overrides: .init(aiEngine: .remoteEndpoint, aiEndpointId: own.id))
            settings.aiEngine = .remoteEndpoint
            settings.aiEndpoints = [shared, own]
            settings.defaultAIEndpointId = shared.id
            settings.profiles = [active, edited]
            settings.setActiveProfile(active.id)
            settings.routeAutomatically(to: active.id, for: UUID())
            let profileRoute = try PromptConfigurationResolver.resolve(identity: .init(kind: .summary, scope: .profile(edited.id)), settings: settings)
            let globalRoute = try PromptConfigurationResolver.resolve(identity: .init(kind: .spokenSummary, scope: .appDefaults), settings: settings)
            #expect(profileRoute == .remote(own))
            #expect(globalRoute == .remote(shared))
            #expect(settings.activeProfileId == active.id)
        }
    }
    @Test func missingProfileEndpointUsesDisclosedDefault() throws {
        try withSettings { settings in
            let endpoint = Endpoint(name: "Default", baseURL: "http://localhost:8080", modelName: "test")
            let profile = MeetingProfile(name: "Edited", overrides: .init(aiEngine: .remoteEndpoint, aiEndpointId: UUID()))
            settings.profiles = [profile]
            settings.aiEndpoints = [endpoint]
            let identity = PromptIdentity(kind: .summary, scope: .profile(profile.id))
            let route = try PromptConfigurationResolver.resolve(identity: identity, settings: settings)
            #expect(route == .remote(endpoint))
            #expect(PromptConfigurationResolver.fallbackExplanation(identity: identity, settings: settings) != nil)
            settings.aiEndpoints = []
            #expect(throws: PromptAIError.self) { try PromptConfigurationResolver.resolve(identity: identity, settings: settings) }
        }
    }
    @Test func configurationRejectsUnsupportedProviderAndEmptyCLI() throws {
        try withSettings { settings in
            settings.aiEngine = .remoteEndpoint
            settings.aiEndpoints = [.init(name: "Speech", baseURL: "https://example.invalid", modelName: "speech", provider: .deepgram)]
            let identity = PromptIdentity(kind: .summary, scope: .appDefaults)
            #expect(throws: PromptAIError.self) { try PromptConfigurationResolver.resolve(identity: identity, settings: settings) }
            settings.aiEngine = .localCLI
            settings.localCLIConfig = .init(command: "   ", timeoutSeconds: 10)
            #expect(throws: PromptAIError.self) { try PromptConfigurationResolver.resolve(identity: identity, settings: settings) }
        }
    }
}

struct PromptAIRemoteTests {
    @Test(arguments: [Endpoint.Provider.openAICompatible, .anthropic])
    func transportsBothProviderShapes(provider: Endpoint.Provider) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PromptCompletionURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = AIService(session: session)
        let result = try await service.completeText(systemPrompt: "system-test", userMessage: "user-test", endpoint: .init(name: "Test", baseURL: "https://success.invalid", modelName: "test", provider: provider), stage: .promptImprovement)
        #expect(result == "Reply")
    }
    @Test(arguments: [Endpoint.Provider.openAICompatible, .anthropic])
    func rejectsTruncatedProviderResponse(provider: Endpoint.Provider) async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PromptCompletionURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        await #expect(throws: AIServiceError.self) {
            _ = try await AIService(session: session).completeText(systemPrompt: "system-test", userMessage: "user-test", endpoint: .init(name: "Test", baseURL: "https://truncated.invalid", modelName: "test", provider: provider), stage: .promptImprovement)
        }
    }
    @Test(arguments: [401, 429])
    func errorsHideProviderBodies(status: Int) async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PromptCompletionURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = PromptAIService(aiService: AIService(session: session), localCLIService: LocalCLIService(), localPlugin: nil)
        do {
            _ = try await service.complete(systemPrompt: "system-test", userMessage: "user-test", configuration: .remote(.init(name: "Test", baseURL: "https://failure\(status).invalid", modelName: "test")), stage: .promptImprovement)
            Issue.record("Expected provider failure")
        } catch {
            #expect(error is PromptAIError)
            #expect(!error.localizedDescription.contains("secret-provider-body"))
        }
    }
}

private final class PromptCompletionURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let anthropic = request.url!.path.contains("messages")
        let truncated = request.url!.host == "truncated.invalid"
        let status = request.url!.host == "failure401.invalid" ? 401 : request.url!.host == "failure429.invalid" ? 429 : 200
        if let body = request.httpBody, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            #expect(json["model"] as? String == "test")
            if anthropic { #expect(json["system"] as? String == "system-test") }
            else { #expect((json["messages"] as? [[String: String]])?.first?["content"] == "system-test") }
        }
        let body: String
        if status != 200 { body = "secret-provider-body" }
        else if anthropic { body = "{\"content\":[{\"type\":\"text\",\"text\":\"Reply\"}],\"stop_reason\":\"\(truncated ? "max_tokens" : "end_turn")\"}" }
        else { body = "{\"choices\":[{\"message\":{\"content\":\"Reply\"},\"finish_reason\":\"\(truncated ? "length" : "stop")\"}]}" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension PromptAIServiceTests {
    @Test func underlyingCLIDiagnosticsAreNeverDisplayed() async {
        let errors: [LocalCLIServiceError] = [.launchFailed("private-secret"), .nonZeroExit(code: 3, stderr: "private-secret"), .invalidJSON("private-secret")]
        for error in errors {
            let service = PromptAIService(apple: { _, _, _ in "" }, local: { _, _, _ in "" }, remote: { _, _, _, _ in "" }, cli: { _, _, _, _ in throw error })
            do {
                _ = try await service.complete(systemPrompt: "s", userMessage: "u", configuration: .localCLI(.init(command: "cat", timeoutSeconds: 1)), stage: .promptImprovement)
                Issue.record("Expected command failure")
            } catch {
                #expect(error is PromptAIError)
                #expect(!error.localizedDescription.contains("private-secret"))
            }
        }
    }
    #if canImport(FoundationModels)
    @Test func unknownAppleErrorDescriptionsAreNeverDisplayed() async {
        let service = PromptAIService(apple: { _, _, _ in throw LocalAIError.generation("private-secret") }, local: { _, _, _ in "" }, remote: { _, _, _, _ in "" }, cli: { _, _, _, _ in "" })
        do {
            _ = try await service.complete(systemPrompt: "s", userMessage: "u", configuration: .appleIntelligence, stage: .promptImprovement)
            Issue.record("Expected Apple failure")
        } catch {
            #expect(error is PromptAIError)
            #expect(!error.localizedDescription.contains("private-secret"))
        }
    }
    #endif
}
