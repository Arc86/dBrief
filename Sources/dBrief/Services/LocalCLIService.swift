import Foundation
import os

/// AI engine that shells out to a user-configured command-line tool (e.g.
/// `claude -p "$DBRIEF_FULL_PROMPT"`, `ollama run …`, `llm …`) to produce the
/// unified JSON insights. The command is invoked once per recording and must
/// print a JSON object matching the `UnifiedInsightsPrompt` contract to stdout.
actor LocalCLIService {

    /// Run the configured command against a transcript and return parsed insights.
    func analyze(
        transcript: String,
        outputLanguage: AppSettings.OutputLanguage,
        config: LocalCLIConfig
    ) async throws -> LocalInsightsResult {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return LocalInsightsResult(
                titleConcept: "",
                summary: "",
                actionItems: [],
                tags: [],
                sentiment: "neutral"
            )
        }

        let truncated = UnifiedInsightsPrompt.truncate(transcript)
        let systemPrompt = UnifiedInsightsPrompt.systemPrompt(outputLanguage: outputLanguage)
        let userPrompt = UnifiedInsightsPrompt.userPrompt(transcript: truncated)
        let fullPrompt = systemPrompt + "\n\n" + userPrompt

        let output = try await Self.runShellCommand(
            config.command,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            fullPrompt: fullPrompt,
            timeoutSeconds: config.timeoutSeconds
        )

        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw LocalCLIServiceError.emptyOutput }

        do {
            return try MLXInsightsService.decodeAndNormalize(cleaned)
        } catch {
            throw LocalCLIServiceError.invalidJSON(String(cleaned.prefix(500)))
        }
    }

    /// Run the command with a tiny sample prompt for the settings "Test command"
    /// button. Returns trimmed stdout (or throws with stderr/exit details).
    func runTest(config: LocalCLIConfig) async throws -> String {
        let sample = "Reply with a short confirmation that you received this prompt."
        let output = try await Self.runShellCommand(
            config.command,
            systemPrompt: sample,
            userPrompt: sample,
            fullPrompt: sample,
            timeoutSeconds: config.timeoutSeconds
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Shell runner

    /// Run `command` through a login shell (`/bin/zsh -l -c`) so PATH-installed
    /// tools resolve. The prompts are exported as `DBRIEF_*` environment variables
    /// and the full prompt is also piped to stdin. Enforces a hard timeout.
    nonisolated static func runShellCommand(
        _ command: String,
        systemPrompt: String,
        userPrompt: String,
        fullPrompt: String,
        timeoutSeconds: Int
    ) async throws -> String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { throw LocalCLIServiceError.emptyCommand }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-l", "-c", trimmedCommand]

                var environment = ProcessInfo.processInfo.environment
                environment["DBRIEF_SYSTEM_PROMPT"] = systemPrompt
                environment["DBRIEF_USER_PROMPT"] = userPrompt
                environment["DBRIEF_FULL_PROMPT"] = fullPrompt
                process.environment = environment

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                let stdinPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.standardInput = stdinPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: LocalCLIServiceError.launchFailed(error.localizedDescription))
                    return
                }

                // Feed the full prompt on stdin, then close it.
                let stdinHandle = stdinPipe.fileHandleForWriting
                if let data = fullPrompt.data(using: .utf8) {
                    try? stdinHandle.write(contentsOf: data)
                }
                try? stdinHandle.close()

                // Drain both pipes concurrently so a large response can't deadlock
                // on a full pipe buffer while the process is still running.
                let lock = NSLock()
                var stdoutData = Data()
                var stderrData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    lock.lock(); stdoutData = data; lock.unlock()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    lock.lock(); stderrData = data; lock.unlock()
                    group.leave()
                }

                // Timeout watchdog terminates the process; `waitUntilExit` then
                // returns and the drains hit EOF.
                var timedOut = false
                let watchdog = DispatchWorkItem {
                    if process.isRunning {
                        lock.lock(); timedOut = true; lock.unlock()
                        process.terminate()
                    }
                }
                let deadline = DispatchTime.now() + .seconds(max(1, timeoutSeconds))
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline, execute: watchdog)

                process.waitUntilExit()
                watchdog.cancel()
                group.wait()

                lock.lock()
                let didTimeout = timedOut
                let out = String(data: stdoutData, encoding: .utf8) ?? ""
                let err = String(data: stderrData, encoding: .utf8) ?? ""
                lock.unlock()

                if didTimeout {
                    continuation.resume(throwing: LocalCLIServiceError.timeout(seconds: timeoutSeconds))
                } else if process.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    let detail = err.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: LocalCLIServiceError.nonZeroExit(
                        code: Int(process.terminationStatus),
                        stderr: detail.isEmpty ? out : detail
                    ))
                }
            }
        }
    }
}

enum LocalCLIServiceError: Error, LocalizedError {
    case emptyCommand
    case launchFailed(String)
    case nonZeroExit(code: Int, stderr: String)
    case timeout(seconds: Int)
    case emptyOutput
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            "No Local CLI command configured. Set one in Settings → AI."
        case .launchFailed(let msg):
            "Failed to launch Local CLI command: \(msg)"
        case .nonZeroExit(let code, let stderr):
            "Local CLI command exited with code \(code): \(stderr)"
        case .timeout(let seconds):
            "Local CLI command timed out after \(seconds)s."
        case .emptyOutput:
            "Local CLI command produced no output."
        case .invalidJSON(let preview):
            "Local CLI output was not valid JSON. Output started with: \(preview)"
        }
    }
}
