import AppKit
import SwiftUI

struct SettingsRecordingTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.settingsSearchRequest) private var searchRequest
    private var searchAdvanced: Bool { searchRequest?.section.isAdvanced ?? false }
    @State private var inputDevices: [AudioInputDevice] = []

    var body: some View {
        @Bindable var settings = appSettings
        Form {
            Section("Shortcut", settingsSearch: .recordingShortcut) {
                LabeledContent("Start or stop recording") {
                    ShortcutRecorderView(hotkey: $settings.recordHotkey)
                }
                Text("Global shortcut to toggle recording from anywhere. Defaults to ⌃⌥⌘R.")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)

            Section("Audio Input", settingsSearch: .audioInput) {
                let selectedUID = settings.audioInputDeviceUID
                let knownUIDs = Set(inputDevices.map { $0.uid })
                let isMissingSelection = !selectedUID.isEmpty && !knownUIDs.contains(selectedUID)

                LabeledContent("Input device") {
                    HStack(spacing: 6) {
                        Picker("Input device", selection: $settings.audioInputDeviceUID) {
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
                        .fixedSize()
                        Button {
                            inputDevices = AudioInputDeviceManager.availableInputDevices()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh device list")
                        .accessibilityLabel("Refresh device list")
                    }
                }
            }
            .listRowBackground(Color.clear)

            Section("Echo Cancellation", settingsSearch: .echoCancellation) {
                Toggle("Reduce microphone echo", isOn: $settings.acousticEchoCancellation)
                Text("Reduces meeting audio picked up by your microphone when using speakers. Automatically skipped with headphones.")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)

            Section("Recording Indicators", settingsSearch: .recordingIndicators) {
                Toggle("Show floating recording window", isOn: $settings.showMiniRecordingView)
                Text("The small floating window that shows recording status and audio levels while you record.")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show recording duration in the menu bar", isOn: $settings.showMenuBarRecordingDuration)
                Text("When off, the menu bar shows only the red record indicator while recording — the elapsed time is hidden.")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)

            if appSettings.powerUserMode || searchAdvanced {
                Section("Audio Quality", settingsSearch: .audioQuality) {
                    LabeledContent("Capture") {
                        Text("CAF/LPCM per track (system + mic separate)")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    LabeledContent("Master output") {
                        Text("M4A/AAC 96 kbps · 48 kHz stereo")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    LabeledContent("Post-processing") {
                        Text("Mic: 80Hz HPF, sidechain duck vs. system, -16 LUFS loudnorm\nSystem: 40Hz HPF, 12kHz LPF\nMix: amix normalize=0")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .settingsFormStyle()
        .onAppear {
            inputDevices = AudioInputDeviceManager.availableInputDevices()
        }
    }
}
