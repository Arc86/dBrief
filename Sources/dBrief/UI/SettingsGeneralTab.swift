import AppKit
import EventKit
import SwiftUI

struct SettingsGeneralTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(MicrosoftAuthService.self) private var microsoftAuthService

    @State private var outlookSignInError: String?

    var body: some View {
        let calendarGranted = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        @Bindable var settings = appSettings
        Form {
            Section("Appearance") {
                Toggle("Show dock icon", isOn: $settings.showDockIcon)
                Toggle("Power user mode", isOn: $settings.powerUserMode)
                if appSettings.powerUserMode {
                    Text("Shows advanced settings and features across all tabs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

            Section("Call Detection") {
                Toggle("Enable call detection", isOn: $settings.callDetectionEnabled)

                if appSettings.callDetectionEnabled {
                    Toggle("Auto-start recording when call detected", isOn: $settings.autoRecordCalls)
                }
            }
            .listRowBackground(Color.clear)

            Section("Calendar") {
                Picker("Source", selection: $settings.calendarSource) {
                    Text("Off").tag(CalendarSource.disabled)
                    Text("iCal").tag(CalendarSource.iCal)
                    Text("Outlook (Microsoft)").tag(CalendarSource.outlook)
                }

                switch settings.calendarSource {
                case .iCal:
                    if !calendarGranted {
                        Text("Grant Calendar access in the Permissions tab to enable this.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Looks up the matching calendar event when recording starts and pre-fills title, participants, and agenda context.")
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

            Section("Permissions") {
                LabeledContent("Microphone:") {
                    HStack {
                        Image(systemName: recordingManager.hasMicrophonePermission ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(recordingManager.hasMicrophonePermission ? .green : .red)
                        Text(recordingManager.hasMicrophonePermission ? "Granted" : "Not granted")
                            .foregroundStyle(.secondary)
                        if !recordingManager.hasMicrophonePermission {
                            Button("Request") {
                                Task { await recordingManager.checkPermissions() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                LabeledContent("Screen Recording:") {
                    HStack {
                        Image(systemName: recordingManager.hasSystemAudioPermission ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(recordingManager.hasSystemAudioPermission ? .green : .red)
                        Text(recordingManager.hasSystemAudioPermission ? "Granted" : "Not granted")
                            .foregroundStyle(.secondary)
                        if !recordingManager.hasSystemAudioPermission {
                            Button("Open Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .listRowBackground(Color.clear)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .toggleStyle(.smallSwitch)
        .padding(.top, -20)
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
