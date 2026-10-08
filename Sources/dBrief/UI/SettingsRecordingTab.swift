import AppKit
import SwiftUI

struct SettingsRecordingTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.viewerPalette) private var palette
    @State private var inputDevices: [AudioInputDevice] = []

    var body: some View {
        @Bindable var settings = appSettings
        let selectedUID = settings.audioInputDeviceUID
        let isMissingSelection = !selectedUID.isEmpty && !Set(inputDevices.map(\.uid)).contains(selectedUID)

        SettingsPageScaffold(page: .recording) {
            SettingsCard("Microphone", section: .audioInput) {
                SettingsRow("Input device", caption: "Follows the macOS default unless you pick one.") {
                    HStack(spacing: 6) {
                        Picker("Input device", selection: $settings.audioInputDeviceUID) {
                            Text("System default").tag("")
                            ForEach(inputDevices) { device in
                                Text(device.displayName).tag(device.uid)
                            }
                            if isMissingSelection {
                                Text("Unavailable device (reconnect)").tag(selectedUID)
                            }
                        }
                        .pickerStyle(.menu)
                        Button {
                            inputDevices = AudioInputDeviceManager.availableInputDevices()
                        } label: {
                            Image(systemName: "arrow.clockwise").frame(width: 14)
                        }
                        .buttonStyle(.settingsSecondary)
                        .help("Refresh device list")
                        .accessibilityLabel("Refresh device list")
                    }
                }
                SettingsRow("Reduce microphone echo",
                            caption: "Removes meeting audio your microphone picks up from the speakers. Skipped automatically with headphones.") {
                    Toggle("Reduce microphone echo", isOn: $settings.acousticEchoCancellation)
                }
                .id(SettingsSectionID.echoCancellation)
            }

            SettingsCard("Shortcut", section: .recordingShortcut) {
                SettingsRow("Start or stop recording", caption: "Works from any app. Defaults to ⌃⌥⌘R.") {
                    ShortcutRecorderView(hotkey: $settings.recordHotkey)
                }
            }

            SettingsCard("While recording", section: .recordingIndicators) {
                SettingsRow("Floating recording window", caption: "Shows recording status and audio levels.") {
                    Toggle("Floating recording window", isOn: $settings.showMiniRecordingView)
                }
                SettingsRow("Duration in the menu bar", caption: "Off shows only the red record dot.") {
                    Toggle("Duration in the menu bar", isOn: $settings.showMenuBarRecordingDuration)
                }
            }

            SettingsAdvancedCard(page: .recording, summary: "Audio quality", sections: [.audioQuality]) {
                SettingsCard("Audio quality", section: .audioQuality) {
                    qualityRow("Capture", "CAF/LPCM per track (system + mic separate)")
                    qualityRow("Master output", "M4A/AAC 96 kbps · 48 kHz stereo")
                    qualityRow("Post-processing",
                               "Mic: 80Hz HPF, sidechain duck vs. system, -16 LUFS loudnorm\nSystem: 40Hz HPF, 12kHz LPF\nMix: amix normalize=0")
                }
            }
        }
        .onAppear {
            inputDevices = AudioInputDeviceManager.availableInputDevices()
        }
    }

    private func qualityRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        SettingsRow(label) {
            Text(value)
                .uiFont(.system(size: 11.5))
                .foregroundStyle(palette.secondary.color)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
