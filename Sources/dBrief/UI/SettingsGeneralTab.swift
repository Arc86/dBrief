import AppKit
import Combine
import EventKit
import SwiftUI

struct SettingsGeneralTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(MicrosoftAuthService.self) private var microsoftAuthService
    @Environment(UpdaterController.self) private var updaterController

    @State private var outlookSignInError: String?
    @State private var calendarStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var availableICalCalendars: [ICalCalendarOption] = []
    @State private var startAtLogin: Bool = LoginItemManager.isEnabled

    // Retention / auto-delete UI state
    @State private var runningCleanup: RetentionCategory?
    @State private var cleanupMessage: [RetentionCategory: String] = [:]
    @State private var pendingCleanup: RetentionCategory?

    private let retentionDayOptions = [1, 7, 14, 30, 60, 90, 180, 365]

    var body: some View {
        @Bindable var settings = appSettings
        Form {
            Section("Appearance") {
                Toggle("Start at login", isOn: Binding(
                    get: { startAtLogin },
                    set: { newValue in
                        if LoginItemManager.setEnabled(newValue) {
                            startAtLogin = newValue
                        } else {
                            // Re-read the real state if the OS rejected the change.
                            startAtLogin = LoginItemManager.isEnabled
                        }
                    }
                ))
                Toggle("Show dock icon", isOn: $settings.showDockIcon)
                Toggle("Power user mode", isOn: $settings.powerUserMode)
                if appSettings.powerUserMode {
                    Text("Shows advanced settings and features across all tabs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Reduce neon accents", isOn: $settings.reduceNeon)
                if appSettings.reduceNeon {
                    Text("Uses plain colors instead of glowing gradients and the neon dark-mode backdrop.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.clear)

            Section("Shortcut") {
                LabeledContent("Start/stop recording:") {
                    ShortcutRecorderView(hotkey: $settings.recordHotkey)
                }
                Text("Global shortcut to toggle recording from anywhere. Defaults to ⌃⌥⌘R.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)

            Section("Call Detection") {
                Toggle("Enable call detection", isOn: $settings.callDetectionEnabled)

                if appSettings.callDetectionEnabled {
                    Toggle("Auto-start recording when call detected", isOn: $settings.autoRecordCalls)

                    if !appSettings.autoRecordCalls {
                        Picker("Auto-dismiss prompt:", selection: $settings.autoDismissCallPromptSeconds) {
                            Text("Never").tag(0)
                            Text("After 10 seconds").tag(10)
                            Text("After 15 seconds").tag(15)
                            Text("After 30 seconds").tag(30)
                            Text("After 60 seconds").tag(60)
                        }
                        Text("Automatically dismiss the “call detected” prompt if you don't respond. Clicking the prompt cancels the timer.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Picker("When a call ends:", selection: $settings.stopRecordingOnCallEnd) {
                        ForEach(AppSettings.CallEndAction.allCases, id: \.self) { action in
                            Text(action.displayName).tag(action)
                        }
                    }
                    if appSettings.stopRecordingOnCallEnd != .off {
                        Picker("Apply to:", selection: $settings.callEndScope) {
                            ForEach(AppSettings.CallEndScope.allCases, id: \.self) { scope in
                                Text(scope.displayName).tag(scope)
                            }
                        }
                    }
                    Text("Detects when the meeting app stops using the microphone (Teams, Zoom, Slack, Meet). On older macOS, only works when the meeting app fully quits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.clear)

            if appSettings.callDetectionEnabled {
                Section("Call Platforms") {
                    ForEach(CallDetectionService.knownCallApps, id: \.bundleId) { app in
                        let isEnabled = !appSettings.disabledCallApps.contains(app.bundleId)
                        Toggle(isOn: Binding(
                            get: { isEnabled },
                            set: { enabled in
                                if enabled {
                                    appSettings.disabledCallApps.remove(app.bundleId)
                                } else {
                                    appSettings.disabledCallApps.insert(app.bundleId)
                                }
                            }
                        )) {
                            HStack(spacing: 12) {
                                callPlatformIcon(for: app)
                                    .frame(width: 36, height: 36)

                                Text(app.name)
                            }
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }

            Section("Calendar") {
                // Display the coerced value so the selection always matches a rendered
                // row (a stale `.outlook` shows as Off while Outlook is hidden); writes
                // persist the raw choice and self-restore once a client ID is configured.
                Picker("Source", selection: Binding(
                    get: { settings.effectiveCalendarSource },
                    set: { settings.calendarSource = $0 }
                )) {
                    Text("Off").tag(CalendarSource.disabled)
                    Text("iCal").tag(CalendarSource.iCal)
                    if MicrosoftAuthService.isConfigured {
                        Text("Outlook (Microsoft)").tag(CalendarSource.outlook)
                    }
                }

                switch settings.effectiveCalendarSource {
                case .iCal:
                    if calendarStatus == .fullAccess {
                        Text("Looks up the matching calendar event when a recording stops and pre-fills title, participants, and agenda context.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        LabeledContent("Calendars") {
                            Menu {
                                Button {
                                    settings.selectedICalCalendarIDs = nil
                                } label: {
                                    if settings.selectedICalCalendarIDs == nil {
                                        Label("All Calendars", systemImage: "checkmark")
                                    } else {
                                        Text("All Calendars")
                                    }
                                }

                                Divider()

                                if availableICalCalendars.isEmpty {
                                    Text("No calendars available")
                                } else {
                                    ForEach(availableICalCalendars) { calendar in
                                        Button {
                                            toggleICalCalendar(calendar.id)
                                        } label: {
                                            let isSelected = settings.selectedICalCalendarIDs?
                                                .contains(calendar.id) == true
                                            Label {
                                                Text(calendar.displayName)
                                            } icon: {
                                                Image(systemName: isSelected ? "checkmark" : "circle.fill")
                                                    .foregroundStyle(isSelected ? Color.primary : calendar.color)
                                            }
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Text(iCalCalendarSelectionSummary)
                                    Image(systemName: "chevron.down")
                                        .font(.caption2.weight(.semibold))
                                }
                            }
                            .buttonStyle(.bordered)
                        }

                        Text("Only events from the selected calendars are considered for automatic matching and the post-recording Meeting picker.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if settings.selectedICalCalendarIDs?.isEmpty == true {
                            Label(
                                "No calendars selected. iCal matching will return no meetings.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        } else if unavailableICalCalendarCount > 0 {
                            Label(
                                unavailableICalCalendarMessage,
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    } else {
                        Text("Grant Calendar access in the Permissions tab to enable this.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .outlook:
                    if microsoftAuthService.isSignedIn {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(microsoftAuthService.accountInfo?.displayName ?? "Microsoft Account")
                                    .fontWeight(.medium)
                                Text(microsoftAuthService.accountInfo?.email ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Sign out") {
                                microsoftAuthService.signOut()
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Button("Sign in with Microsoft") {
                                outlookSignInError = nil
                                Task { @MainActor in
                                    do {
                                        try await microsoftAuthService.signIn()
                                    } catch {
                                        outlookSignInError = error.localizedDescription
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            if let error = outlookSignInError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                case .disabled:
                    EmptyView()
                }

                if settings.effectiveCalendarSource != .disabled {
                    Picker("Automatic match window", selection: $settings.calendarMatchWindowMinutes) {
                        ForEach(AppSettings.calendarMatchWindowOptions, id: \.self) { minutes in
                            if minutes == 0 {
                                Text("Only overlapping").tag(minutes)
                            } else {
                                Text("\(minutes) minutes").tag(minutes)
                            }
                        }
                    }
                    Text("Automatically links overlapping events and non-overlapping events whose start time is within the selected window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle(
                        "Show all meetings from the recording day",
                        isOn: $settings.showAllMeetingsFromRecordingDay
                    )
                    Text("Adds the day’s other calendar events to the post-recording Meeting picker. Events outside the automatic match window are never selected automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.clear)

            Section("Storage & privacy") {
                folderRow(title: "Recordings:", url: appSettings.recordingFolderURL) { url in
                    appSettings.recordingFolderURL = url
                }

                folderRow(title: "Transcriptions:", url: appSettings.transcriptionFolderURL) { url in
                    appSettings.transcriptionFolderURL = url
                }

                retentionControls(
                    title: "Auto-delete recordings",
                    help: "Removes audio files older than the selected age from the recordings folder. Transcripts and notes are kept.",
                    enabled: $settings.autoDeleteRecordingsEnabled,
                    days: $settings.autoDeleteRecordingsDays,
                    category: .recordings
                )

                retentionControls(
                    title: "Auto-delete transcripts",
                    help: "Removes transcript, insights, and Markdown note files older than the selected age. Audio recordings are kept.",
                    enabled: $settings.autoDeleteTranscriptsEnabled,
                    days: $settings.autoDeleteTranscriptsDays,
                    category: .transcripts
                )

                if appSettings.autoDeleteRecordingsEnabled || appSettings.autoDeleteTranscriptsEnabled {
                    Text("Cleanup also runs automatically when dBrief launches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.clear)

            Section("Software update") {
                LabeledContent("Check for updates") {
                    Button("Check Now") {
                        updaterController.checkForUpdates()
                    }
                    .disabled(!updaterController.canCheckForUpdates)
                }

                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updaterController.automaticallyChecksForUpdates },
                    set: { updaterController.automaticallyChecksForUpdates = $0 }
                ))

                if let lastCheck = updaterController.lastUpdateCheckDate {
                    Text("Last checked: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.clear)

            Section("Setup guide") {
                LabeledContent("Setup guide") {
                    Button("Reset Onboarding") {
                        appSettings.hasCompletedOnboarding = false
                    }
                    .buttonStyle(.bordered)
                }
                Text("Shows the welcome and setup guide again the next time you open the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .toggleStyle(.smallSwitch)
        .padding(.top, -20)
        .confirmationDialog(
            "Delete \(pendingCleanup?.displayName ?? "files") older than the selected age?",
            isPresented: Binding(
                get: { pendingCleanup != nil },
                set: { if !$0 { pendingCleanup = nil } }
            ),
            presenting: pendingCleanup
        ) { category in
            Button("Delete", role: .destructive) { runCleanup(category) }
            Button("Cancel", role: .cancel) { pendingCleanup = nil }
        } message: { _ in
            Text("This permanently deletes matching files. This can't be undone.")
        }
        .onAppear {
            reloadICalCalendars()
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            reloadICalCalendars()
        }
    }

    private var iCalCalendarSelectionSummary: String {
        guard let selected = appSettings.selectedICalCalendarIDs else {
            return "All Calendars"
        }
        guard !selected.isEmpty else { return "No Calendars" }
        if selected.count == 1,
           let calendar = availableICalCalendars.first(where: { selected.contains($0.id) }) {
            return calendar.title
        }
        return "\(selected.count) Calendars"
    }

    private var unavailableICalCalendarCount: Int {
        guard let selected = appSettings.selectedICalCalendarIDs else { return 0 }
        let available = Set(availableICalCalendars.map(\.id))
        return selected.subtracting(available).count
    }

    private var unavailableICalCalendarMessage: String {
        let count = unavailableICalCalendarCount
        let noun = count == 1 ? "calendar is" : "calendars are"
        return "\(count) selected \(noun) unavailable and won’t provide meetings."
    }

    private func toggleICalCalendar(_ id: String) {
        var selected = appSettings.selectedICalCalendarIDs ?? []
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
        appSettings.selectedICalCalendarIDs = selected
    }

    private func reloadICalCalendars() {
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
        guard calendarStatus == .fullAccess else {
            availableICalCalendars = []
            return
        }

        let store = EKEventStore()
        availableICalCalendars = store.calendars(for: .event)
            .map { calendar in
                ICalCalendarOption(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    sourceTitle: calendar.source.title,
                    color: Color(nsColor: calendar.color)
                )
            }
            .sorted { lhs, rhs in
                let sourceOrder = lhs.sourceTitle.localizedCaseInsensitiveCompare(rhs.sourceTitle)
                if sourceOrder != .orderedSame { return sourceOrder == .orderedAscending }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    @ViewBuilder
    private func retentionControls(
        title: String,
        help: String,
        enabled: Binding<Bool>,
        days: Binding<Int>,
        category: RetentionCategory
    ) -> some View {
        Toggle(title, isOn: enabled)

        if enabled.wrappedValue {
            Picker("Delete after", selection: days) {
                ForEach(retentionDayOptions, id: \.self) { value in
                    Text(retentionLabel(value)).tag(value)
                }
            }
            .pickerStyle(.menu)

            LabeledContent("Clean up now") {
                HStack(spacing: 8) {
                    if let message = cleanupMessage[category] {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if runningCleanup == category {
                        ProgressView().controlSize(.small)
                    }

                    Button("Run") { pendingCleanup = category }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(runningCleanup != nil)
                }
            }

            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func folderRow(
        title: String,
        url: URL,
        onChoose: @escaping (URL) -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                FolderPathControl(url: url)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Button("Choose...") {
                    chooseFolder(completion: onChoose)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func retentionLabel(_ days: Int) -> String {
        switch days {
        case 1: "1 day"
        case 7: "1 week"
        case 14: "2 weeks"
        case 365: "1 year"
        default: "\(days) days"
        }
    }

    private func runCleanup(_ category: RetentionCategory) {
        pendingCleanup = nil
        guard runningCleanup == nil else { return }
        runningCleanup = category

        let days: Int
        let folders: [URL]
        switch category {
        case .recordings:
            days = appSettings.autoDeleteRecordingsDays
            folders = [appSettings.effectiveRecordingFolderURL]
        case .transcripts:
            days = appSettings.autoDeleteTranscriptsDays
            folders = [appSettings.effectiveRecordingFolderURL, appSettings.effectiveTranscriptionFolderURL]
        }

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                RetentionCleanup.cleanup(category: category, olderThanDays: days, in: folders)
            }.value
            cleanupMessage[category] = result.summary
            runningCleanup = nil
        }
    }

    private func chooseFolder(completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            completion(url)
        }
    }

    private func callPlatformIconImage(for app: CallDetectionService.CallApp) -> NSImage? {
        let baseNames = switch app.bundleId {
        case "us.zoom.xos":
            ["Zoom"]
        case "com.microsoft.teams":
            ["Teams Classic", "Teams"]
        case "com.microsoft.teams2":
            ["Teams"]
        case "com.tinyspeck.slackmacgap":
            ["Slack"]
        default:
            [app.name]
        }
        let extensions = ["png", "jpg", "jpeg", "pdf", "icns", "webp", ""]

        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        for name in baseNames {
            for ext in extensions {
                let fileName = ext.isEmpty ? name : "\(name).\(ext)"
                let url = resourceURL.appendingPathComponent("3dPartyIcons/\(fileName)")
                if let image = NSImage(contentsOf: url) {
                    return image
                }
            }
        }
        return nil
    }

    @ViewBuilder
    private func callPlatformIcon(for app: CallDetectionService.CallApp) -> some View {
        glassIconTile {
            if let customIcon = callPlatformIconImage(for: app) {
                Image(nsImage: customIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .scaleEffect(1.2)
            } else if let brand = app.brandIcon {
                brand.text(size: 22)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: app.sfSymbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func glassIconTile<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.45),
                                    .white.opacity(0.15),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                )
                .shadow(color: .black.opacity(0.10), radius: 2, x: 0, y: 1)

            content()
                .padding(1)
        }
    }
}

private struct ICalCalendarOption: Identifiable {
    let id: String
    let title: String
    let sourceTitle: String
    let color: Color

    var displayName: String {
        "\(title) — \(sourceTitle)"
    }
}
