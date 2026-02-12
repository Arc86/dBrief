import SwiftUI

struct PostRecordingSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager

    @State private var transcribe = true
    @State private var summary = true
    @State private var actionItems = true
    @State private var tags = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recording Complete")
                .font(.headline)
            Text("Profile: \(appSettings.activeProfile.name)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let recording = appState.currentRecording {
                HStack {
                    Label(recording.formattedDuration, systemImage: "clock")
                    Spacer()
                    Label(recording.formattedFileSize, systemImage: "doc")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            Text("Post-Processing Options")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Toggle("Transcribe audio", isOn: $transcribe)
            Toggle("Generate summary", isOn: $summary)
                .disabled(!transcribe)
            Toggle("Extract action items", isOn: $actionItems)
                .disabled(!transcribe)
            Toggle("Analyze tags & sentiment", isOn: $tags)
                .disabled(!transcribe)

            if !transcribe {
                Text("Transcription is required for AI analysis.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if appSettings.effectiveTranscriptionEngine == .remoteEndpoint,
               appSettings.effectiveDefaultTranscriptionEndpoint == nil,
               transcribe {
                Text("No transcription endpoint configured. Add one in Settings.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if appSettings.obsidianEnabled, let recording = appState.currentRecording {
                Divider()

                ObsidianFolderPicker(
                    title: "Obsidian output folder",
                    currentRelativePath: recording.obsidianFolderRelativePath ?? appSettings.effectiveObsidianDefaultFolderRelativePath
                ) { relativePath in
                    recording.obsidianFolderRelativePath = relativePath
                    if appSettings.activeProfile.isProtectedDefault {
                        appSettings.obsidianDefaultFolderRelativePath = relativePath
                    }
                }
            }

            if !enabledDestinationNames.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Auto-send destinations")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(enabledDestinationNames.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if appSettings.integrations.webhook.enabled {
                        Text("Webhook fields: \(webhookFieldsDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            HStack {
                Button("Skip") {
                    recordingManager.skipProcessing()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Process") {
                    Task {
                        await recordingManager.processRecording(
                            transcribe: transcribe,
                            summary: summary && transcribe,
                            actionItems: actionItems && transcribe,
                            tags: tags && transcribe
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    transcribe
                        && appSettings.effectiveTranscriptionEngine == .remoteEndpoint
                        && appSettings.effectiveDefaultTranscriptionEndpoint == nil
                )
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            transcribe = appSettings.effectiveAutoTranscribe
            summary = appSettings.effectiveAutoSummary
            actionItems = appSettings.effectiveAutoActionItems
            tags = appSettings.effectiveAutoTags
        }
    }

    private var enabledDestinationNames: [String] {
        var values: [String] = []
        let i = appSettings.integrations
        if i.appleNotes.enabled { values.append(IntegrationDestination.appleNotes.displayName) }
        if i.appleReminders.enabled { values.append(IntegrationDestination.appleReminders.displayName) }
        if i.notion.enabled { values.append(IntegrationDestination.notion.displayName) }
        if i.evernote.enabled { values.append(IntegrationDestination.evernote.displayName) }
        if i.googleKeep.enabled { values.append(IntegrationDestination.googleKeep.displayName) }
        if i.oneNote.enabled { values.append(IntegrationDestination.oneNote.displayName) }
        if i.webhook.enabled { values.append(IntegrationDestination.webhook.displayName) }
        return values
    }

    private var webhookFieldsDescription: String {
        let labels = appSettings.integrations.webhook.fields.map(\.displayName)
        return labels.isEmpty ? "None selected" : labels.joined(separator: ", ")
    }
}
