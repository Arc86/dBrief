import SwiftUI

struct SettingsGeneralTab: View {
    @Environment(AppSettings.self) private var appSettings
    @State private var inputDevices: [AudioInputDevice] = []

    var body: some View {
        @Bindable var settings = appSettings
        Form {
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

            Section("Audio Quality") {
                HStack {
                    Text("Sample rate:")
                    Spacer()
                    Picker("", selection: $settings.audioSampleRate) {
                        Text("16 kHz (speech)").tag(16000)
                        Text("22 kHz").tag(22050)
                        Text("44.1 kHz (CD)").tag(44100)
                        Text("48 kHz (studio)").tag(48000)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160, alignment: .trailing)
                }
                HStack {
                    Text("Bit rate (AAC):")
                    Spacer()
                    Picker("", selection: $settings.audioBitRate) {
                        Text("64 kbps").tag(64000)
                        Text("96 kbps").tag(96000)
                        Text("128 kbps").tag(128000)
                        Text("192 kbps").tag(192000)
                        Text("256 kbps").tag(256000)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160, alignment: .trailing)
                }
            }
            .listRowBackground(Color.clear)

            Section("Audio Input") {
                let selectedUID = settings.audioInputDeviceUID
                let knownUIDs = Set(inputDevices.map { $0.uid })
                let isMissingSelection = !selectedUID.isEmpty && !knownUIDs.contains(selectedUID)

                HStack {
                    Text("Input device:")
                    Spacer()
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
                HStack {
                    Text("Refresh device list")
                    Spacer()
                    Button("Refresh") {
                        inputDevices = AudioInputDeviceManager.availableInputDevices()
                    }
                    .buttonStyle(.bordered)
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

            if appSettings.callDetectionEnabled {
                Section("Call Platforms") {
                    ForEach(CallDetectionService.knownCallApps, id: \.bundleId) { app in
                        let isEnabled = !appSettings.disabledCallApps.contains(app.bundleId)
                        Toggle(
                            app.name,
                            isOn: Binding(
                                get: { isEnabled },
                                set: { enabled in
                                    if enabled {
                                        appSettings.disabledCallApps.remove(app.bundleId)
                                    } else {
                                        appSettings.disabledCallApps.insert(app.bundleId)
                                    }
                                }
                            )
                        )
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .toggleStyle(.switch)
        .controlSize(.regular)
        .padding(.top, -20)
        .onAppear {
            inputDevices = AudioInputDeviceManager.availableInputDevices()
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
}
