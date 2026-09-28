import Foundation

/// Configuration for the Local CLI AI engine: a shell command that receives the
/// analysis prompt (via `$DBRIEF_*` environment variables and stdin) and prints a
/// JSON result to stdout. One global config; the command is run through a login
/// shell so PATH-installed tools (`claude`, `ollama`, `llm`, …) resolve.
struct LocalCLIConfig: Codable, Sendable, Equatable {
    /// Shell command. `$DBRIEF_SYSTEM_PROMPT`, `$DBRIEF_USER_PROMPT`, and
    /// `$DBRIEF_FULL_PROMPT` are exported into the environment; the full prompt is
    /// also piped to stdin.
    var command: String

    /// Maximum seconds to wait before the command is terminated.
    var timeoutSeconds: Int

    var effort: CLIReasoningEffort
    var effortProvider: CLIEffortProvider
    var modelID: String?

    init(command: String, timeoutSeconds: Int,
         effort: CLIReasoningEffort = .cliDefault,
         effortProvider: CLIEffortProvider = .commandDefault,
         modelID: String? = nil) {
        self.command = command
        self.timeoutSeconds = timeoutSeconds
        self.effort = effort
        self.effortProvider = effortProvider
        self.modelID = CalendarCLIConfig.sanitizedModelID(modelID)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? Self.default.command
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? Self.default.timeoutSeconds
        let rawEffort = try container.decodeIfPresent(String.self, forKey: .effort)
        effort = rawEffort.flatMap(CLIReasoningEffort.init(rawValue:)) ?? .cliDefault
        let rawProvider = try container.decodeIfPresent(String.self, forKey: .effortProvider)
        effortProvider = rawProvider.flatMap(CLIEffortProvider.init(rawValue:)) ?? .commandDefault
        modelID = CalendarCLIConfig.sanitizedModelID(try container.decodeIfPresent(String.self, forKey: .modelID))
    }

    private enum CodingKeys: String, CodingKey {
        case command, timeoutSeconds, effort, effortProvider, modelID
    }

    /// Direct Claude commands are detected; wrappers opt in via Claude Code.
    var supportsClaudeModel: Bool {
        if effortProvider == .claude { return true }
        guard let executable = command.split(whereSeparator: { $0.isWhitespace }).first else { return false }
        let path = String(executable).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return URL(fileURLWithPath: path).lastPathComponent == "claude"
    }

    /// Export after login-shell startup, so shell initialization cannot replace
    /// the picker choice. Explicit --model flags in custom commands still win.
    var executionCommand: String {
        guard supportsClaudeModel, let id = CalendarCLIConfig.sanitizedModelID(modelID) else { return command }
        return "export ANTHROPIC_MODEL='\(id)'\n\(command)"
    }

    static let `default` = LocalCLIConfig(
        command: "claude -p",
        timeoutSeconds: 180
    )

    /// Presets for the settings "Load Template" menu.
    struct Template: Identifiable, Sendable {
        var id: String { name }
        let name: String
        let command: String
        let effortProvider: CLIEffortProvider
        let effort: CLIReasoningEffort
    }

    static let templates: [Template] = [
        Template(name: "Claude Code", command: "claude -p", effortProvider: .claude, effort: .medium),
        Template(name: "Gemini CLI", command: "gemini -p \"$DBRIEF_FULL_PROMPT\"", effortProvider: .commandDefault, effort: .cliDefault),
        Template(name: "Codex CLI", command: "codex exec --skip-git-repo-check --sandbox read-only -", effortProvider: .commandDefault, effort: .cliDefault),
        Template(name: "GitHub Copilot CLI", command: "copilot -p \"$DBRIEF_FULL_PROMPT\"", effortProvider: .commandDefault, effort: .cliDefault),
        Template(name: "Ollama (llama3)", command: "ollama run llama3", effortProvider: .commandDefault, effort: .cliDefault),
        Template(name: "llm CLI", command: "llm \"$DBRIEF_FULL_PROMPT\"", effortProvider: .commandDefault, effort: .cliDefault),
        Template(name: "Custom", command: "", effortProvider: .commandDefault, effort: .cliDefault),
    ]
}
