import AppKit
import SwiftUI

struct SettingsStorageTab: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(AppSettings.self) private var appSettings

    // Retention / auto-delete UI state
    @State private var runningCleanup: RetentionCategory?
    @State private var cleanupMessage: [RetentionCategory: String] = [:]
    @State private var pendingCleanup: RetentionCategory?

    private let retentionDayOptions = [1, 7, 14, 30, 60, 90, 180, 365]

    var body: some View {
        @Bindable var settings = appSettings
        Form {
            Section("Storage & privacy", settingsSearch: .storageFolders) {
                folderRow(title: "Recordings:", url: appSettings.recordingFolderURL) { url in
                    appSettings.recordingFolderURL = url
                }

                folderRow(title: "Transcriptions:", url: appSettings.transcriptionFolderURL) { url in
                    appSettings.transcriptionFolderURL = url
                }

                retentionControls(
                    title: "Auto-delete recordings",
                    help: "Removes recordings identified by dBrief metadata that are older than the selected age. Unrecognized files, transcripts, and notes are kept.",
                    enabled: $settings.autoDeleteRecordingsEnabled,
                    days: $settings.autoDeleteRecordingsDays,
                    category: .recordings
                )

                retentionControls(
                    title: "Auto-delete transcripts",
                    help: "Removes transcript files and linked Markdown exports identified by dBrief metadata that are older than the selected age. Unrecognized files and audio recordings are kept.",
                    enabled: $settings.autoDeleteTranscriptsEnabled,
                    days: $settings.autoDeleteTranscriptsDays,
                    category: .transcripts
                )

                if appSettings.autoDeleteRecordingsEnabled || appSettings.autoDeleteTranscriptsEnabled {
                    Text("Cleanup runs at launch and then daily while dBrief stays open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let lastRun = appSettings.lastRetentionCleanupDate {
                        LabeledContent("Last cleanup") {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(lastRun.formatted(date: .abbreviated, time: .shortened))
                                if !appSettings.lastRetentionCleanupSummary.isEmpty {
                                    Text(appSettings.lastRetentionCleanupSummary)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption)
                        }
                    } else {
                        LabeledContent("Last cleanup") {
                            Text("Not run yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listRowBackground(Color.clear)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .toggleStyle(.smallSwitch)
        .padding(.top, -20)
        .confirmationDialog(
            "Delete \(pendingCleanup?.displayName ?? "files") older than the selected age?",
            isPresented: Binding(
                get: { pendingCleanup != nil },
                set: { if !$0 { pendingCleanup = nil } }
            ),
            presenting: pendingCleanup
        ) { category in
            Button("Delete", role: .destructive) { runCleanup(category) }
            Button("Cancel", role: .cancel) { pendingCleanup = nil }
        } message: { _ in
            Text("This permanently deletes matching files. This can't be undone.")
        }
    }

    @ViewBuilder
    private func retentionControls(
        title: String,
        help: String,
        enabled: Binding<Bool>,
        days: Binding<Int>,
        category: RetentionCategory
    ) -> some View {
        Toggle(title, isOn: enabled)

        if enabled.wrappedValue {
            Picker("Delete after", selection: days) {
                ForEach(retentionDayOptions, id: \.self) { value in
                    Text(retentionLabel(value)).tag(value)
                }
            }
            .pickerStyle(.menu)

            LabeledContent("Clean up now") {
                HStack(spacing: 8) {
                    if let message = cleanupMessage[category] {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if runningCleanup == category {
                        ProgressView().controlSize(.small)
                    }

                    Button(category == .recordings ? "Delete old recordings…" : "Delete old transcripts…") { pendingCleanup = category }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(runningCleanup != nil)
                }
            }

            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func folderRow(
        title: String,
        url: URL,
        onChoose: @escaping (URL) -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                FolderPathControl(url: url)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Button("Choose...") {
                    chooseFolder(completion: onChoose)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func retentionLabel(_ days: Int) -> String {
        switch days {
        case 1: "1 day"
        case 7: "1 week"
        case 14: "2 weeks"
        case 365: "1 year"
        default: "\(days) days"
        }
    }

    private func runCleanup(_ category: RetentionCategory) {
        pendingCleanup = nil
        guard runningCleanup == nil else { return }
        runningCleanup = category

        let days: Int
        let folders: [URL]
        switch category {
        case .recordings:
            days = appSettings.autoDeleteRecordingsDays
            folders = [appSettings.effectiveRecordingFolderURL]
        case .transcripts:
            days = appSettings.autoDeleteTranscriptsDays
            folders = [appSettings.effectiveRecordingFolderURL, appSettings.effectiveTranscriptionFolderURL]
        }

        Task {
            do {
                let result = try await recordingManager.runRetentionCleanup(category: category, days: days, folders: folders)
                cleanupMessage[category] = result.summary
                appSettings.lastRetentionCleanupDate = Date()
                appSettings.lastRetentionCleanupSummary = result.summary
            } catch {
                cleanupMessage[category] = "Cleanup could not finish safely. Wait for processing to finish and check storage before retrying."
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
