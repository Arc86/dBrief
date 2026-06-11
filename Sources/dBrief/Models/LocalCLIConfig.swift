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

    static let `default` = LocalCLIConfig(
        command: "claude -p \"$DBRIEF_FULL_PROMPT\"",
        timeoutSeconds: 180
    )

    /// Presets for the settings "Load Template" menu.
    struct Template: Identifiable, Sendable {
        var id: String { name }
        let name: String
        let command: String
    }

    static let templates: [Template] = [
        Template(name: "Claude Code", command: "claude -p \"$DBRIEF_FULL_PROMPT\""),
        Template(name: "Gemini CLI", command: "gemini -p \"$DBRIEF_FULL_PROMPT\""),
        Template(name: "Codex CLI", command: "codex exec \"$DBRIEF_FULL_PROMPT\""),
        Template(name: "GitHub Copilot CLI", command: "copilot -p \"$DBRIEF_FULL_PROMPT\""),
        Template(name: "Ollama (llama3)", command: "ollama run llama3"),
        Template(name: "llm CLI", command: "llm \"$DBRIEF_FULL_PROMPT\""),
        Template(name: "Custom", command: ""),
    ]
}
