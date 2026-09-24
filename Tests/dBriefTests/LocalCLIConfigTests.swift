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
}
