import AppKit
import SwiftUI

struct SettingsStorageTab: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(AppSettings.self) private var appSettings
    let editProfile: (UUID) -> Void

    // Retention / auto-delete UI state
    @State private var runningCleanup: RetentionCategory?
    @State private var cleanupMessage: [RetentionCategory: String] = [:]
    @State private var pendingCleanup: RetentionCategory?

    private let retentionDayOptions = [1, 7, 14, 30, 60, 90, 180, 365]

    var body: some View {
        @Bindable var settings = appSettings
        SettingsPageScaffold(page: .storage, notice: {
            SettingsProfileScopeView(fields: SettingsPage.storage.profileFields, editProfile: editProfile)
        }) {
            SettingsCard("Folders", section: .storageFolders) {
                folderRow(title: String(localized: "Recordings"), url: appSettings.recordingFolderURL) { url in
                    appSettings.recordingFolderURL = url
                }
                folderRow(title: String(localized: "Transcripts"), url: appSettings.transcriptionFolderURL) { url in
                    appSettings.transcriptionFolderURL = url
                }
            }

            SettingsCard("Auto-delete", description: "Runs at launch and then daily while dBrief is open, in these folders and every profile's folders",
                         section: .storageRetention) {
                retentionRows(
                    title: String(localized: "Delete old recordings"),
                    help: String(localized: "Audio dBrief recognises from its metadata. Transcripts, notes and unknown files are kept."),
                    enabled: $settings.autoDeleteRecordingsEnabled,
                    days: $settings.autoDeleteRecordingsDays,
                    category: .recordings
                )
                retentionRows(
                    title: String(localized: "Delete old transcripts"),
                    help: String(localized: "Transcripts and linked Markdown exports dBrief recognises. Audio and unknown files are kept."),
                    enabled: $settings.autoDeleteTranscriptsEnabled,
                    days: $settings.autoDeleteTranscriptsDays,
                    category: .transcripts
                )
                if appSettings.autoDeleteRecordingsEnabled || appSettings.autoDeleteTranscriptsEnabled {
                    SettingsRow(verbatim: String(localized: "Last clean-up"), caption: lastCleanupCaption)
                }
            }
        }
        .confirmationDialog(
            Text(verbatim: pendingCleanup.map {
                String(localized: "Delete \($0.displayName) older than \(retentionLabel(retentionDays(for: $0)))?")
            } ?? ""),
            isPresented: Binding(
                get: { pendingCleanup != nil },
                set: { if !$0 { pendingCleanup = nil } }
            ),
            presenting: pendingCleanup
        ) { category in
            Button("Delete", role: .destructive) { runCleanup(category) }
            Button("Cancel", role: .cancel) { pendingCleanup = nil }
        } message: { category in
            // Name the folders: profiles can save recordings outside the ones shown above.
            let folders = ListFormatter.localizedString(byJoining: appSettings.retentionFolders(for: category).map(\.lastPathComponent))
            Text(verbatim: String(localized: "This permanently deletes matching files in \(folders). This can't be undone."))
        }
    }

    private var lastCleanupCaption: String {
        guard let lastRun = appSettings.lastRetentionCleanupDate else { return String(localized: "Not run yet.") }
        let date = lastRun.formatted(date: .abbreviated, time: .shortened)
        let summary = RetentionCleanupSummary.display(appSettings.lastRetentionCleanupSummary)
        return summary.isEmpty ? date : "\(date) · \(summary)"
    }

    @ViewBuilder
    private func retentionRows(
        title: String,
        help: String,
        enabled: Binding<Bool>,
        days: Binding<Int>,
        category: RetentionCategory
    ) -> some View {
        SettingsRow(verbatim: title, caption: help) {
            HStack(spacing: 8) {
                if enabled.wrappedValue {
                    Picker("Delete after", selection: days) {
                        ForEach(retentionDayOptions, id: \.self) { value in
                            Text("After \(retentionLabel(value))").tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Toggle(title, isOn: enabled)
            }
        }
        if enabled.wrappedValue {
            SettingsRow(verbatim: String(localized: "Clean up now"), caption: cleanupMessage[category]) {
                HStack(spacing: 8) {
                    if runningCleanup == category { ProgressView().controlSize(.small) }
                    Button(category == .recordings ? "Delete old recordings…" : "Delete old transcripts…") {
                        pendingCleanup = category
                    }
                    .buttonStyle(.settingsDanger)
                    .disabled(runningCleanup != nil)
                }
            }
        }
    }

    private func folderRow(title: String, url: URL, onChoose: @escaping (URL) -> Void) -> some View {
        SettingsRow(verbatim: title, systemImage: "folder") {
            HStack(spacing: 8) {
                FolderPathControl(url: url)
                    .frame(maxWidth: 280, alignment: .trailing)
                Button("Choose…") { chooseFolder(completion: onChoose) }
                    .buttonStyle(.settingsSecondary)
            }
        }
    }

    private func retentionDays(for category: RetentionCategory) -> Int {
        switch category {
        case .recordings: appSettings.autoDeleteRecordingsDays
        case .transcripts: appSettings.autoDeleteTranscriptsDays
        }
    }

    private func retentionLabel(_ days: Int) -> String {
        switch days {
        case 1: String(localized: "1 day")
        case 7: String(localized: "1 week")
        case 14: String(localized: "2 weeks")
        case 365: String(localized: "1 year")
        default: String(localized: "\(days) days")
        }
    }

    private func runCleanup(_ category: RetentionCategory) {
        pendingCleanup = nil
        guard runningCleanup == nil else { return }
        runningCleanup = category

        let days = retentionDays(for: category)
        let folders = appSettings.retentionFolders(for: category)

        Task {
            do {
                let result = try await recordingManager.runRetentionCleanup(category: category, days: days, folders: folders)
                cleanupMessage[category] = result.summary
                appSettings.lastRetentionCleanupDate = Date()
                appSettings.lastRetentionCleanupSummary = RetentionCleanupSummary.stored(result)
            } catch let blocked as RecordingBlockedError {
                cleanupMessage[category] = blocked.localizedDescription
            } catch {
                cleanupMessage[category] = recordingManager.hasUnreadableRecords
                    ? RecordingBlock.unreadableRecords.message
                    : String(localized: "Cleanup could not finish safely. Check storage before retrying.")
            }
            runningCleanup = nil
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
