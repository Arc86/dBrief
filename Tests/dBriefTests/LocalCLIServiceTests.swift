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

struct LocalCLIFormattingRetryTests {
    @Test func repairsUnescapedQuotesWithoutRegeneratingTheMeeting() async throws {
        let command = #"if [[ "$DBRIEF_SYSTEM_PROMPT" == *"JSON formatting repair"* ]]; then printf '%s' '{"summary":"The speaker said \"keep the original wording\".","action_items":[],"tags":[],"sentiment":"Neutral"}'; else printf '%s' '{"summary":"The speaker said "keep the original wording".","action_items":[],"tags":[]}'; fi"#
        let result = try await LocalCLIService().analyze(transcript: "A short meeting.", outputLanguage: .matchInput,
            config: .init(command: command, timeoutSeconds: 10))
        #expect(result.summary == "The speaker said \"keep the original wording\".")
    }

    @Test func reportsFailureAfterOneUnsuccessfulRepair() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let command = "echo run >> '\(marker.path)'; printf '%s' '{\"summary\":\"unfinished'"
        do {
            _ = try await LocalCLIService().analyze(transcript: "A short meeting.", outputLanguage: .matchInput,
                config: .init(command: command, timeoutSeconds: 10))
            Issue.record("Expected invalid JSON to fail")
        } catch {
            #expect(error.localizedDescription.contains("formatting retry"))
        }
        let calls = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n")
        #expect(calls.count == 2)
    }

    @Test func acceptsMarkdownFencesWithoutARepair() async throws {
        let command = #"""
printf '%s' '```json
{"summary":"Valid fenced response","action_items":[],"tags":[]}
```'
"""#
        let result = try await LocalCLIService().analyze(transcript: "A short meeting.", outputLanguage: .matchInput,
            config: .init(command: command, timeoutSeconds: 10))
        #expect(result.summary == "Valid fenced response")
    }
}

struct LocalCLICompletionTests {
    @Test func plainCompletionUsesUnmodifiedCommandAndData() async throws {
        let output = try await LocalCLIService().completeText(systemPrompt: "s", userMessage: "$(echo DO-NOT-EXECUTE)", config: .init(command: "cat", timeoutSeconds: 10), stage: .promptImprovement)
        #expect(output == "s\n\n$(echo DO-NOT-EXECUTE)")
    }
    @Test func cancellationTerminatesChildRetainingStdout() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            try await LocalCLIService.runShellCommand("/bin/sleep 30 & child=$!; echo $child > '\(marker.path)'; wait", systemPrompt: "s", userPrompt: "u", fullPrompt: String(repeating: "x", count: 100_000), timeoutSeconds: 20)
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let pid = try #require(Int32(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - start < .seconds(3))
        for _ in 0..<50 {
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(pid, 0) != 0)
    }
    @Test func errorsDoNotExposeProcessOutput() {
        let error = LocalCLIServiceError.nonZeroExit(code: 3, stderr: "private prompt and secret")
        #expect(!error.localizedDescription.contains("private"))
        #expect(!error.localizedDescription.contains("secret"))
    }
}

extension LocalCLICompletionTests {
    @Test func drainsLargeStderrWhileWritingStdin() async throws {
        let input = String(repeating: "x", count: 100_000)
        let output = try await LocalCLIService.runShellCommand("head -c 131072 /dev/zero >&2; cat", systemPrompt: "s", userPrompt: "u", fullPrompt: input, timeoutSeconds: 10)
        #expect(output == input)
    }
    @Test func rejectsUnboundedOutput() async {
        await #expect(throws: LocalCLIServiceError.self) {
            _ = try await LocalCLIService.runShellCommand("head -c 1200000 /dev/zero", systemPrompt: "s", userPrompt: "u", fullPrompt: "f", timeoutSeconds: 10)
        }
    }
    @Test func cancellationBeforeLaunchDoesNotRunCommand() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LocalCLIService.runShellCommand("touch '\(marker.path)'", systemPrompt: "s", userPrompt: "u", fullPrompt: "f", timeoutSeconds: 10)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
