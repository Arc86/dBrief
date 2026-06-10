import AppKit
import EventKit
import SwiftUI

struct SettingsGeneralTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(MicrosoftAuthService.self) private var microsoftAuthService
    @Environment(UpdateService.self) private var updateService

    @State private var outlookSignInError: String?
    @State private var calendarStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
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
            }
            .listRowBackground(Color.clear)

            Section("Updates") {
                LabeledContent("Check for updates") {
                    HStack(spacing: 8) {
                        if updateService.isChecking {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button("Check Now") {
                            Task {
                                await updateService.checkForUpdates(manual: true)
                                settings.lastUpdateCheckTime = Date()
                            }
                        }
                        .disabled(updateService.isChecking)
                    }
                }

                Toggle("Automatically check for updates", isOn: $settings.autoCheckUpdates)

                if updateService.updateAvailable {
                    HStack {
                        Label(
                            "New version \(updateService.latestVersion ?? "") available",
                            systemImage: "arrow.down.circle.fill"
                        )
                        .foregroundStyle(.orange)
                        Spacer()
                        Button("View Release") {
                            updateService.openReleasePage()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                } else if let error = updateService.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if updateService.latestVersion != nil {
                    Text("You're up to date.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let lastCheck = appSettings.lastUpdateCheckTime {
                    Text("Last checked: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.clear)

            Section("Shortcuts") {
                LabeledContent("Start/stop recording:") {
                    ShortcutRecorderView(hotkey: $settings.recordHotkey)
                }
                Text("Global shortcut to toggle recording from anywhere. Defaults to ⌃⌥⌘R.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)

            Section("Folders") {
                LabeledContent("Recordings:") {
                    HStack {
                        Text(appSettings.recordingFolderURL.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Button("Choose...") {
                            chooseFolder { url in
                                appSettings.recordingFolderURL = url
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                LabeledContent("Transcriptions:") {
                    HStack {
                        Text(appSettings.transcriptionFolderURL.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Button("Choose...") {
                            chooseFolder { url in
                                appSettings.transcriptionFolderURL = url
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .listRowBackground(Color.clear)

            Section("Privacy") {
                retentionControls(
                    title: "Auto-delete recordings",
                    help: "Removes audio files older than the selected age from the recordings folder. Transcripts and notes are kept.",
                    enabled: $settings.autoDeleteRecordingsEnabled,
                    days: $settings.autoDeleteRecordingsDays,
                    category: .recordings
                )

                Divider()

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

            Section("Call Detection") {
                Toggle("Enable call detection", isOn: $settings.callDetectionEnabled)

                if appSettings.callDetectionEnabled {
                    Toggle("Auto-start recording when call detected", isOn: $settings.autoRecordCalls)
                }
            }
            .listRowBackground(Color.clear)

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
                        Text("Looks up the matching calendar event when recording starts and pre-fills title, participants, and agenda context.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

            Section("Onboarding") {
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
            calendarStatus = EKEventStore.authorizationStatus(for: .event)
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

            HStack(spacing: 8) {
                Button("Run Cleanup Now") { pendingCleanup = category }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(runningCleanup != nil)

                if runningCleanup == category {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                if let message = cleanupMessage[category] {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
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
