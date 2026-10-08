import AppKit
import SwiftUI

/// Meetings: call detection and calendar matching — the things that tell dBrief
/// which meeting a recording belongs to.
struct SettingsMeetingsTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.settingsSearchRequest) private var searchRequest
    @Environment(\.viewerPalette) private var palette
    let editProfile: (UUID) -> Void

    var body: some View {
        @Bindable var settings = appSettings
        SettingsPageScaffold(page: .meetings, notice: {
            SettingsProfileScopeView(fields: SettingsPage.meetings.profileFields, editProfile: editProfile)
        }) {
            SettingsCard("Call detection", description: "Zoom, Teams, Meet and others", section: .callDetection) {
                SettingsRow("Notice when a call starts") {
                    Toggle("Notice when a call starts", isOn: $settings.callDetectionEnabled)
                }
                if appSettings.callDetectionEnabled {
                    SettingsRow("When a call starts") {
                        Picker("When a call starts", selection: $settings.autoRecordCalls) {
                            Text("Ask me").tag(false)
                            Text("Record automatically").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    if !appSettings.autoRecordCalls {
                        SettingsRow("Dismiss the prompt after", caption: "Clicking the prompt cancels the timer.") {
                            Picker("Dismiss the prompt after", selection: $settings.autoDismissCallPromptSeconds) {
                                Text("Never").tag(0)
                                Text("10 seconds").tag(10)
                                Text("15 seconds").tag(15)
                                Text("30 seconds").tag(30)
                                Text("60 seconds").tag(60)
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    SettingsRow("When a call ends",
                                caption: "Noticed when the meeting app stops using the microphone. On older macOS, only when it quits.") {
                        Picker("When a call ends", selection: $settings.stopRecordingOnCallEnd) {
                            ForEach(AppSettings.CallEndAction.allCases, id: \.self) { action in
                                Text(action.displayName).tag(action)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    if appSettings.stopRecordingOnCallEnd != .off {
                        SettingsRow("Apply to") {
                            Picker("Apply to", selection: $settings.callEndScope) {
                                ForEach(AppSettings.CallEndScope.allCases, id: \.self) { scope in
                                    Text(scope.displayName).tag(scope)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                }
            }

            if appSettings.callDetectionEnabled || searchRequest?.section == .callPlatforms {
                SettingsCard("Apps to watch", section: .callPlatforms) {
                    if !appSettings.callDetectionEnabled {
                        SettingsRow("Call detection is off", caption: "These choices apply when you turn it on.")
                    }
                    SettingsStackedRow {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 8)], spacing: 8) {
                            ForEach(CallDetectionService.knownCallApps, id: \.bundleId) { app in
                                appTile(app)
                            }
                        }
                    }
                }
            }

            SettingsCalendarSection()
        }
    }

    private func appTile(_ app: CallDetectionService.CallApp) -> some View {
        let isEnabled = Binding(
            get: { !appSettings.disabledCallApps.contains(app.bundleId) },
            set: { enabled in
                if enabled {
                    appSettings.disabledCallApps.remove(app.bundleId)
                } else {
                    appSettings.disabledCallApps.insert(app.bundleId)
                }
            }
        )
        return HStack(spacing: 9) {
            appIcon(app)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(app.name)
                .uiFont(.system(size: 12.5, weight: .medium))
                .foregroundStyle(palette.heading.color)
                .lineLimit(1)
            Spacer(minLength: 4)
            Toggle(app.name, isOn: isEnabled).labelsHidden()
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(palette.canvas.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(palette.divider.color, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func appIcon(_ app: CallDetectionService.CallApp) -> some View {
        if let customIcon = callPlatformIconImage(for: app) {
            Image(nsImage: customIcon).resizable().scaledToFit()
        } else if let brand = app.brandIcon {
            brand.text(size: 14).foregroundStyle(palette.secondary.color)
        } else {
            Image(systemName: app.sfSymbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.secondary.color)
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
}
