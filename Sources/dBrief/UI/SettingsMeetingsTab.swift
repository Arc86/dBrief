import AppKit
import SwiftUI

/// Meetings: call detection and calendar matching — the things that tell dBrief
/// which meeting a recording belongs to.
struct SettingsMeetingsTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.settingsSearchRequest) private var searchRequest

    var body: some View {
        @Bindable var settings = appSettings
        Form {
            Section("Call Detection", settingsSearch: .callDetection) {
                Toggle("Enable call detection", isOn: $settings.callDetectionEnabled)

                if appSettings.callDetectionEnabled {
                    Toggle("Auto-start recording when call detected", isOn: $settings.autoRecordCalls)

                    if !appSettings.autoRecordCalls {
                        Picker("Auto-dismiss prompt", selection: $settings.autoDismissCallPromptSeconds) {
                            Text("Never").tag(0)
                            Text("After 10 seconds").tag(10)
                            Text("After 15 seconds").tag(15)
                            Text("After 30 seconds").tag(30)
                            Text("After 60 seconds").tag(60)
                        }
                        Text("Automatically dismiss the “call detected” prompt if you don't respond. Clicking the prompt cancels the timer.")
                            .uiFont(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Picker("When a call ends", selection: $settings.stopRecordingOnCallEnd) {
                        ForEach(AppSettings.CallEndAction.allCases, id: \.self) { action in
                            Text(action.displayName).tag(action)
                        }
                    }
                    if appSettings.stopRecordingOnCallEnd != .off {
                        Picker("Apply to", selection: $settings.callEndScope) {
                            ForEach(AppSettings.CallEndScope.allCases, id: \.self) { scope in
                                Text(scope.displayName).tag(scope)
                            }
                        }
                    }
                    Text("Detects when the meeting app stops using the microphone (Teams, Zoom, Slack, Meet). On older macOS, only works when the meeting app fully quits.")
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.clear)

            if appSettings.callDetectionEnabled || searchRequest?.section == .callPlatforms {
                Section("Call Platforms", settingsSearch: .callPlatforms) {
                    if !appSettings.callDetectionEnabled {
                        Text("Call detection is off. These platform choices will apply when you enable it.")
                            .uiFont(.caption).foregroundStyle(.secondary)
                    }
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
                            HStack(spacing: 10) {
                                callPlatformIcon(for: app)
                                    .frame(width: 28, height: 28)

                                Text(app.name)
                            }
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }

            SettingsCalendarSection()
        }
        .settingsFormStyle()
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
                    .frame(width: 24, height: 24)
                    .scaleEffect(1.2)
            } else if let brand = app.brandIcon {
                brand.text(size: 16)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: app.sfSymbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func glassIconTile<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
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
