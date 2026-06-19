import SwiftUI

struct SettingsRecordingTab: View {
    @Environment(AppSettings.self) private var appSettings
    @State private var inputDevices: [AudioInputDevice] = []

    var body: some View {
        @Bindable var settings = appSettings
        Form {
            Section("Audio Input") {
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

            Section("Echo Cancellation") {
                Toggle("Remove meeting audio from microphone", isOn: $settings.acousticEchoCancellation)
                Text("Recommended when using laptop speakers. Uses the captured system audio as a reference to suppress speaker bleed in the mic during mixing. Falls back to real-time voice processing when recording mic only. Automatically skipped when you're on headphones or earphones (no speaker bleed to cancel), so output volume stays at full level.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)

            Section("Recording Indicators") {
                Toggle("Show floating Mini Recording view", isOn: $settings.showMiniRecordingView)
                Text("The small floating window that shows recording status and audio levels while you record.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show recording duration in the menu bar", isOn: $settings.showMenuBarRecordingDuration)
                Text("When off, the menu bar shows only the red record indicator while recording — the elapsed time is hidden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)

            if appSettings.powerUserMode {
                Section("Audio Quality") {
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
        .scrollBounceBehavior(.basedOnSize)
        .onAppear {
            inputDevices = AudioInputDeviceManager.availableInputDevices()
        }
    }
}
