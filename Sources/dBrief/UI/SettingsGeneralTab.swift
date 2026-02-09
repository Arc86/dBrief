import SwiftUI

struct SettingsGeneralTab: View {
    @Environment(AppSettings.self) private var appSettings
    @State private var inputDevices: [AudioInputDevice] = []

    var body: some View {
        @Bindable var settings = appSettings

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Folders
                SettingsSection(title: "Folders") {
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
                        }
                    }

                    Divider()

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
                        }
                    }
                }

                // Audio Quality
                SettingsSection(title: "Audio Quality") {
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
                        .fixedSize()
                        .frame(width: 160, alignment: .trailing)
                    }

                    Divider()

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
                        .fixedSize()
                        .frame(width: 160, alignment: .trailing)
                    }
                }

                // Audio Input
                SettingsSection(title: "Audio Input") {
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
                        .fixedSize()
                        .frame(width: 220, alignment: .trailing)
                    }

                    Divider()

                    HStack {
                        Text("Refresh device list")
                        Spacer()
                        Button("Refresh") {
                            inputDevices = AudioInputDeviceManager.availableInputDevices()
                        }
                    }
                }

                // Call Detection
                SettingsSection(title: "Call Detection") {
                    Toggle("Enable call detection", isOn: $settings.callDetectionEnabled)

                    if appSettings.callDetectionEnabled {
                        Divider()
                        Toggle("Auto-start recording when call detected", isOn: $settings.autoRecordCalls)
                        Divider()
                        ForEach(Array(CallDetectionService.knownCallApps.enumerated()), id: \.element.bundleId) { index, app in
                            let isDisabled = appSettings.disabledCallApps.contains(app.bundleId)
                            Toggle(app.name, isOn: Binding(
                                get: { !isDisabled },
                                set: { enabled in
                                    if enabled {
                                        appSettings.disabledCallApps.remove(app.bundleId)
                                    } else {
                                        appSettings.disabledCallApps.insert(app.bundleId)
                                    }
                                }
                            ))
                            if index < CallDetectionService.knownCallApps.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding()
        }
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
