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
    @State private var showsAdvanced = false

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
            Section {
                TextField("Mailbox", text: Binding(
                    get: { config.mailboxEmail },
                    set: { settings.calendarCLIConfig = config.updating(mailboxEmail: $0) }
                ), prompt: Text("name@company.com"))
                .onSubmit { configurationChanged() }

                TextField("Calendar name", text: Binding(
                    get: { config.calendarName ?? "" },
                    set: { settings.calendarCLIConfig = config.updating(calendarName: $0.isEmpty ? nil : $0) }
                ), prompt: Text("Default calendar"))
                .onSubmit { configurationChanged() }

                statusFooter(config: config)

                HStack(spacing: 8) {
                    Button {
                        runRefresh()
                    } label: {
                        if refreshState == .running {
                            Label("Refreshing…", systemImage: "arrow.clockwise")
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(refreshState == .running || !config.isConfigured)

                    Button {
                        runConnectionTest()
                    } label: {
                        if testState == .running {
                            Text("Testing…")
                        } else {
                            Text("Test connection")
                        }
                    }
                    .disabled(testState == .running || !config.isConfigured)

                    Menu {
                        Button("Clear cached meetings", role: .destructive) {
                            recordingManager.clearCalendarCLICache()
                            refreshStatus()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More calendar actions")
                    .disabled(!config.isConfigured)
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("Uses your Claude login and Microsoft 365 connector. Calendar name is optional; first use may request approval in Terminal.")
            }

            Section {
                Picker("Model", selection: modelSelection) {
                    Text("Claude default").tag("__default")
                    Text("Haiku").tag("haiku")
                    Text("Sonnet").tag("sonnet")
                    Text("Custom model ID").tag("__custom")
                }
                if modelSelection.wrappedValue == "__custom" {
                    TextField("Custom model ID", text: $customModelID, prompt: Text("e.g. claude-haiku-4-5"))
                        .onSubmit { applyCustomModel() }
                }

                Picker("Refresh interval", selection: Binding(
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
                    TextField("Custom minutes", value: $customFreshnessMinutes, format: .number)
                        .onSubmit {
                            let minutes = min(1440, max(5, customFreshnessMinutes))
                            settings.calendarCLIConfig = config.updating(listFreshnessSeconds: minutes * 60)
                            customFreshnessMinutes = settings.calendarCLIConfig.listFreshnessSeconds / 60
                        }
                }
            } header: {
                Text("Meeting list")
            } footer: {
                Text(config.listFreshnessSeconds == 0
                     ? "Meetings load only when you press Refresh."
                     : "A stale list refreshes when you open the meeting picker or start recording.")
            }

            Section {
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
                if config.attendeePolicy == .onDemand {
                    LabeledContent("Maximum attendees") {
                        Stepper(value: Binding(
                            get: { config.maxAttendees },
                            set: { value in
                                settings.calendarCLIConfig = config.updating(maxAttendees: value)
                                configurationChanged()
                            }
                        ), in: 1...100) {
                            Text("\(config.maxAttendees)").monospacedDigit()
                        }
                    }
                }
            } header: {
                Text("Meeting attendees")
            } footer: {
                Text(config.attendeePolicy == .never
                     ? "Attendee rosters are never loaded. Invite bodies are never saved."
                     : "Rosters load only when requested for one meeting. Larger meetings omit the roster; invite bodies are never saved.")
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
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

                    TextField("CLI command", text: Binding(
                        get: { config.command ?? "" },
                        set: { settings.calendarCLIConfig = config.updating(command: $0.isEmpty ? nil : $0) }
                    ), prompt: Text("Managed Claude command"))
                    .onSubmit { configurationChanged() }
                    if let command = config.command, !command.isEmpty, !config.validateCommand() {
                        Label("The command conflicts with managed Claude options.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            } footer: {
                Text("Calendar requests consume Claude usage. dBrief saves titles, times, and attendees only when requested.")
            }
        }
        .onAppear {
            customFreshnessMinutes = max(5, config.listFreshnessSeconds / 60)
            if let modelID = config.modelID,
               !Self.modelChoices.contains(where: { $0.id == modelID }) {
                customModelID = modelID
            }
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
        VStack(alignment: .leading, spacing: 5) {
            if !config.isConfigured {
                Label("Enter a mailbox to connect", systemImage: "person.crop.circle")
                    .foregroundStyle(.orange)
            } else if let last = lastSuccessfulRefresh {
                Label("Updated \(last.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                Label("No meetings loaded yet", systemImage: "calendar")
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
                .foregroundStyle(partial ? Color.orange : Color.green)
            case .blocked:
                Label("Access blocked — check the Claude login and connector permission, then retest.", systemImage: "lock.fill")
                    .foregroundStyle(.red)
            case .failed:
                Label("The calendar CLI call failed. Check the claude command and its login.", systemImage: "xmark.circle")
                    .foregroundStyle(.red)
            default:
                EmptyView()
            }
            switch refreshState {
            case .reachable(_, let partial) where partial:
                Label("Refresh incomplete; saved meetings remain available.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .blocked:
                Label("Refresh blocked — check Claude connector approval, then retry.", systemImage: "lock.fill")
                    .foregroundStyle(.orange)
            case .failed:
                Label("Refresh failed — showing saved meetings if available. Press Refresh to retry.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .unconfigured:
                Label("Set your mailbox before refreshing.", systemImage: "person.crop.circle")
                    .foregroundStyle(.orange)
            case .idle, .running, .reachable:
                EmptyView()
            }
        }
        .font(.caption)
    }
}
