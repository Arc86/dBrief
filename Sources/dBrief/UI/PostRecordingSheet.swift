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
    @State private var participantNames: [String] = []
    @State private var participantInput = ""
    /// The pill currently being edited in place (nil = none). Single-valued, so exactly one
    /// pill is ever swapped for a text field.
    @State private var editingParticipant: String?
    @FocusState private var participantFieldFocused: Bool
    @State private var confirmingDelete = false
    @State private var participantsBoxHeight: CGFloat = 0

    /// Beyond ≈4–5 pill rows the participants box caps its height and scrolls
    /// internally, so a large calendar attendee list can't push the action row
    /// (Skip / Queue / Process) off the bottom of the menu-bar popover.
    private static let participantsFieldMaxHeight: CGFloat = 168

    private var reviewProfile: MeetingProfile {
        let id = appState.currentRecording?.profileSelection.reviewProfileID(savedManualID: appSettings.activeProfileId)
            ?? appSettings.activeProfileId
        return appSettings.profiles.first(where: { $0.id == id })
            ?? appSettings.profiles.first(where: { $0.id == appSettings.activeProfileId })
            ?? appSettings.activeProfile
    }

    private func loadProfileTaskDefaults() {
        transcribe = reviewProfile.overrides.autoTranscribe ?? appSettings.autoTranscribe
        summary = reviewProfile.overrides.autoSummary ?? appSettings.autoSummary
        actionItems = reviewProfile.overrides.autoActionItems ?? appSettings.autoActionItems
        tags = reviewProfile.overrides.autoTags ?? appSettings.autoTags
    }

    private var reviewAIEnabled: Bool {
        reviewProfile.overrides.aiProcessingEnabled ?? appSettings.aiProcessingEnabled
    }

    private var reviewNeedsTranscriptionEndpoint: Bool {
        let engine = reviewProfile.overrides.transcriptionEngine ?? appSettings.transcriptionEngine
        let endpoint = reviewProfile.overrides.transcriptionEndpointId.flatMap { id in
            appSettings.transcriptionEndpoints.first(where: { $0.id == id })
        } ?? appSettings.defaultTranscriptionEndpoint
        return engine == .remoteEndpoint && endpoint == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Profile for this recording: \(reviewProfile.name)")
                .font(.caption.weight(.semibold))
            if let recording = appState.currentRecording {
                if recording.awaitingProfileContext {
                    Text("Checking calendar context for profile selection…")
                        .font(.caption).foregroundStyle(.secondary)
                } else if recording.profileSelection.isManual {
                    Text("Profile chosen manually for this recording")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let match = recording.profileSelection.match,
                          let profile = appSettings.profiles.first(where: { $0.id == match.profileID }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recording.profileSelection.isDeferred
                             ? "Suggested: \(profile.name) — waiting for the current job"
                             : "Selected automatically: \(profile.name)")
                            .font(.caption.weight(.semibold))
                        Text(match.reasons.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        if recording.profileSelection.isDeferred {
                            Button("Keep current profile") { recordingManager.cancelPostRecordingAutomation() }
                        }
                    }
                }
            }
            if let request = recordingManager.postRecordingAutomation.request {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(request.profile.postRecordingPolicy == .process
                             ? "Processing in \(recordingManager.postRecordingAutomation.secondsRemaining) seconds"
                             : "Queueing in \(recordingManager.postRecordingAutomation.secondsRemaining) seconds")
                            .font(.headline).monospacedDigit()
                        Text("Choose Review instead to change this recording’s options.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Review instead") { recordingManager.cancelPostRecordingAutomation() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            reviewContent.disabled(recordingManager.postRecordingAutomation.isPending)
        }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Success banner
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().fill(Brand.violetTint).frame(width: 30, height: 30)
                    if recordingManager.postRecordingAction.isBusy {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Saving recording")
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(Brand.violet2)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(recordingManager.postRecordingAction.action?.title ?? "Recording complete")
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

                if reviewAIEnabled {
                    BrandCheckRow(title: "Generate summary", isOn: $summary, enabled: transcribe)
                    BrandCheckRow(title: "Extract action items", isOn: $actionItems, enabled: transcribe)
                    BrandCheckRow(title: "Analyze tags & sentiment", isOn: $tags, enabled: transcribe)
                }
            }

            if reviewAIEnabled {
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

            if reviewNeedsTranscriptionEndpoint && transcribe {
                Text("No transcription endpoint configured. Add one in Settings.")
                    .font(.caption)
                    .foregroundStyle(Brand.coral)
            }

            if appSettings.obsidianEnabled, let recording = appState.currentRecording {
                Divider()

                ObsidianFolderPicker(
                    title: "Obsidian output folder",
                    currentRelativePath: recording.obsidianFolderRelativePath
                        ?? reviewProfile.overrides.obsidianDefaultFolderRelativePath
                        ?? appSettings.obsidianDefaultFolderRelativePath
                ) { relativePath in
                    recording.obsidianFolderRelativePath = relativePath
                    if reviewProfile.isProtectedDefault {
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

            postRecordingStatus

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
                    .accessibilityLabel("Delete recording")

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
        .disabled(recordingManager.postRecordingAction.isBusy)
        .padding(.vertical, 4)
        .onAppear {
            loadProfileTaskDefaults()
            if let recording = appState.currentRecording {
                let existing = recording.meetingTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                meetingTitle = existing.isEmpty ? fallbackMeetingTitle(recording: recording) : existing
            } else {
                meetingTitle = "meeting"
            }
            // The calendar lookup runs in RecordingManager.stopRecording; here we only react to
            // its result. If the best match already arrived, pre-fill from it (guarded so we
            // never clobber a title/participants the user typed).
            if !recordingManager.postRecordingAction.isBusy,
               let recording = appState.currentRecording, let event = recording.calendarEvent {
                applyCalendarEvent(event, to: recording)
            }
        }
        .onChange(of: appState.currentRecording?.calendarEvent?.id) { _, _ in
            defer { recordingManager.refreshPostRecordingProfileSelection() }
            // Reactive pre-fill: the async candidate lookup set the best match after the sheet
            // appeared. Auto-fill is guarded; an explicit picker pick is handled in selectCalendarEvent.
            guard !recordingManager.postRecordingAction.isBusy,
                  let recording = appState.currentRecording,
                  let event = recording.calendarEvent else { return }
            applyCalendarEvent(event, to: recording)
        }
        .onChange(of: meetingTitle) { _, title in
            guard !recordingManager.postRecordingAction.isBusy,
                  let recording = appState.currentRecording else { return }
            recording.meetingTitleDraft = title
            recordingManager.refreshPostRecordingProfileSelection()
        }
        .onChange(of: reviewProfile.id) { _, _ in
            guard !recordingManager.postRecordingAction.isBusy else { return }
            loadProfileTaskDefaults()
        }
    }

    @ViewBuilder
    private var postRecordingStatus: some View {
        let state = recordingManager.postRecordingAction
        if state.isBusy {
            VStack(alignment: .leading, spacing: 5) {
                if let progress = state.progress {
                    ProgressView(value: progress)
                        .accessibilityLabel("Audio saving progress")
                }
                Text(state.progress == 1
                     ? "Finishing save… Please keep dBrief open."
                     : "Preparing your audio. Longer recordings can take a few minutes. Please keep dBrief open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if state.recordingID == appState.currentRecording?.id, let error = state.error {
            Label("Couldn’t finish: \(error) Try again, or choose another action.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Brand.coral)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else if appState.processingJob != nil {
            Text("Another recording is processing. Process saves this recording and queues it to run automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                    recordingManager.selectPostRecordingProfile(p.id)
                } label: {
                    if p.id == reviewProfile.id {
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
                Text(reviewProfile.name)
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
        .disabled(appState.processingJob != nil)
        .help(appState.processingJob == nil ? "Choose a profile for this recording" : "Profile changes wait for the current job to finish")
    }

    private var processDisabled: Bool {
        recordingManager.postRecordingAction.isBusy || sanitizedMeetingTitle.isEmpty
            || (transcribe && reviewNeedsTranscriptionEndpoint)
    }

    /// Participant entry as removable pills plus an inline "Add name…" field.
    /// `participantNames` is the canonical store — a *list*, never a comma-joined string:
    /// directory calendars supply names like "den Boer, Bart", and a joined-then-split
    /// round-trip used to shred each of those into two people.
    private var participantsField: some View {
        ScrollView(.vertical) {
            FlowLayout(spacing: 6) {
                ForEach(participantNames, id: \.self) { name in
                    if editingParticipant == name {
                        ParticipantEditField(
                            name: name,
                            onCommit: { commitParticipantEdit(from: name, to: $0) },
                            onCancel: { editingParticipant = nil })
                    } else {
                        ParticipantPill(
                            name: name,
                            color: Theme.speakerColor(for: name),
                            onRemove: { removeParticipant(name) },
                            onEdit: { editingParticipant = name })
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

    /// Adds the typed name(s). A typed comma separates people ("Alice, Bob") — unlike a
    /// calendar's "den Boer, Bart", which `CalendarEvent.attendeeNames` has already folded
    /// into one name before it ever reaches this field.
    private func addParticipant() {
        for name in PersonName.typedNames(participantInput)
        where !participantNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            participantNames.append(name)
        }
        participantInput = ""
    }

    private func removeParticipant(_ name: String) {
        participantNames.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        if editingParticipant == name { editingParticipant = nil }
    }

    private func commitParticipantEdit(from oldName: String, to newName: String) {
        participantNames = PersonName.replacing(oldName, in: participantNames, with: newName)
        editingParticipant = nil
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
        guard !recordingManager.postRecordingAction.isBusy else { return }
        guard let recording = appState.currentRecording else { return }
        recording.meetingTitleDraft = sanitizedMeetingTitle
        recording.titleWasUserProvided = isCustomTitle(sanitizedMeetingTitle, recording: recording)
        recording.participants = participantNames
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
        if participantNames.isEmpty, !event.attendeeNames.isEmpty {
            participantNames = event.attendeeNames
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
        participantNames = event.attendeeNames
    }

    private func pickerLabel(_ event: CalendarEvent) -> String {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(untitled)" : event.title
        if event.isAllDay {
            return "\(title)  All day"
        }
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

/// A participant pill in its editing state: a capsule-shaped text field that takes the pill's
/// place. Return commits, Escape reverts, and clicking away commits rather than discarding.
///
/// Deliberately inline rather than a popover (which is how speaker renaming works in the
/// transcript window): this sheet lives in the `MenuBarExtra` panel, a non-activating window
/// in an `LSUIElement` app, where a popover-hosted text field can't reliably take keyboard
/// focus — the same reason Settings has to flip the activation policy. Fields hosted by the
/// panel itself (this one, the title field, "Add name…") do get input.
private struct ParticipantEditField: View {
    let name: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @Environment(\.calmAppearance) private var calm
    @State private var text: String
    /// Set by Escape so the focus-loss commit below doesn't undo the cancel.
    @State private var cancelled = false
    @FocusState private var focused: Bool

    init(name: String, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.name = name
        self.onCommit = onCommit
        self.onCancel = onCancel
        _text = State(initialValue: name)
    }

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .focused($focused)
            // Hug the text like the pill it replaces; FlowLayout needs a concrete width.
            .frame(width: max(80, CGFloat(text.count) * 7.2 + 20))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    calm ? Color.primary.opacity(0.35) : Brand.violet.opacity(0.55),
                    lineWidth: 1)
            )
            .onSubmit { onCommit(text) }
            .onExitCommand {
                cancelled = true
                onCancel()
            }
            .onAppear { focused = true }
            .onChange(of: focused) { _, isFocused in
                guard !isFocused, !cancelled else { return }
                onCommit(text)
            }
    }
}
