import Foundation

/// A CLI-specific choice. CLI default delegates to the child's inherited settings.
enum CLIReasoningEffort: String, Codable, CaseIterable, Hashable, Sendable {
    case cliDefault, low, medium, high, xhigh, max

    var claudeValue: String? { self == .cliDefault ? nil : rawValue }
}

enum CLIEffortProvider: String, Codable, Sendable {
    case commandDefault, claude
}
