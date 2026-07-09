import SwiftUI

struct PostRecordingSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.calmAppearance) private var calm

    @State private var transcribe = true
    @State private var summary = true
    @State private var actionItems = true
    @State private var tags = true
    @State private var meetingTitle = ""
    @State private var participantsText = ""
    @State private var participantInput = ""
    @FocusState private var participantFieldFocused: Bool
    @State private var confirmingDelete = false
    @State private var participantsBoxHeight: CGFloat = 0

    /// Beyond ≈4–5 pill rows the participants box caps its height and scrolls
    /// internally, so a large calendar attendee list can't push the action row
    /// (Skip / Queue / Process) off the bottom of the menu-bar popover.
    private static let participantsFieldMaxHeight: CGFloat = 168

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Success banner
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().fill(Brand.violetTint).frame(width: 30, height: 30)
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(Brand.violet2)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Recording complete")
                        .font(.system(size: 15, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    profilePill
                }
                Spacer(minLength: 8)
                if let recording = appState.currentRecording {
                    VStack(alignment: .trailing, spacing: 3) {
                        Label(recording.formattedDuration, systemImage: "clock")
                        Label(recording.formattedFileSize, systemImage: "doc")
                    }
                    .font(.brandMono(10.5))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
                }
            }

            // Meeting title
            HStack {
                Text("Meeting title")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if appState.currentRecording?.calendarEvent != nil {
                    Label("Calendar linked", systemImage: "calendar")
                        .font(.brandMono(9.5))
                        .foregroundStyle(Brand.cyan2)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Brand.cyanTint, in: Capsule())
                        .labelStyle(.titleAndIcon)
                }
            }
            TextField("meeting", text: $meetingTitle)
                .textFieldStyle(.roundedBorder)

            if let recording = appState.currentRecording, !recording.calendarCandidates.isEmpty {
                Picker("Meeting", selection: calendarSelection(recording)) {
                    Text("None").tag(String?.none)
                    ForEach(recording.calendarCandidates) { event in
                        Text(pickerLabel(event)).tag(Optional(event.id))
                    }
                }
                .labelsHidden()
            }

            Text("Used for file naming · YYYY-MM-DD_HHMM_[meeting-title].md")
                .font(.brandMono(10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Participants
            if appSettings.diarizationEnabled {
                Text("Participants")
                    .font(.system(size: 12.5, weight: .semibold))
                participantsField
                Text("Type a name and press return · matched to speakers in order of first appearance")
                    .font(.brandMono(10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            BrandKicker("Post-processing")

            VStack(alignment: .leading, spacing: 2) {
                BrandCheckRow(title: "Transcribe audio", isOn: $transcribe)

                if appSettings.effectiveAIProcessingEnabled {
                    BrandCheckRow(title: "Generate summary", isOn: $summary, enabled: transcribe)
                    BrandCheckRow(title: "Extract action items", isOn: $actionItems, enabled: transcribe)
                    BrandCheckRow(title: "Analyze tags & sentiment", isOn: $tags, enabled: transcribe)
                }
            }

            if appSettings.effectiveAIProcessingEnabled {
                if !transcribe {
                    Text("Transcription is required for AI analysis.")
                        .font(.caption)
                        .foregroundStyle(Brand.paused)
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
                    .foregroundStyle(Brand.coral)
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
                    BrandKicker("Auto-send destinations")
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

            if confirmingDelete {
                deleteConfirmation
            } else {
                HStack(spacing: 8) {
                    // Delete — coral-outlined icon button (38×38, radius 10)
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { confirmingDelete = true }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Brand.coral)
                            .frame(width: 38, height: 38)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.coral.opacity(0.4), lineWidth: 1))
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Delete recording")

                    Button("Skip") {
                        applyFieldsToRecording()
                        Task { await recordingManager.skipProcessing() }
                    }
                    .buttonStyle(SheetActionButtonStyle())
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
                    .buttonStyle(SheetActionButtonStyle())
                    .disabled(sanitizedMeetingTitle.isEmpty)
                    .help("Finalize audio and queue processing for later")

                    Spacer(minLength: 8)

                    Button {
                        applyFieldsToRecording()
                        recordingManager.startProcessing(
                            transcribe: transcribe,
                            summary: summary && transcribe,
                            actionItems: actionItems && transcribe,
                            tags: tags && transcribe
                        )
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                            Text("Process")
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 38)
                        .background(Brand.ctaFill(calm: calm), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .shadow(color: Brand.ctaGlow(calm: calm), radius: calm ? 0 : 10, y: calm ? 0 : 4)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .disabled(processDisabled)
                    .opacity(processDisabled ? 0.4 : 1)
                }

                Text("**Skip** keeps the audio and stops here · **Delete** removes the file")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
            // The calendar lookup runs in RecordingManager.stopRecording; here we only react to
            // its result. If the best match already arrived, pre-fill from it (guarded so we
            // never clobber a title/participants the user typed).
            if let recording = appState.currentRecording, let event = recording.calendarEvent {
                applyCalendarEvent(event, to: recording)
            }
        }
        .onChange(of: appState.currentRecording?.calendarEvent?.id) { _, _ in
            // Reactive pre-fill: the async candidate lookup set the best match after the sheet
            // appeared. Auto-fill is guarded; an explicit picker pick is handled in selectCalendarEvent.
            guard let recording = appState.currentRecording,
                  let event = recording.calendarEvent else { return }
            applyCalendarEvent(event, to: recording)
        }
    }

    /// Inline delete confirmation (coral panel) shown in place of the action row.
    private var deleteConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Delete this recording?")
                .font(.system(size: 13, weight: .semibold))
            Text("The audio file is permanently removed from disk. This can’t be undone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel") {
                    withAnimation(.easeOut(duration: 0.15)) { confirmingDelete = false }
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await recordingManager.discardRecording() }
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Brand.coral, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(13)
        .background(Brand.coralTint, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Brand.coral.opacity(0.4), lineWidth: 1))
    }

    /// Profile switcher rendered as the design's banner pill ("PROFILE  Default ⌄").
    private var profilePill: some View {
        Menu {
            ForEach(appSettings.profiles) { p in
                Button {
                    appSettings.setActiveProfile(p.id)
                } label: {
                    if p.id == appSettings.activeProfileId {
                        Label(p.name, systemImage: "checkmark")
                    } else {
                        Text(p.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("Profile:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(appSettings.activeProfile.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Brand.violet2)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Brand.violetTint, in: Capsule())
            .overlay(Capsule().strokeBorder(Brand.violet.opacity(0.35), lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var processDisabled: Bool {
        sanitizedMeetingTitle.isEmpty
            || (transcribe
                && appSettings.effectiveTranscriptionEngine == .remoteEndpoint
                && appSettings.effectiveDefaultTranscriptionEndpoint == nil)
    }

    /// Participant entry as removable pills plus an inline "Add name…" field.
    /// `participantsText` (comma-separated) stays the canonical store so calendar
    /// auto-fill and `applyFieldsToRecording` keep working unchanged.
    private var participantsField: some View {
        ScrollView(.vertical) {
            FlowLayout(spacing: 6) {
                ForEach(participantNames, id: \.self) { name in
                    ParticipantPill(name: name, color: Theme.speakerColor(for: name)) {
                        removeParticipant(name)
                    }
                }
                TextField("Add name…", text: $participantInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(minWidth: 90)
                    .focused($participantFieldFocused)
                    .onSubmit(addParticipant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ParticipantsHeightKey.self, value: proxy.size.height)
                }
            )
        }
        // Grow with the content, then cap and scroll. Measured height (min 30 so
        // the input row is always visible) drives the frame so the box hugs its
        // content instead of a bare ScrollView eating the popover's height.
        .frame(height: min(max(participantsBoxHeight, 30), Self.participantsFieldMaxHeight))
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(ParticipantsHeightKey.self) { participantsBoxHeight = $0 }
        .padding(7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { participantFieldFocused = true }
    }

    private var participantNames: [String] {
        participantsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func addParticipant() {
        let name = participantInput.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var names = participantNames
        if !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            names.append(name)
            participantsText = names.joined(separator: ", ")
        }
        participantInput = ""
    }

    private func removeParticipant(_ name: String) {
        let names = participantNames.filter { $0.caseInsensitiveCompare(name) != .orderedSame }
        participantsText = names.joined(separator: ", ")
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

    /// Whether `title` is a title the user genuinely provided — i.e. not the default fallback
    /// ("meeting"/app name) and not the matched calendar event's title. Only user-provided
    /// titles are protected from AI title generation; blank/default/calendar titles are not.
    private func isCustomTitle(_ title: String, recording: Recording) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == "meeting" || trimmed == fallbackMeetingTitle(recording: recording) { return false }
        if let cal = recording.calendarEvent?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !cal.isEmpty, trimmed.compare(cal, options: .caseInsensitive) == .orderedSame { return false }
        return true
    }

    private func applyFieldsToRecording() {
        guard let recording = appState.currentRecording else { return }
        recording.meetingTitleDraft = sanitizedMeetingTitle
        recording.titleWasUserProvided = isCustomTitle(sanitizedMeetingTitle, recording: recording)
        recording.participants = participantsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Guarded auto-fill: only fills the title when it's still a fallback and only fills
    /// participants when empty, so a reactive best-match update never overwrites typed input.
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

    /// Two-way binding between the override picker and `recording.calendarEvent`, keyed by event id.
    private func calendarSelection(_ recording: Recording) -> Binding<String?> {
        Binding(
            get: { recording.calendarEvent?.id },
            set: { newID in
                let event = recording.calendarCandidates.first { $0.id == newID }
                selectCalendarEvent(event, to: recording)
            }
        )
    }

    /// Explicit user pick: overwrite title and participants from the chosen event (distinct
    /// from the auto-fill guard in `applyCalendarEvent`). `nil` clears the context without
    /// wiping fields the user may have typed.
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

/// Reports the participants `FlowLayout`'s natural (wrapped) height so the box can
/// size to fit up to a cap, then scroll.
private struct ParticipantsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
