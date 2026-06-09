import SwiftUI

struct PostRecordingSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager

    @State private var transcribe = true
    @State private var summary = true
    @State private var actionItems = true
    @State private var tags = true
    @State private var meetingTitle = ""
    @State private var participantsText = ""
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

            LabeledContent("Meeting title:") {
                TextField("meeting", text: $meetingTitle)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }

            Text("Used for file naming (`YYYY-MM-DD_HHMM_[meeting-title].m4a`).")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if appSettings.diarizationEnabled {
                LabeledContent("Participants:") {
                    TextField("Alice, Bob, Charlie", text: $participantsText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }
                Text("Comma-separated names. Matched to speakers in order of first appearance.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let recording = appState.currentRecording, !recording.calendarCandidates.isEmpty {
                LabeledContent("Meeting:") {
                    Picker("Meeting", selection: calendarSelection(recording)) {
                        Text("None").tag(String?.none)
                        ForEach(recording.calendarCandidates) { event in
                            Text(pickerLabel(event)).tag(Optional(event.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                Text("Pick the meeting this recording belongs to. Fills the title, participants, and AI context.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Post-Processing Options")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Toggle("Transcribe audio", isOn: $transcribe)

            if appSettings.aiProcessingEnabled {
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
            } else {
                Text("AI processing is disabled in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    applyFieldsToRecording()
                    Task { await recordingManager.skipProcessing() }
                }
                .buttonStyle(.bordered)
                .disabled(sanitizedMeetingTitle.isEmpty)

                Button("Queue") {
                    applyFieldsToRecording()
                    Task {
                        await recordingManager.queueForLater(
                            transcribe: transcribe,
                            summary: summary && transcribe,
                            actionItems: actionItems && transcribe,
                            tags: tags && transcribe
                        )
                    }
                }
                .buttonStyle(.bordered)
                .disabled(sanitizedMeetingTitle.isEmpty)
                .help("Finalize audio and queue processing for later")

                Spacer()

                Button("Process") {
                    applyFieldsToRecording()
                    recordingManager.startProcessing(
                        transcribe: transcribe,
                        summary: summary && transcribe,
                        actionItems: actionItems && transcribe,
                        tags: tags && transcribe
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    sanitizedMeetingTitle.isEmpty
                        || (transcribe
                            && appSettings.effectiveTranscriptionEngine == .remoteEndpoint
                            && appSettings.effectiveDefaultTranscriptionEndpoint == nil)
                )
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            transcribe = appSettings.effectiveAutoTranscribe
            summary = appSettings.effectiveAutoSummary
            actionItems = appSettings.effectiveAutoActionItems
            tags = appSettings.effectiveAutoTags
            if let recording = appState.currentRecording {
                let existing = recording.meetingTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                meetingTitle = existing.isEmpty ? fallbackMeetingTitle(recording: recording) : existing
            } else {
                meetingTitle = "meeting"
            }
            if let recording = appState.currentRecording, let event = recording.calendarEvent {
                applyCalendarEvent(event, to: recording)
            }
        }
        .onChange(of: appState.currentRecording?.calendarEvent?.id) { _, _ in
            guard let recording = appState.currentRecording,
                  let event = recording.calendarEvent else { return }
            applyCalendarEvent(event, to: recording)
        }
    }

    private var enabledDestinationNames: [String] {
        var values: [String] = []
        let i = appSettings.integrations
        if i.appleNotes.enabled { values.append(IntegrationDestination.appleNotes.displayName) }
        if i.appleReminders.enabled { values.append(IntegrationDestination.appleReminders.displayName) }
        if i.webhook.enabled { values.append(IntegrationDestination.webhook.displayName) }
        return values
    }

    private var webhookFieldsDescription: String {
        let labels = appSettings.integrations.webhook.fields.map(\.displayName)
        return labels.isEmpty ? "None selected" : labels.joined(separator: ", ")
    }

    private var sanitizedMeetingTitle: String {
        let trimmed = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : trimmed
    }

    private func fallbackMeetingTitle(recording: Recording) -> String {
        let appName = recording.associatedApp?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return appName.isEmpty ? "meeting" : appName
    }

    private func applyFieldsToRecording() {
        guard let recording = appState.currentRecording else { return }
        recording.meetingTitleDraft = sanitizedMeetingTitle
        recording.participants = participantsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func applyCalendarEvent(_ event: CalendarEvent, to recording: Recording) {
        let current = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFallback = current.isEmpty
            || current == "meeting"
            || current == fallbackMeetingTitle(recording: recording)
        if isFallback, !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            meetingTitle = event.title
        }
        if participantsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !event.participantsText.isEmpty {
            participantsText = event.participantsText
        }
    }

    /// Two-way binding between the picker and `recording.calendarEvent`, keyed by event id.
    private func calendarSelection(_ recording: Recording) -> Binding<String?> {
        Binding(
            get: { recording.calendarEvent?.id },
            set: { newID in
                let event = recording.calendarCandidates.first { $0.id == newID }
                selectCalendarEvent(event, to: recording)
            }
        )
    }

    /// Explicit user pick: overwrite title and participants from the chosen event
    /// (distinct from the auto-fill guard in `applyCalendarEvent`). `nil` clears context
    /// without wiping fields the user may have typed.
    private func selectCalendarEvent(_ event: CalendarEvent?, to recording: Recording) {
        recording.calendarEvent = event
        guard let event else { return }
        if !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            meetingTitle = event.title
        }
        participantsText = event.participantsText
    }

    private func pickerLabel(_ event: CalendarEvent) -> String {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(untitled)" : event.title
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        return "\(title)  \(start)–\(end)"
    }
}
