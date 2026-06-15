import AppKit
import SwiftUI

struct SettingsWatchedFoldersTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(AppContext.self) private var context

    var body: some View {
        @Bindable var settings = appSettings
        Form {
            Section("Watched Folders") {
                Toggle("Monitor folders for new audio files", isOn: $settings.watchedFoldersEnabled)
                Text("Drop an audio file into a watched folder and dBrief transcribes, analyzes, and exports it automatically — no recording needed. Your original file stays where it is; a copy is imported into your recordings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)

            if appSettings.watchedFoldersEnabled {
                Section("Folders") {
                    if appSettings.watchedFolders.isEmpty {
                        Text("No folders yet. Add one to start watching for dropped-in audio.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appSettings.watchedFolders) { folder in
                            folderRow(folder)
                        }
                    }

                    Button {
                        addFolder()
                    } label: {
                        Label("Add Folder…", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }
                .listRowBackground(Color.clear)

                Section("Options") {
                    Toggle("Notify when a new file is detected", isOn: $settings.watchedFolderNotifyOnDetect)
                    Text("New files use your global processing preferences (Settings → AI & Models). Only files added **after** a folder is watched are processed — existing files are left alone. Files are picked up once they finish copying.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func folderRow(_ folder: WatchedFolder) -> some View {
        @Bindable var settings = appSettings
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { folder.isEnabled },
                set: { newValue in
                    if let idx = settings.watchedFolders.firstIndex(where: { $0.id == folder.id }) {
                        settings.watchedFolders[idx].isEnabled = newValue
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: folder.displayPath).lastPathComponent)
                    .font(.callout)
                Text(folder.displayPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                removeFolder(folder)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Stop watching this folder")
        }
    }

    private func addFolder() {
        if !appSettings.showDockIcon { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose a folder to watch for new audio files"

        let response = panel.runModal()
        if !appSettings.showDockIcon { NSApp.setActivationPolicy(.accessory) }

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
