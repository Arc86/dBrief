import Testing
import Foundation
@testable import dBrief

/// Exercises the real subprocess runner behind the Local CLI engine: env-var and
/// stdin delivery, stdout capture, timeout, and non-zero-exit handling.
struct LocalCLIServiceTests {

    @Test("Full prompt is exported as an environment variable")
    func fullPromptInEnvironment() async throws {
        let output = try await LocalCLIService.runShellCommand(
            "printf '%s' \"$DBRIEF_FULL_PROMPT\"",
            systemPrompt: "sys",
            userPrompt: "usr",
            fullPrompt: "HELLO-ENV",
            timeoutSeconds: 10
        )
        #expect(output == "HELLO-ENV")
    }

    @Test("System and user prompts are exported separately")
    func systemAndUserPromptsInEnvironment() async throws {
        let output = try await LocalCLIService.runShellCommand(
            "printf '%s|%s' \"$DBRIEF_SYSTEM_PROMPT\" \"$DBRIEF_USER_PROMPT\"",
            systemPrompt: "SYS",
            userPrompt: "USR",
            fullPrompt: "ignored",
            timeoutSeconds: 10
        )
        #expect(output == "SYS|USR")
    }

    @Test("Full prompt is also delivered on stdin")
    func fullPromptOnStdin() async throws {
        let output = try await LocalCLIService.runShellCommand(
            "cat",
            systemPrompt: "sys",
            userPrompt: "usr",
            fullPrompt: "STDIN-PAYLOAD",
            timeoutSeconds: 10
        )
        #expect(output == "STDIN-PAYLOAD")
    }

    @Test("Non-zero exit surfaces stderr")
    func nonZeroExitThrows() async {
        await #expect(throws: LocalCLIServiceError.self) {
            _ = try await LocalCLIService.runShellCommand(
                "echo 'boom' 1>&2; exit 3",
                systemPrompt: "s",
                userPrompt: "u",
                fullPrompt: "f",
                timeoutSeconds: 10
            )
        }
    }

    @Test("A command that overruns the timeout is terminated")
    func timeoutTerminatesCommand() async {
        await #expect(throws: LocalCLIServiceError.self) {
            _ = try await LocalCLIService.runShellCommand(
                "sleep 5",
                systemPrompt: "s",
                userPrompt: "u",
                fullPrompt: "f",
                timeoutSeconds: 1
            )
        }
    }

    @Test("Empty command throws emptyCommand")
    func emptyCommandThrows() async {
        await #expect(throws: LocalCLIServiceError.self) {
            _ = try await LocalCLIService.runShellCommand(
                "   ",
                systemPrompt: "s",
                userPrompt: "u",
                fullPrompt: "f",
                timeoutSeconds: 10
            )
        }
    }

    @Test("analyze() parses JSON printed by the command")
    func analyzeParsesCommandJSON() async throws {
        // A command that ignores its input and prints a fixed JSON object.
        let json = #"{"title_concept":"T","summary":"S","action_items":["A to do X"],"tags":["t1"],"sentiment":"Neutral"}"#
        let config = LocalCLIConfig(command: "printf '%s' '\(json)'", timeoutSeconds: 10)
        let result = try await LocalCLIService().analyze(
            transcript: "Some non-empty transcript.",
            outputLanguage: .matchInput,
            config: config
        )
        #expect(result.titleConcept == "T")
        #expect(result.summary == "S")
        #expect(result.actionItems == ["A to do X"])
        #expect(result.tags == ["t1"])
    }
}
