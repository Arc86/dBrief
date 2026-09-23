import SwiftUI

/// Settings subview for the Claude CLI calendar source: mailbox/calendar
/// configuration, model and timeout, attendee policy, connection test,
/// manual refresh and cache clearing. Native controls only; progress is
/// labelled; status is readable and cancellable.
struct SettingsCalendarCLISection: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager

    @State private var testState: ConnectionTestState = .idle
    @State private var refreshState: ConnectionTestState = .idle
    @State private var lastSuccessfulRefresh: Date?
    @State private var statusTask: Task<Void, Never>?
    @State private var customModelID = ""
    @State private var usesCustomModel = false
    @State private var customFreshnessMinutes = 60
    @State private var usesCustomFreshness = false

    private enum ConnectionTestState: Equatable {
        case idle, running
        case reachable(events: Int, partial: Bool)
        case blocked
        case unconfigured
        case failed
    }

    /// Freshness options shown as minutes; stored as seconds.
    private static let freshnessOptions: [Int] = [5, 15, 30, 60, 120, 360, 720, 1440].map { $0 * 60 }
    private static let modelChoices: [(label: String, id: String?)] = [
        ("Claude default", nil),
        ("Haiku", "haiku"),
        ("Sonnet", "sonnet"),
    ]

    private var modelSelection: Binding<String> {
        Binding(
            get: {
                let modelID = appSettings.calendarCLIConfig.modelID
                if let id = modelID, Self.modelChoices.contains(where: { $0.id == id }) {
                    return id
                }
                return (modelID != nil || usesCustomModel) ? "__custom" : "__default"
            },
            set: { newValue in
                switch newValue {
                case "__default":
                    usesCustomModel = false
                    appSettings.calendarCLIConfig = appSettings.calendarCLIConfig.updating(modelID: nil)
                case "__custom":
                    usesCustomModel = true
                default:
                    usesCustomModel = false
                    appSettings.calendarCLIConfig = appSettings.calendarCLIConfig.updating(modelID: newValue)
                }
            }
        )
    }

    var body: some View {
        @Bindable var settings = appSettings
        let config = settings.calendarCLIConfig

        Group {
            LabeledContent("Mailbox") {
                TextField("name@company.com", text: Binding(
                    get: { config.mailboxEmail },
                    set: { settings.calendarCLIConfig = config.updating(mailboxEmail: $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .onSubmit { configurationChanged() }
            }
            LabeledContent("Calendar") {
                TextField("Default calendar", text: Binding(
                    get: { config.calendarName ?? "" },
                    set: { settings.calendarCLIConfig = config.updating(calendarName: $0.isEmpty ? nil : $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .onSubmit { configurationChanged() }
            }

            Picker("Model", selection: modelSelection) {
                Text("Claude default").tag("__default")
                Text("Haiku").tag("haiku")
                Text("Sonnet").tag("sonnet")
                Text("Custom model ID").tag("__custom")
            }
            if modelSelection.wrappedValue == "__custom" {
                LabeledContent("Custom model ID") {
                    TextField("e.g. claude-haiku-4-5", text: $customModelID)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                        .onSubmit { applyCustomModel() }
                }
                Text("Passed as one --model value; anything unsafe is ignored and the Claude default is kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Timeout") {
                Text("\(config.timeoutSeconds) s")
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
                Slider(value: Binding(
                    get: { Double(config.timeoutSeconds) },
                    set: { settings.calendarCLIConfig = config.updating(timeoutSeconds: Int($0)) }
                ), in: 30...300, step: 5)
                .frame(maxWidth: 220)
            }
            Text("Applies to each calendar call; the call covers connector pages and output generation.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("List refresh", selection: Binding(
                get: {
                    usesCustomFreshness || (config.listFreshnessSeconds != 0 && !Self.freshnessOptions.contains(config.listFreshnessSeconds))
                        ? -1 : config.listFreshnessSeconds
                },
                set: { seconds in
                    usesCustomFreshness = seconds == -1
                    if seconds == -1 {
                        customFreshnessMinutes = max(5, config.listFreshnessSeconds / 60)
                        settings.calendarCLIConfig = config.updating(listFreshnessSeconds: customFreshnessMinutes * 60)
                    } else {
                        settings.calendarCLIConfig = config.updating(listFreshnessSeconds: seconds)
                    }
                }
            )) {
                ForEach(Self.freshnessOptions, id: \.self) { seconds in
                    Text("\(seconds / 60) min").tag(seconds)
                }
                Text("Custom…").tag(-1)
                Text("Manual only").tag(0)
            }
            if usesCustomFreshness || (config.listFreshnessSeconds != 0 && !Self.freshnessOptions.contains(config.listFreshnessSeconds)) {
                LabeledContent("Custom minutes") {
                    TextField("5–1440", value: $customFreshnessMinutes, format: .number)
                        .frame(width: 80)
                        .onSubmit {
                            let minutes = min(1440, max(5, customFreshnessMinutes))
                            settings.calendarCLIConfig = config.updating(listFreshnessSeconds: minutes * 60)
                            customFreshnessMinutes = settings.calendarCLIConfig.listFreshnessSeconds / 60
                        }
                    Text("5–1440 min").foregroundStyle(.secondary)
                }
            }
            Text("A stale day list refreshes when the meeting picker opens or a recording starts. Manual mode fetches only when you press Refresh.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Attendees", selection: Binding(
                get: { config.attendeePolicy },
                set: { policy in
                    settings.calendarCLIConfig = config.updating(attendeePolicy: policy)
                    configurationChanged()
                }
            )) {
                Text("Load on demand").tag(CalendarCLIConfig.AttendeePolicy.onDemand)
                Text("Never").tag(CalendarCLIConfig.AttendeePolicy.never)
            }
            Text("On demand loads rosters only when you press Load attendees for a specific meeting. Matching and selection never fetch attendees.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Attendee limit") {
                Stepper(value: Binding(
                    get: { config.maxAttendees },
                    set: { value in
                        settings.calendarCLIConfig = config.updating(maxAttendees: value)
                        configurationChanged()
                    }
                ), in: 1...100) {
                    Text("\(config.maxAttendees)")
                        .monospacedDigit()
                }
            }
            Text("Meetings with more invitees omit the whole roster. The limit caps what dBrief saves, not what the connector retrieves.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            statusFooter(config: config)

            HStack {
                Button {
                    runConnectionTest()
                } label: {
                    if testState == .running {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Testing…")
                        }
                    } else {
                        Text("Test connection")
                    }
                }
                .disabled(testState == .running || !config.isConfigured)

                Button {
                    runRefresh()
                } label: {
                    if refreshState == .running {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Refreshing…")
                        }
                    } else {
                        Text("Refresh")
                    }
                }
                .disabled(refreshState == .running || !config.isConfigured)

                Button("Clear cache", role: .destructive) {
                    recordingManager.clearCalendarCLICache()
                    refreshStatus()
                }
                .disabled(!config.isConfigured)
            }

            Text("Calendar content passes through your Claude connector and consumes Claude usage. dBrief saves only titles, times and — when you explicitly request them — attendee names and emails. Invite bodies are never kept.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if modelSelection.wrappedValue == "__custom" || config.command != nil {
                LabeledContent("Advanced command") {
                    TextField("Leave empty for the managed Claude command", text: Binding(
                        get: { config.command ?? "" },
                        set: { settings.calendarCLIConfig = config.updating(command: $0.isEmpty ? nil : $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit { configurationChanged() }
                }
                if let command = config.command, !command.isEmpty, !config.validateCommand() {
                    Label("The command contains flags that conflict with the managed invocation (--model, --output-format, --json-schema, tool allowlist).", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .onAppear {
            customFreshnessMinutes = max(5, config.listFreshnessSeconds / 60)
            refreshStatus()
        }
        .onDisappear {
            statusTask?.cancel()
        }
    }

    // MARK: - Actions

    private func configurationChanged() {
        testState = .idle
        refreshState = .idle
        lastSuccessfulRefresh = nil
        recordingManager.calendarCLIConfigurationChanged()
        refreshStatus()
    }

    private func applyCustomModel() {
        let sanitized = CalendarCLIConfig.sanitizedModelID(customModelID)
        appSettings.calendarCLIConfig = appSettings.calendarCLIConfig.updating(modelID: sanitized)
        if sanitized == nil { customModelID = "" }
        configurationChanged()
    }

    private func runConnectionTest() {
        testState = .running
        Task { @MainActor in
            let outcome = await recordingManager.testCalendarCLIConnection()
            switch outcome {
            case .unconfigured: testState = .unconfigured
            case .reachable(let events, let partial): testState = .reachable(events: events, partial: partial)
            case .blocked: testState = .blocked
            case .failed: testState = .failed
            }
            refreshStatus()
        }
    }

    private func runRefresh() {
        refreshState = .running
        Task { @MainActor in
            let outcome = await recordingManager.refreshCalendarCLINow()
            switch outcome {
            case .unconfigured: refreshState = .unconfigured
            case .reachable(let events, let partial): refreshState = .reachable(events: events, partial: partial)
            case .blocked: refreshState = .blocked
            case .failed: refreshState = .failed
            }
            refreshStatus()
        }
    }

    private func refreshStatus() {
        statusTask?.cancel()
        statusTask = Task { @MainActor in
            let status = await recordingManager.calendarCLIStatusForToday()
            if !Task.isCancelled {
                lastSuccessfulRefresh = status?.lastSuccessfulRefresh
            }
        }
    }

    // MARK: - Status

    @ViewBuilder
    private func statusFooter(config: CalendarCLIConfig) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !config.isConfigured {
                Label("Set your mailbox email to connect.", systemImage: "person.crop.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let last = lastSuccessfulRefresh {
                Text("Last successful refresh: \(last.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not loaded yet. A day list loads when a recording starts, or with Refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch testState {
            case .reachable(let events, let partial):
                Label {
                    Text(partial
                        ? "Connected — partial data returned for the test window."
                        : "Connected — the connector answered the test window\(events > 0 ? " (\(events) events)" : "").")
                } icon: {
                    Image(systemName: partial ? "exclamationmark.triangle" : "checkmark.circle")
                }
                .font(.caption)
                .foregroundStyle(partial ? Color.orange : Color.green)
            case .blocked:
                Label("Access blocked — check the Claude login and connector permission, then retest.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            case .failed:
                Label("The calendar CLI call failed. Check the claude command and its login.", systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            default:
                EmptyView()
            }
            switch refreshState {
            case .reachable(let events, let partial):
                Label(partial
                      ? "Refresh incomplete — showing the last saved meeting list. Press Refresh to retry."
                      : "Meeting list updated (\(events) events).",
                      systemImage: partial ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(partial ? Color.orange : Color.green)
            case .blocked:
                Label("Refresh blocked — check Claude connector approval, then retry.", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.orange)
            case .failed:
                Label("Refresh failed — showing saved meetings if available. Press Refresh to retry.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            case .unconfigured:
                Label("Set your mailbox before refreshing.", systemImage: "person.crop.circle")
                    .font(.caption).foregroundStyle(.orange)
            case .idle, .running:
                EmptyView()
            }
            Text("First use may ask you to approve the calendar tool in Terminal; the connector uses your Claude subscription login. Switching accounts requires clearing the cache and retesting.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
