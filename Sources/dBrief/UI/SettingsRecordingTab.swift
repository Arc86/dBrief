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

            if appSettings.powerUserMode {
                Section("Audio Quality") {
                    LabeledContent("Recording profile:") {
                        Text("Native rate FLAC (48 kHz stereo)")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    LabeledContent("Post-process:") {
                        Text("80Hz high-pass, -14 LUFS to -1dBTP, AEC/echo cancel")
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
}
