import Foundation

/// An immutable route snapshot. Debug descriptions deliberately omit credentials and shell code.
enum PromptExecutionConfiguration: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case appleIntelligence
    case localModel
    case remote(Endpoint)
    case localCLI(LocalCLIConfig)

    var displayName: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        case .localModel: "Gemma 4 E4B Local"
        case .remote(let endpoint): "\(endpoint.name) · \(endpoint.modelName)"
        case .localCLI: "Local CLI"
        }
    }
    var destinationDescription: String {
        switch self {
        case .appleIntelligence, .localModel: "On this Mac"
        case .remote(let endpoint): URLComponents(string: endpoint.baseURL)?.host ?? "Configured remote endpoint"
        case .localCLI: "Externally managed by your configured command"
        }
    }
    var description: String {
        switch self {
        case .appleIntelligence: "appleIntelligence"
        case .localModel: "localModel"
        case .remote: "remote(configured endpoint)"
        case .localCLI: "localCLI(configured command)"
        }
    }
    var debugDescription: String { description }
}

@MainActor
enum PromptConfigurationResolver {
    static func resolve(identity: PromptIdentity, settings: AppSettings) throws -> PromptExecutionConfiguration {
        let profile = try profile(identity: identity, settings: settings)
        let engine = profile?.overrides.aiEngine ?? settings.aiEngine
        switch engine {
        case .appleIntelligence: return .appleIntelligence
        case .qwenLocal: return .localModel
        case .localCLI:
            guard !settings.localCLIConfig.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PromptAIError.emptyCommand }
            return .localCLI(settings.localCLIConfig)
        case .remoteEndpoint:
            let override = profile?.overrides.aiEndpointId.flatMap { id in settings.aiEndpoints.first { $0.id == id } }
            guard let endpoint = override ?? settings.defaultAIEndpoint else { throw PromptAIError.missingEndpoint }
            try validate(endpoint)
            return .remote(endpoint)
        }
    }

    static func fallbackExplanation(identity: PromptIdentity, settings: AppSettings) -> String? {
        guard let configuration = try? resolve(identity: identity, settings: settings),
              case .remote = configuration else { return nil }
        let editedProfile = try? profile(identity: identity, settings: settings)
        if let id = editedProfile?.overrides.aiEndpointId {
            if settings.aiEndpoints.contains(where: { $0.id == id }) { return nil }
            if let defaultID = settings.defaultAIEndpointId,
               !settings.aiEndpoints.contains(where: { $0.id == defaultID }) {
                return "The profile and default endpoints are unavailable. Using the first configured endpoint."
            }
            return "This profile’s endpoint is unavailable. Using the app’s default endpoint."
        }
        if let id = settings.defaultAIEndpointId,
           !settings.aiEndpoints.contains(where: { $0.id == id }) {
            return "The saved default endpoint is unavailable. Using the first configured endpoint."
        }
        return nil
    }

    private static func profile(identity: PromptIdentity, settings: AppSettings) throws -> MeetingProfile? {
        switch identity.scope {
        case .appDefaults: return nil
        case .profile(let id):
            guard identity.kind != .spokenSummary, identity.kind != .voiceStyle else { throw PromptAIError.unsupportedScope }
            guard let profile = settings.profiles.first(where: { $0.id == id }) else { throw PromptAIError.profileMissing }
            return profile
        }
    }

    nonisolated static func validate(_ endpoint: Endpoint) throws {
        guard endpoint.provider == .anthropic || endpoint.provider == .openAICompatible,
              let url = URLComponents(string: endpoint.baseURL),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false,
              !endpoint.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PromptAIError.invalidEndpoint
        }
    }
}
