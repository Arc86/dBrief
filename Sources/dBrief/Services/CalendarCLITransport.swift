import Foundation
import os

/// Narrow read-only transport for the Claude CLI calendar adapter. Each call
/// launches one headless `claude` process whose tool access is restricted by an
/// explicit allowlist: list refreshes permit `outlook_calendar_search` only,
/// explicit roster fetches permit `read_resource` only. Every other tool —
/// shell, file, browser, write, calendar mutation — is denied without
/// prompting (`--permission-prompts none`). The prompt reinforces but never
/// replaces that boundary.
///
/// Dynamic values (model, schema) travel through quoted environment variables;
/// prompt content travels on stdin. Nothing user-controlled is concatenated
/// into the command string.
protocol CalendarCLITransporting: Sendable {
    func list(window: CalendarCLIWindow, config: CalendarCLIConfig) async throws -> CalendarCLIListResult
    func detail(entry: CalendarCLIEntry, config: CalendarCLIConfig) async throws -> CalendarCLIEntry
}

struct CalendarCLITransport: CalendarCLITransporting {
    /// Bounded diagnostic report (latency, usage tokens, outcome category).
    /// Never carries meeting content or raw connector output.
    struct CallReport: Sendable {
        enum Kind: String, Sendable { case list, detail }
        enum Outcome: String, Sendable { case complete, partial, blocked, failed, cancelled }

        let kind: Kind
        let duration: TimeInterval
        let inputTokens: Int?
        let outputTokens: Int?
        let outcome: Outcome
    }

    let onReport: (@Sendable (CallReport) -> Void)?

    init(onReport: (@Sendable (CallReport) -> Void)? = nil) {
        self.onReport = onReport
    }

    func list(window: CalendarCLIWindow, config: CalendarCLIConfig) async throws -> CalendarCLIListResult {
        guard config.isConfigured else { throw CalendarCLITransportError.notConfigured }
        guard config.validateCommand() else { throw CalendarCLITransportError.invalidCommand }
        let requestID = UUID()
        let command = config.command ?? CalendarCLIConfig.managedCommand(
            allowedTool: CalendarCLIPrompt.calendarSearchTool, modelID: config.modelID
        )
        let startedAt = Date()
        do {
            let raw = try await invoke(
                command: command,
                schema: CalendarCLIPrompt.listJSONSchema,
                system: CalendarCLIPrompt.listSystemPrompt,
                user: CalendarCLIPrompt.listUserPrompt(
                    window: window,
                    mailbox: CalendarCLIConfig.normalizedMailbox(config.mailboxEmail),
                    calendarName: config.calendarName,
                    requestID: requestID
                ),
                config: config
            )
            let result = try CalendarCLIPrompt.listResult(from: raw, requestID: requestID, window: window, config: config)
            report(.list, raw: raw, startedAt: startedAt, callOutcome(from: result.completeness))
            return result
        } catch {
            throw failure(.list, error: error, startedAt: startedAt, timeoutSeconds: config.timeoutSeconds)
        }
    }

    func detail(entry: CalendarCLIEntry, config: CalendarCLIConfig) async throws -> CalendarCLIEntry {
        guard config.isConfigured else { throw CalendarCLITransportError.notConfigured }
        guard config.validateCommand() else { throw CalendarCLITransportError.invalidCommand }
        let requestID = UUID()
        let command = config.command ?? CalendarCLIConfig.managedCommand(
            allowedTool: CalendarCLIPrompt.readResourceTool, modelID: config.modelID
        )
        let startedAt = Date()
        do {
            let raw = try await invoke(
                command: command,
                schema: CalendarCLIPrompt.detailJSONSchema(cap: config.maxAttendees),
                system: CalendarCLIPrompt.detailSystemPrompt,
                user: CalendarCLIPrompt.detailUserPrompt(entry: entry, cap: config.maxAttendees, requestID: requestID),
                config: config
            )
            let outcome = try CalendarCLIPrompt.validateDetail(
                CalendarCLIPrompt.decodeCLIResultEnvelope(raw, as: CalendarCLIDetailEnvelope.self)
                    .structuredOutput.unsafelyUnwrapped,
                requestID: requestID,
                expectedURI: entry.key.resourceURI,
                expectedStart: entry.event.startDate,
                expectedEnd: entry.event.endDate,
                cap: config.maxAttendees
            )
            report(.detail, raw: raw, startedAt: startedAt, callOutcome(from: outcome.completeness))
            // Only a complete, verified fetch stamps freshness; blocked/partial
            // outcomes preserve the previous state.
            let fetchedAt = outcome.completeness == .complete ? Date() : entry.detailsFetchedAt
            let updatedEvent = CalendarEvent(
                uid: entry.event.uid,
                title: entry.event.title,
                attendees: outcome.people,
                organizer: entry.event.organizer,
                body: "", // Bodies are discarded after the explicit read; never stored.
                location: entry.event.location,
                isOnline: entry.event.isOnline,
                isAllDay: entry.event.isAllDay,
                startDate: entry.event.startDate,
                endDate: entry.event.endDate
            )
            return CalendarCLIEntry(
                key: entry.key,
                event: updatedEvent,
                sourceRevision: outcome.revision ?? entry.sourceRevision,
                detailsFetchedAt: fetchedAt,
                attendeeState: outcome.state,
                attendeeCount: outcome.attendeeCount ?? entry.attendeeCount,
                isCancelled: entry.isCancelled
            )
        } catch {
            throw failure(.detail, error: error, startedAt: startedAt, timeoutSeconds: config.timeoutSeconds)
        }
    }

