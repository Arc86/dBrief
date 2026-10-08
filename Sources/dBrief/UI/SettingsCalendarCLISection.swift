import SwiftUI

/// Settings subview for the Claude CLI calendar source: mailbox/calendar
/// configuration, model and timeout, attendee policy, connection test,
/// manual refresh and cache clearing. Native controls only; progress is
/// labelled; status is readable and cancellable.
struct SettingsCalendarCLISection: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status

    @State private var testState: ConnectionTestState = .idle
    @State private var refreshState: ConnectionTestState = .idle
    @State private var lastSuccessfulRefresh: Date?
    @State private var statusTask: Task<Void, Never>?
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
    var body: some View {
        @Bindable var settings = appSettings
        let config = settings.calendarCLIConfig

        SettingsCard("Connection", description: "Uses your Claude login and Microsoft 365 connector") {
            SettingsRow("Mailbox") {
                TextField("Mailbox", text: Binding(
                    get: { config.mailboxEmail },
                    set: { settings.calendarCLIConfig = config.updating(mailboxEmail: $0) }
                ), prompt: Text("name@company.com"))
                .settingsTextField()
                .frame(width: 240)
                .onSubmit { configurationChanged() }
            }
            SettingsRow("Calendar name", caption: "Optional. First use may ask for approval in Terminal.") {
                TextField("Calendar name", text: Binding(
                    get: { config.calendarName ?? "" },
                    set: { settings.calendarCLIConfig = config.updating(calendarName: $0.isEmpty ? nil : $0) }
                ), prompt: Text("Default calendar"))
                .settingsTextField()
                .frame(width: 240)
                .onSubmit { configurationChanged() }
            }
            SettingsStackedRow {
                VStack(alignment: .leading, spacing: 10) {
                    statusFooter(config: config)
                    HStack(spacing: 8) {
                        Button {
                            runRefresh()
                        } label: {
                            Label(refreshState == .running ? "Refreshing…" : "Refresh today", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.settingsPrimary)
                        .disabled(refreshState == .running || !config.isConfigured)

                        Button(testState == .running ? "Testing…" : "Test connection") { runConnectionTest() }
                            .buttonStyle(.settingsSecondary)
                            .disabled(testState == .running || !config.isConfigured)

                        Menu {
                            Button("Clear cached meetings", role: .destructive) {
                                recordingManager.clearCalendarCLICache()
                                refreshStatus()
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("More calendar actions")
                        .disabled(!config.isConfigured)
                    }
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

        SettingsCard("Meeting list") {
            ClaudeModelPicker(modelID: Binding(
                get: { settings.calendarCLIConfig.modelID },
                set: { modelID in
                    settings.calendarCLIConfig = settings.calendarCLIConfig.updating(modelID: .some(modelID))
                    configurationChanged()
                }
            ))

            if config.modelID?.lowercased().contains("haiku") == true {
                SettingsRow("Reasoning effort") {
                    Text("Not applicable").uiFont(.system(size: 12)).foregroundStyle(palette.secondary.color)
                }
            } else {
                SettingsRow("Reasoning effort",
                            caption: config.modelID == nil || (config.modelID != "sonnet" && config.modelID != "opus")
                                ? "Support depends on your Claude model." : nil) {
                    CLIReasoningEffortPicker(title: "Reasoning effort", selection: Binding(
                        get: { settings.calendarCLIConfig.effort },
                        set: { effort in
                            settings.calendarCLIConfig = settings.calendarCLIConfig.updating(effort: effort)
                            testState = .idle
                        }
                    ), recommendation: .low)
                }
            }

            SettingsRow("Refresh interval",
                        caption: config.listFreshnessSeconds == 0
                            ? "Meetings load only when you press Refresh."
                            : "A stale list refreshes when you open the meeting picker or start recording.") {
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
                .pickerStyle(.menu)
            }
            if usesCustomFreshness || (config.listFreshnessSeconds != 0 && !Self.freshnessOptions.contains(config.listFreshnessSeconds)) {
                SettingsRow("Custom minutes", caption: "Between 5 and 1440.") {
                    TextField("Custom minutes", value: $customFreshnessMinutes, format: .number)
                        .settingsTextField()
                        .frame(width: 80)
                        .onSubmit {
                            let minutes = min(1440, max(5, customFreshnessMinutes))
                            settings.calendarCLIConfig = config.updating(listFreshnessSeconds: minutes * 60)
                            customFreshnessMinutes = settings.calendarCLIConfig.listFreshnessSeconds / 60
                        }
                }
            }
        }

        SettingsCard("Meeting attendees") {
            SettingsRow("Attendees",
                        caption: config.attendeePolicy == .never
                            ? "Rosters are never loaded. Invite bodies are never saved."
                            : "Rosters load only when requested for one meeting. Larger meetings omit the roster.") {
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
                .pickerStyle(.menu)
            }
            if config.attendeePolicy == .onDemand {
                SettingsRow("Maximum attendees") {
                    HStack(spacing: 6) {
                        Text("\(config.maxAttendees)")
                            .uiFont(.system(size: 12).monospacedDigit())
                            .foregroundStyle(palette.text.color)
                        Stepper("Maximum attendees", value: Binding(
                            get: { config.maxAttendees },
                            set: { value in
                                settings.calendarCLIConfig = config.updating(maxAttendees: value)
                                configurationChanged()
                            }
                        ), in: 1...100)
                    }
                }
            }
        }

        SettingsAdvancedCard(page: .meetings, summary: "Timeout, launcher, command", sections: [.calendarCLIAdvanced]) {
            SettingsCard("Claude CLI", description: "Calendar requests use your Claude usage", section: .calendarCLIAdvanced) {
                SettingsRow("Timeout") {
                    HStack(spacing: 8) {
                        Text("\(config.timeoutSeconds) s")
                            .uiFont(.system(size: 12).monospacedDigit())
                            .foregroundStyle(palette.text.color)
                            .frame(width: 44, alignment: .trailing)
                        Slider(value: Binding(
                            get: { Double(config.timeoutSeconds) },
                            set: { settings.calendarCLIConfig = config.updating(timeoutSeconds: Int($0)) }
                        ), in: 30...300, step: 5)
                        .frame(width: 180)
                    }
                }
                SettingsRow("Claude launcher",
                            caption: "Replaces `claude` in the managed command, e.g. `cswap run 1 --` for another account. Ignored when a CLI command is set.") {
                    TextField("Claude launcher", text: Binding(
                        get: { config.launcher ?? "" },
                        set: { settings.calendarCLIConfig = config.updating(launcher: .some($0)) }
                    ), prompt: Text("claude"))
                    .settingsTextField()
                    .frame(width: 200)
                    .onSubmit { configurationChanged() }
                }
                SettingsRow("CLI command") {
                    HStack(spacing: 8) {
                        if !config.validateCommand() {
                            SettingsStatusPill("Conflicts with managed options", kind: .warning)
                        }
                        TextField("CLI command", text: Binding(
                            get: { config.command ?? "" },
                            set: { settings.calendarCLIConfig = config.updating(command: $0.isEmpty ? nil : $0) }
                        ), prompt: Text("Managed Claude command"))
                        .settingsTextField()
                        .frame(width: 240)
                        .onSubmit { configurationChanged() }
                    }
                }
            }
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
                    .foregroundStyle(status.warning.color)
            } else if let last = lastSuccessfulRefresh {
                Label("Updated \(last.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.circle")
                    .foregroundStyle(palette.secondary.color)
            } else {
                Label("No meetings loaded yet", systemImage: "calendar")
                    .foregroundStyle(palette.secondary.color)
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
                .foregroundStyle(partial ? status.warning.color : status.success.color)
            case .blocked:
                Label("Access blocked — check the Claude login and connector permission, then retest.", systemImage: "lock.fill")
                    .foregroundStyle(status.danger.color)
            case .failed:
                Label("The calendar CLI call failed. Check the claude command and its login.", systemImage: "xmark.circle")
                    .foregroundStyle(status.danger.color)
            default:
                EmptyView()
            }
            switch refreshState {
            case .reachable(_, let partial) where partial:
                Label("Refresh incomplete; saved meetings remain available.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(status.warning.color)
            case .blocked:
                Label("Refresh blocked — check Claude connector approval, then retry.", systemImage: "lock.fill")
                    .foregroundStyle(status.warning.color)
            case .failed:
                Label("Refresh failed — showing saved meetings if available. Press Refresh to retry.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(status.warning.color)
            case .unconfigured:
                Label("Set your mailbox before refreshing.", systemImage: "person.crop.circle")
                    .foregroundStyle(status.warning.color)
            case .idle, .running, .reachable:
                EmptyView()
            }
        }
        .uiFont(.system(size: 11.5))
    }
}
