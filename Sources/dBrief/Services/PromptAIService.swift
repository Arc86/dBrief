import Foundation

protocol PromptTextCompleting: Sendable {
    func complete(systemPrompt: String, userMessage: String, configuration: PromptExecutionConfiguration, stage: PrivacyOperation.Stage) async throws -> String
}

/// Service-produced messages are fixed application copy or numeric status codes.
/// Provider bodies, process output, and arbitrary underlying descriptions never enter this boundary.
enum PromptAIError: Error, LocalizedError {
    case missingEndpoint, invalidEndpoint, emptyCommand, profileMissing, unsupportedScope
    case appleUnavailable, localUnavailable, emptyOutput, incompleteOutput, contextLimit
    case providerFailure(Int), unavailable(String)
    var errorDescription: String? {
        switch self {
        case .missingEndpoint: "Configure an AI endpoint in Settings → AI before trying again."
        case .invalidEndpoint: "Choose an OpenAI-compatible or Anthropic endpoint with a valid URL and model in Settings → AI."
        case .emptyCommand: "Configure a Local CLI command in Settings → AI before trying again."
        case .profileMissing: "This profile was deleted. Copy your draft before closing the editor."
        case .unsupportedScope: "This prompt only supports app defaults."
        case .appleUnavailable: "Apple Intelligence is unavailable. Check macOS support and enable Apple Intelligence in System Settings."
        case .localUnavailable: "The local AI helper is unavailable. Install or enable the local AI component in Settings → AI."
        case .emptyOutput: "The AI returned no text. Try again or check the configured model."
        case .incompleteOutput: "The AI response was incomplete, too long, or repetitive. Ask for a shorter response and try again."
        case .contextLimit: "The request exceeds the model’s context size. Shorten the prompt or sample and try again."
        case .providerFailure(let status):
            switch status {
            case 401, 403: "The provider rejected access. Check the API key and account permissions in Settings → AI."
            case 429: "The provider limited this request. Wait and try again, or check your account quota."
            default: "The provider returned HTTP \(status). Check its configuration and service status, then try again."
            }
        case .unavailable(let message): message
        }
    }
}

actor PromptAIService: PromptTextCompleting {
    typealias LocalCompletion = @Sendable (String, String, PrivacyOperation.Stage) async throws -> String
    typealias RemoteCompletion = @Sendable (String, String, Endpoint, PrivacyOperation.Stage) async throws -> String
    typealias CLICompletion = @Sendable (String, String, LocalCLIConfig, PrivacyOperation.Stage) async throws -> String
    private let apple: LocalCompletion
    private let local: LocalCompletion
    private let remote: RemoteCompletion
    private let cli: CLICompletion

    init(apple: @escaping LocalCompletion, local: @escaping LocalCompletion, remote: @escaping RemoteCompletion, cli: @escaping CLICompletion) {
        self.apple = apple; self.local = local; self.remote = remote; self.cli = cli
    }
    init(aiService: AIService, localCLIService: LocalCLIService, localPlugin: LocalAIPluginService?) {
        apple = { system, user, stage in
            #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                return try await LocalAIService().completeText(systemPrompt: system, userMessage: user, stage: stage)
            }
            #endif
            throw PromptAIError.appleUnavailable
        }
        local = { system, user, stage in
            guard let localPlugin else { throw PromptAIError.localUnavailable }
            var result = ""
            var limiter = ChatResponseLimiter()
            for try await chunk in await localPlugin.chatStream(systemPrompt: system, userMessage: user, stage: stage) {
                try Task.checkCancellation()
                result += limiter.append(chunk)
                guard limiter.stopReason == nil else { throw PromptAIError.incompleteOutput }
            }
            return result
        }
        remote = { system, user, endpoint, stage in
            try await aiService.completeText(systemPrompt: system, userMessage: user, endpoint: endpoint, stage: stage)
        }
        cli = { system, user, config, stage in
            try await localCLIService.completeText(systemPrompt: system, userMessage: user, config: config, stage: stage)
        }
    }

    func complete(systemPrompt: String, userMessage: String, configuration: PromptExecutionConfiguration, stage: PrivacyOperation.Stage) async throws -> String {
        try Task.checkCancellation()
        do {
            let result: String
            switch configuration {
            case .appleIntelligence: result = try await apple(systemPrompt, userMessage, stage)
            case .localModel: result = try await local(systemPrompt, userMessage, stage)
            case .remote(let endpoint):
                try PromptConfigurationResolver.validate(endpoint)
                result = try await remote(systemPrompt, userMessage, endpoint, stage)
            case .localCLI(let config):
                guard !config.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PromptAIError.emptyCommand }
                result = try await cli(systemPrompt, userMessage, config, stage)
            }
            try Task.checkCancellation()
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PromptAIError.emptyOutput }
            var limiter = ChatResponseLimiter()
            _ = limiter.append(result)
            guard limiter.stopReason == nil else { throw PromptAIError.incompleteOutput }
            return result
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let safe = error as? PromptAIError { throw safe }
            if let remote = error as? AIServiceError {
                switch remote {
                case .contextWindowExceeded: throw PromptAIError.contextLimit
                case .truncatedResponse: throw PromptAIError.incompleteOutput
                case .serverError(let code, _): throw PromptAIError.providerFailure(code)
                default: throw PromptAIError.unavailable("The AI returned an invalid response. Check the endpoint and model, then try again.")
                }
            }
            #if canImport(FoundationModels)
            if let local = error as? LocalAIError {
                let knownMessages: Set<String> = [
                    "Apple Intelligence is not supported on this Mac.",
                    "Apple Intelligence is turned off. Enable it in System Settings → Apple Intelligence & Siri, then try again.",
                    "The Apple Intelligence model is still downloading or not ready yet. Try again shortly.",
                    "Apple Intelligence is currently unavailable.",
                    "Apple Intelligence could not process this request because of its safety guardrails.",
                    "Apple Intelligence does not support this language. Choose a different engine.",
                    "Apple Intelligence could not complete the request. Try again or choose a different engine."
                ]
                if knownMessages.contains(local.localizedDescription) { throw PromptAIError.unavailable(local.localizedDescription) }
                throw PromptAIError.appleUnavailable
            }
            #endif
            if let cli = error as? LocalCLIServiceError {
                switch cli {
                case .emptyCommand: throw PromptAIError.emptyCommand
                case .emptyOutput: throw PromptAIError.emptyOutput
                case .outputTooLong: throw PromptAIError.incompleteOutput
                case .timeout(let seconds): throw PromptAIError.unavailable("The Local CLI command timed out after \(seconds) seconds. Allow more time or try a shorter request.")
                case .nonZeroExit(let code, _): throw PromptAIError.unavailable("The Local CLI command exited with code \(code). Check its command and authentication in Settings → AI.")
                case .launchFailed: throw PromptAIError.unavailable("The Local CLI command could not be launched. Check its executable path and permissions in Settings → AI.")
                case .invalidJSON: throw PromptAIError.unavailable("The Local CLI command returned an invalid response. Check that it supports the requested output format.")
                }
            }
            if let network = error as? URLError, network.code == .cancelled { throw CancellationError() }
            throw PromptAIError.unavailable("The configured AI could not complete the request. Check the connection or local model, then try again.")
        }
    }
}
