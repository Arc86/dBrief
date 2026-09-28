import Foundation
import Testing
@testable import dBrief

struct LocalCLIConfigTests {
    @Test("Old analysis configuration preserves command and gains CLI default effort")
    func oldAnalysisConfigPreservesCommand() throws {
        let data = Data(#"{"command":"claude -p","timeoutSeconds":180}"#.utf8)
        let config = try JSONDecoder().decode(LocalCLIConfig.self, from: data)
        #expect(config.command == "claude -p")
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        #expect(encoded["effort"] as? String == "cliDefault")
    }

    @Test("Unknown effort keeps a custom command and timeout")
    func unknownEffortDoesNotResetCustomCommand() throws {
        let data = Data(#"{"command":"my-wrapper --calendar-free","timeoutSeconds":600,"effort":"future"}"#.utf8)
        let config = try JSONDecoder().decode(LocalCLIConfig.self, from: data)
        #expect(config.command == "my-wrapper --calendar-free")
        #expect(config.timeoutSeconds == 600)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        #expect(encoded["effort"] as? String == "cliDefault")
    }

    @Test("Unknown effort provider falls back without losing a command")
    func unknownProviderPreservesCommand() throws {
        let data = Data(#"{"command":"custom --run","timeoutSeconds":60,"effortProvider":"future"}"#.utf8)
        let config = try JSONDecoder().decode(LocalCLIConfig.self, from: data)
        #expect(config.command == "custom --run")
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        #expect(encoded["effortProvider"] as? String == "commandDefault")
    }
    @Test("Claude model choice survives persistence without changing the command")
    func modelRoundtrip() throws {
        let config = LocalCLIConfig(command: "claude -p", timeoutSeconds: 180, modelID: "sonnet")
        let decoded = try JSONDecoder().decode(LocalCLIConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.modelID == "sonnet")
        #expect(decoded.command == "claude -p")
        #expect(decoded.supportsClaudeModel)
    }

    @Test("Legacy configs use the command's default model")
    func legacyModelDefault() throws {
        let config = try JSONDecoder().decode(LocalCLIConfig.self, from: Data(#"{"command":"claude -p","timeoutSeconds":180}"#.utf8))
        #expect(config.modelID == nil)
        #expect(config.executionCommand == config.command)
    }

    @Test("Model overrides apply only to Claude commands or explicitly selected wrappers")
    func modelProviderScope() {
        let other = LocalCLIConfig(command: "ollama run llama3", timeoutSeconds: 30, modelID: "sonnet")
        #expect(!other.supportsClaudeModel)
        #expect(other.executionCommand == other.command)
        let wrapper = LocalCLIConfig(command: "my-wrapper", timeoutSeconds: 30, effortProvider: .claude, modelID: "haiku")
        #expect(wrapper.supportsClaudeModel)
        #expect(wrapper.executionCommand.contains("ANTHROPIC_MODEL='haiku'"))
        let absolute = LocalCLIConfig(command: "'/usr/local/bin/claude' -p", timeoutSeconds: 30)
        #expect(absolute.supportsClaudeModel)
    }

    @Test("Invalid model IDs cannot enter the shell command")
    func invalidModel() {
        let config = LocalCLIConfig(command: "claude -p", timeoutSeconds: 30, modelID: "bad; touch /tmp/unwanted")
        #expect(config.executionCommand == config.command)
    }

}
