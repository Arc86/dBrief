import Testing
import Foundation
@testable import dBrief

/// Exercises the calendar transport against fake shell commands: stdin echo
/// validation, timeouts, cancellation, nonzero exits and malformed output.
/// The managed command itself is never executed here — launching the real CLI
/// belongs to live verification, not unit tests.
@Suite(.serialized)
struct CalendarCLITransportTests {

    static func configured(timeoutSeconds: Int = 30, command: String? = nil, modelID: String? = nil) -> CalendarCLIConfig {
        .unnormalized(modelID: modelID, timeoutSeconds: timeoutSeconds,
                      mailboxEmail: "ada.lovelace@example.com", command: command)
    }

    static func window() -> CalendarCLIWindow {
        let start = CalendarCLITimeParsing.connectorUTCDate("2026-09-22T00:00:00Z").unsafelyUnwrapped
        let end = CalendarCLITimeParsing.connectorUTCDate("2026-09-23T00:00:00Z").unsafelyUnwrapped
        return CalendarCLIWindow(start: start, end: end, timeZoneID: "UTC")
    }

    /// Fake list invocation: extracts the requestID from the prompt on stdin
    /// and prints a valid complete-empty envelope, exercising stdin delivery,
    /// echo validation and decoding end to end without the real CLI.
    static let echoListCommand = #"rid=$(awk '/^requestID: /{print $2; exit}'); printf '{"type":"result","subtype":"success","is_error":false,"structured_output":{"v":1,"requestID":"%s","status":"complete","mailbox":"ada.lovelace@example.com","windowStart":"2026-09-22T00:00:00Z","windowEnd":"2026-09-23T00:00:00Z","events":[],"paginationComplete":true,"totalResultCount":0,"error":null}}' "$rid""#

    // MARK: - Guard clauses

    @Test("Unconfigured mailbox fails before spawning a process")
    func unconfiguredFailsFast() async {
        do {
            _ = try await CalendarCLITransport().list(
                window: Self.window(), config: .unnormalized(timeoutSeconds: 5)
            )
            Issue.record("Expected failure")
        } catch {
            #expect(error is CalendarCLITransportError)
            #expect(error.localizedDescription.contains("mailbox"))
        }
    }

    @Test("Advanced commands with conflicting flags are rejected")
    func conflictingAdvancedCommandRejected() async {
        for flag in ["--model haiku", "--output-format json", "--json-schema {}", "--allowedTools x"] {
            let config = Self.configured(command: "claude -p \(flag)")
            #expect(!config.validateCommand(), "expected rejection for \(flag)")
        }
        #expect(Self.configured(command: "claude -p --no-session-persistence").validateCommand())
    }

    // MARK: - Managed command construction

    @Test("Managed command allowlists exactly one connector tool")
    func managedCommandAllowlist() {
        let list = CalendarCLIConfig.managedCommand(
            allowedTool: CalendarCLIPrompt.calendarSearchTool, modelID: nil
        )
        #expect(list.contains(#"--json-schema "$DBRIEF_CALENDAR_SCHEMA""#))
        #expect(list.contains("--output-format json"))
        #expect(list.contains("--no-session-persistence"))
        #expect(list.contains("--allowedTools \(CalendarCLIPrompt.calendarSearchTool)"))
        #expect(list.contains("--permission-prompts none"))
        #expect(!list.contains("--model "))
        #expect(!list.contains(CalendarCLIPrompt.readResourceTool))

        let detail = CalendarCLIConfig.managedCommand(
            allowedTool: CalendarCLIPrompt.readResourceTool, modelID: "claude-haiku-4-5"
        )
        #expect(detail.contains(#"--model "$DBRIEF_CALENDAR_MODEL""#))
        #expect(detail.contains("--allowedTools \(CalendarCLIPrompt.readResourceTool)"))
        #expect(!detail.contains(CalendarCLIPrompt.calendarSearchTool))
    }

