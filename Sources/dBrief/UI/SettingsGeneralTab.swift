import SwiftUI

struct SettingsGeneralTab: View {
    @Environment(AppSettings.self) private var appSettings
    @State private var inputDevices: [AudioInputDevice] = []

    var body: some View {
        @Bindable var settings = appSettings
        Form {
            Section("Appearance") {
                Toggle("Show dock icon", isOn: $settings.showDockIcon)
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

            Section("Audio Quality") {
                LabeledContent("Sample rate:") {
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
                LabeledContent("Bit rate (AAC):") {
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
                LabeledContent("Refresh device list") {
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
