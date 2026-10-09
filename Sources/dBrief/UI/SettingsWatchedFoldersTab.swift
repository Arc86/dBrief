import AppKit
import SwiftUI

struct SettingsWatchedFoldersTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(AppContext.self) private var context

    var body: some View {
        @Bindable var settings = appSettings
        SettingsPageScaffold(page: .watchedFolders) {
            SettingsCard(section: .automaticImport) {
                SettingsRow("Watch folders for new audio",
                            caption: "Files dropped in a folder are copied into dBrief and processed like a recording. The original stays where it is.") {
                    Toggle("Watch folders for new audio", isOn: $settings.watchedFoldersEnabled)
                        .onChange(of: appSettings.watchedFoldersEnabled) { _, enabled in
                            // Re-arm the poller when the feature is switched on; it
                            // self-parks when switched off (no idle CPU wakeups).
                            if enabled { context.watchedFolderService.start() }
                        }
                }
            }

            if appSettings.watchedFoldersEnabled {
                SettingsCard("Folders", description: "Only files added after a folder is watched are processed") {
                    if appSettings.watchedFolders.isEmpty {
                        SettingsRow("No folders yet", caption: "Add one to start watching for new audio.")
                    }
                    ForEach(appSettings.watchedFolders) { folder in
                        folderRow(folder)
                    }
                    SettingsRow("Add a folder") {
                        Button {
                            addFolder()
                        } label: {
                            Label("Add folder…", systemImage: "plus")
                        }
                        .buttonStyle(.settingsSecondary)
                    }
                }

                SettingsCard("Notifications") {
                    SettingsRow("Notify when a file is detected",
                                caption: "New files use your After recording defaults and are picked up once they finish copying.") {
                        Toggle("Notify when a file is detected", isOn: $settings.watchedFolderNotifyOnDetect)
                    }
                }
            }
        }
    }

    private func folderRow(_ folder: WatchedFolder) -> some View {
        @Bindable var settings = appSettings
        let name = URL(fileURLWithPath: folder.displayPath).lastPathComponent
        return SettingsRow(verbatim: name, caption: folder.displayPath, systemImage: "folder") {
            HStack(spacing: 8) {
                Toggle("Monitor \(name)", isOn: Binding(
                    get: { folder.isEnabled },
                    set: { newValue in
                        if let idx = settings.watchedFolders.firstIndex(where: { $0.id == folder.id }) {
                            settings.watchedFolders[idx].isEnabled = newValue
                        }
                    }
                ))
                Button {
                    removeFolder(folder)
                } label: {
                    Image(systemName: "xmark").frame(width: 12)
                }
                .buttonStyle(.settingsSecondary)
                .help("Stop watching this folder")
                .accessibilityLabel("Stop watching \(name)")
            }
        }
    }

    private func addFolder() {
        // The Settings window already owns the activation policy (SettingsView).
        NSApp.activate()

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose a folder to watch for new audio files"

        let response = panel.runModal()

        guard response == .OK, let url = panel.url, let folder = WatchedFolder.make(from: url) else { return }
        // Avoid duplicates by path.
        guard !appSettings.watchedFolders.contains(where: { $0.displayPath == folder.displayPath }) else { return }
        // Re-adding a previously removed folder should re-seed its existing files as "old".
        context.watchedFolderService.forget(folderPath: folder.displayPath)
        appSettings.watchedFolders.append(folder)
    }

    private func removeFolder(_ folder: WatchedFolder) {
        appSettings.watchedFolders.removeAll { $0.id == folder.id }
        context.watchedFolderService.forget(folderPath: folder.displayPath)
    }
}