    @Test("Unsanitary model IDs fall back to the Claude default")
    func unsanitaryModelIDFallsBack() {
        #expect(CalendarCLIConfig.sanitizedModelID("claude-haiku-4.5") == "claude-haiku-4.5")
        #expect(CalendarCLIConfig.sanitizedModelID("evil; rm -rf ~") == nil)
        #expect(CalendarCLIConfig.sanitizedModelID("$(reboot)") == nil)
        #expect(CalendarCLIConfig.sanitizedModelID("a\nb") == nil)
        #expect(CalendarCLIConfig.sanitizedModelID("") == nil)
    }

    // MARK: - Process behavior

    @Test("A fake list invocation parses a complete empty result from stdin echo")
    func validListRoundTrip() async throws {
        let transport = CalendarCLITransport()
        let result = try await transport.list(window: Self.window(), config: Self.configured(command: Self.echoListCommand))
        #expect(result.completeness == .complete)
        #expect(result.entries.isEmpty)
        #expect(result.message == nil)
    }

    @Test("Nonzero exits surface as process failures")
    func nonZeroExitFails() async {
        do {
            _ = try await CalendarCLITransport().list(
                window: Self.window(),
                config: Self.configured(command: #"printf '%s' '{"nope":true}'; exit 3"#)
            )
            Issue.record("Expected failure")
        } catch let error as CalendarCLITransportError {
            guard case .processFailed(let status) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(status == 3)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Prose output is rejected as invalid")
    func proseOutputFails() async {
        do {
            _ = try await CalendarCLITransport().list(
                window: Self.window(),
                config: Self.configured(command: #"printf '%s' 'Here is your calendar, no JSON today.'"#)
            )
            Issue.record("Expected failure")
        } catch let error as CalendarCLITransportError {
            guard case .invalidOutput = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Timeout terminates the process group and surfaces a timeout error")
    func timeoutTerminates() async {
        let start = ContinuousClock.now
        do {
            _ = try await CalendarCLITransport().list(
                window: Self.window(),
                config: .unnormalized(timeoutSeconds: 1, mailboxEmail: "ada.lovelace@example.com",
                                      command: "sleep 30")
            )
            Issue.record("Expected timeout")
        } catch let error as CalendarCLITransportError {
            guard case .timeout(let seconds) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(seconds == 1)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test("Cancellation aborts a running invocation")
    func cancellationAborts() async throws {
        let task = Task { () -> CalendarCLIListResult in
            try await CalendarCLITransport().list(
                window: Self.window(),
                config: .unnormalized(timeoutSeconds: 30, mailboxEmail: "ada.lovelace@example.com",
                                      command: "sleep 30")
            )
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    // MARK: - Report hook

    @Test("Report hook carries bounded fields only")
    func reportHookBoundedFields() async throws {
        let reports = ReportCollector()
        let transport = CalendarCLITransport { report in reports.append(report) }
        _ = try await transport.list(window: Self.window(), config: Self.configured(command: Self.echoListCommand))
        let collected = reports.all()
        let report = try #require(collected.first)
        #expect(report.kind == .list)
        #expect(report.outcome == .complete)
        #expect(report.duration >= 0)
        #expect(report.inputTokens == nil) // fake commands print no usage envelope
        #expect(report.outputTokens == nil)
    }

    @Test("Failed invocations report failure without content")
    func reportHookFailure() async throws {
        let reports = ReportCollector()
        let transport = CalendarCLITransport { report in reports.append(report) }
        do {
            _ = try await transport.list(
                window: Self.window(),
                config: Self.configured(command: "exit 2")
            )
            Issue.record("Expected failure")
        } catch {
            // expected
        }
        let collected = reports.all()
        let report = try #require(collected.first)
        #expect(report.outcome == .failed)
        #expect(report.inputTokens == nil)
        #expect(report.outputTokens == nil)
    }
}

final class ReportCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CalendarCLITransport.CallReport] = []

    func append(_ report: CalendarCLITransport.CallReport) {
        lock.withLock { stored.append(report) }
    }

    func all() -> [CalendarCLITransport.CallReport] {
        lock.withLock { stored }
    }
}
