import Foundation

/// Adds an effort override only to the child process being launched.
enum CLIReasoningEnvironment {
    static func applying(_ effort: CLIReasoningEffort,
                         provider: CLIEffortProvider,
                         to environment: [String: String]) -> [String: String] {
        guard provider == .claude, let value = effort.claudeValue else { return environment }
        var result = environment
        result["CLAUDE_CODE_EFFORT_LEVEL"] = value
        return result
    }
}
