import AppKit
import SwiftUI

struct SettingsRecordingTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.settingsSearchRevealAdvanced) private var searchAdvanced
    @Environment(\.settingsSearchRequest) private var searchRequest
    @State private var inputDevices: [AudioInputDevice] = []

    var body: some View {
        @Bindable var settings = appSettings
        Form {
            Section("Shortcut", settingsSearch: .recordingShortcut) {
                LabeledContent("Start/stop recording:") {
                    ShortcutRecorderView(hotkey: $settings.recordHotkey)
                }
                Text("Global shortcut to toggle recording from anywhere. Defaults to ⌃⌥⌘R.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)

            Section("Call Detection", settingsSearch: .callDetection) {
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

            if appSettings.callDetectionEnabled || searchRequest?.section == .callPlatforms {
                Section("Call Platforms", settingsSearch: .callPlatforms) {
                    if !appSettings.callDetectionEnabled {
                        Text("Call detection is off. These platform choices will apply when you enable it.")
                            .font(.caption).foregroundStyle(.secondary)
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

            Section("Audio Input", settingsSearch: .audioInput) {
                let selectedUID = settings.audioInputDeviceUID
                let knownUIDs = Set(inputDevices.map { $0.uid })
                let isMissingSelection = !selectedUID.isEmpty && !knownUIDs.contains(selectedUID)

                LabeledContent("Input device:") {
                    Picker("", selection: $settings.audioInputDeviceUID) {
                        Text("System Default").tag("")
                        ForEach(inputDevices) { device in
                            Text(device.displayName).tag(device.uid)
                        }
                        if isMissingSelection {
                            Text("Unavailable device (reconnect)").tag(selectedUID)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220, alignment: .trailing)
                }
                LabeledContent("") {
                    Button("Refresh device list") {
                        inputDevices = AudioInputDeviceManager.availableInputDevices()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .listRowBackground(Color.clear)

            Section("Echo Cancellation", settingsSearch: .echoCancellation) {
                Toggle("Reduce microphone echo", isOn: $settings.acousticEchoCancellation)
                Text("Reduces meeting audio picked up by your microphone when using speakers. Automatically skipped with headphones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)

            Section("Recording Indicators", settingsSearch: .recordingIndicators) {
                Toggle("Show floating recording window", isOn: $settings.showMiniRecordingView)
                Text("The small floating window that shows recording status and audio levels while you record.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show recording duration in the menu bar", isOn: $settings.showMenuBarRecordingDuration)
                Text("When off, the menu bar shows only the red record indicator while recording — the elapsed time is hidden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)

            if appSettings.powerUserMode || searchAdvanced {
                Section("Audio Quality", settingsSearch: .audioQuality) {
                    LabeledContent("Capture:") {
                        Text("CAF/LPCM per track (system + mic separate)")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    LabeledContent("Master output:") {
                        Text("M4A/AAC 96 kbps · 48 kHz stereo")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    LabeledContent("Post-process:") {
                        Text("Mic: 80Hz HPF, sidechain duck vs. system, -16 LUFS loudnorm\nSystem: 40Hz HPF, 12kHz LPF\nMix: amix normalize=0")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .toggleStyle(.smallSwitch)
        .padding(.top, -20)
        .onAppear {
            inputDevices = AudioInputDeviceManager.availableInputDevices()
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