    // MARK: - Process invocation

    private func invoke(
        command: String,
        schema: String,
        system: String,
        user: String,
        config: CalendarCLIConfig
    ) async throws -> String {
        try await PrivacyTrace.perform(
            PrivacyOperation(
                stage: .calendarFetch,
                data: [.metadata],
                destination: .externallyManaged(provider: .claudeCLI)
            )
        ) {
            var environment = ProcessInfo.processInfo.environment
            if let loginPath = try await LocalCLIService.loginShellPath(), !loginPath.isEmpty {
                environment["PATH"] = loginPath
            }
            environment["DBRIEF_CALENDAR_SCHEMA"] = schema
            if let modelID = CalendarCLIConfig.sanitizedModelID(config.modelID) {
                environment["DBRIEF_CALENDAR_MODEL"] = modelID
            }
            return try await LocalCLIProcessRunner.run(
                command: command,
                environment: environment,
                input: system + "\n\n" + user,
                timeoutSeconds: config.timeoutSeconds
            )
        }
    }

    // MARK: - Diagnostics

    private func report(
        _ kind: CallReport.Kind, raw: String?, startedAt: Date, _ outcome: CallReport.Outcome
    ) {
        guard let onReport else { return }
        var inputTokens: Int?
        var outputTokens: Int?
        if let raw,
           let envelope = try? JSONDecoder().decode(CalendarCLIUsageEnvelope.self, from: Data(raw.utf8)),
           let usage = envelope.usage {
            inputTokens = usage.input_tokens
            outputTokens = usage.output_tokens
        }
        onReport(CallReport(
            kind: kind,
            duration: Date().timeIntervalSince(startedAt),
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            outcome: outcome
        ))
    }

    /// Maps, reports and re-raises a failed invocation. Cancellation passes
    /// through unchanged; everything else becomes a bounded transport error.
    private func failure(
        _ kind: CallReport.Kind, error: Error, startedAt: Date, timeoutSeconds: Int
    ) -> Error {
        let mapped: Error
        switch error {
        case let error as CalendarCLITransportError:
            mapped = error
        case is CancellationError:
            mapped = CancellationError()
        case LocalCLIServiceError.timeout:
            mapped = CalendarCLITransportError.timeout(seconds: timeoutSeconds)
        case LocalCLIServiceError.nonZeroExit(let code, _):
            mapped = CalendarCLITransportError.processFailed(status: code)
        case LocalCLIServiceError.outputTooLong:
            mapped = CalendarCLITransportError.invalidOutput(.undecodableOutput)
        case LocalCLIServiceError.emptyOutput:
            mapped = CalendarCLITransportError.invalidOutput(.emptyOutput)
        default:
            mapped = error
        }
        guard let onReport else { return mapped }
        onReport(CallReport(
            kind: kind,
            duration: Date().timeIntervalSince(startedAt),
            inputTokens: nil,
            outputTokens: nil,
            outcome: mapped is CancellationError ? .cancelled : .failed
        ))
        return mapped
    }

    private func callOutcome(from completeness: CalendarCLICompleteness) -> CallReport.Outcome {
        switch completeness {
        case .complete: .complete
        case .partial: .partial
        case .blocked: .blocked
        }
    }
}

enum CalendarCLITransportError: Error, LocalizedError {
    /// A bounded category, never a raw message: diagnostics stay free of
    /// connector response bodies, tokens and meeting contents.
    enum Reason: String, Sendable {
        case emptyOutput
        case undecodableOutput
        case cliReportedError
        case missingStructuredOutput
        case unsupportedPayloadVersion
        case requestIDMismatch
        case mailboxMismatch
        case windowMismatch
        case unknownStatus
        case occurrenceIdentityMismatch
        case rosterExceedsCap
        case invalidAttendeeCount
    }

    case notConfigured
    case invalidCommand
    case timeout(seconds: Int)
    case processFailed(status: Int)
    case invalidOutput(Reason)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "No mailbox is configured for the Claude CLI calendar source."
        case .invalidCommand:
            "The advanced calendar CLI command contains flags that conflict with the managed invocation."
        case .timeout(let seconds):
            "The calendar CLI call timed out after \(seconds)s."
        case .processFailed(let status):
            "The calendar CLI command exited with code \(status). Check its authentication and connection."
        case .invalidOutput(let reason):
            "The calendar CLI response was rejected: \(reason.diagnosticText)"
        case .cancelled:
            "The calendar CLI call was cancelled."
        }
    }
}

extension CalendarCLITransportError.Reason {
    var diagnosticText: String {
        switch self {
        case .emptyOutput: "the command produced no output"
        case .undecodableOutput: "the output was not a valid result envelope"
        case .cliReportedError: "the CLI reported an error instead of a result"
        case .missingStructuredOutput: "the structured output payload was missing"
        case .unsupportedPayloadVersion: "the payload version is unsupported"
        case .requestIDMismatch: "the response did not match this request"
        case .mailboxMismatch: "the response was for a different mailbox"
        case .windowMismatch: "the response was for a different date window"
        case .unknownStatus: "the response status was unrecognized"
        case .occurrenceIdentityMismatch: "the response did not match the requested occurrence"
        case .rosterExceedsCap: "the roster exceeded the configured attendee limit"
        case .invalidAttendeeCount: "the attendee count was invalid"
        }
    }
}
