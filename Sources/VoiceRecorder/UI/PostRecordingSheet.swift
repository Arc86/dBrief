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

            if appSettings.defaultTranscriptionEndpoint == nil && transcribe {
                Text("No transcription endpoint configured. Add one in Settings.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if appSettings.obsidianEnabled, let recording = appState.currentRecording {
                Divider()

                ObsidianFolderPicker(
                    title: "Obsidian output folder",
                    currentRelativePath: recording.obsidianFolderRelativePath ?? appSettings.obsidianDefaultFolderRelativePath
                ) { relativePath in
                    recording.obsidianFolderRelativePath = relativePath
                    appSettings.obsidianDefaultFolderRelativePath = relativePath
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
                .disabled(transcribe && appSettings.defaultTranscriptionEndpoint == nil)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            transcribe = appSettings.autoTranscribe
            summary = appSettings.autoSummary
            actionItems = appSettings.autoActionItems
            tags = appSettings.autoTags
        }
    }
}
