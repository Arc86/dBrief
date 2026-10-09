import SwiftUI

struct PostRecordingSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status

    @State private var transcribe = true
    @State private var summary = true
    @State private var actionItems = true
    @State private var tags = true
    @State private var loadCalendarParticipants = false
    @State private var meetingTitle = ""
    @State private var participantNames: [String] = []
    /// The roster the sheet last auto-filled, so a later attendee load can
    /// refresh the field while still respecting genuine manual edits.
    @State private var lastAutoFilledParticipants: [String] = []
    @State private var attendeeLoadState: AttendeeLoadState = .idle
    @State private var calendarPickerOutcome: CalendarCLIPickerOutcome?
    @State private var calendarPickerRefreshing = false
    @State private var calendarPickerLastRefresh: Date?
    @State private var calendarPickerTask: Task<Void, Never>?
    @State private var participantInput = ""
    /// The pill currently being edited in place (nil = none). Single-valued, so exactly one
    /// pill is ever swapped for a text field.
    @State private var editingParticipant: String?
    @FocusState private var participantFieldFocused: Bool
    @State private var confirmingDelete = false
    @State private var showProcessingSettings = false
    @FocusState private var titleFocused: Bool
    @State private var titleHovered = false
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
        loadCalendarParticipants = appSettings.resolvedAutoLoadCalendarParticipants(for: reviewProfile)
    }

    private var reviewAIEnabled: Bool {
        reviewProfile.overrides.aiProcessingEnabled ?? appSettings.aiProcessingEnabled
    }

    private var acceptedCalendarParticipantLoad: Bool {
        guard loadCalendarParticipants, appState.currentRecording?.calendarEvent != nil else { return false }
        if appSettings.effectiveCalendarSource == .claudeCLI {
            return appSettings.effectiveCalendarCLIConfig.attendeePolicy == .onDemand
        }
        return appSettings.effectiveCalendarSource != .disabled
    }

    private var reviewNeedsTranscriptionEndpoint: Bool {
        let engine = reviewProfile.overrides.transcriptionEngine ?? appSettings.transcriptionEngine
        let endpoint = reviewProfile.overrides.transcriptionEndpointId.flatMap { id in
            appSettings.transcriptionEndpoints.first(where: { $0.id == id })
        } ?? appSettings.defaultTranscriptionEndpoint
        return engine == .remoteEndpoint && endpoint == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let request = recordingManager.postRecordingAutomation.request {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(request.profile.postRecordingPolicy == .process
                             ? "Processing in \(recordingManager.postRecordingAutomation.secondsRemaining) seconds"
                             : "Queueing in \(recordingManager.postRecordingAutomation.secondsRemaining) seconds")
                            .uiFont(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(palette.heading.color)
                        Text("Choose Review instead to change this recording’s options.")
                            .uiFont(.system(size: 11))
                            .foregroundStyle(palette.secondary.color)
                    }
                    Spacer(minLength: 4)
                    Button("Review instead") { recordingManager.cancelPostRecordingAutomation() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 30, fontSize: 11, fillsWidth: false))
                }
                .padding(12)
                .background(palette.selected.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            reviewContent.disabled(recordingManager.postRecordingAutomation.isPending)
        }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleBlock
            MenuPanelHairline()

            // Meeting details and Processing settings work as an accordion so the
            // panel stays short: opening one folds the other into a summary row.
            if showProcessingSettings {
                meetingSummaryRow
            } else {
                if let recording = appState.currentRecording, showsMeetingDetails(recording) {
                    meetingDetails(for: recording)
                }

                if appSettings.diarizationEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(participantNames.isEmpty ? "Participants" : "Participants (\(participantNames.count))")
                            .uiFont(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.heading.color)
                        participantsField
                        Text("Press Return to add each name · matched to speakers in order of first appearance.")
                            .uiFont(.system(size: 11))
                            .foregroundStyle(palette.secondary.color)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            MenuPanelHairline()
            if profileNoticeOnSurface {
                profileContext
            }
            processingSettings
            MenuPanelHairline()

            postRecordingStatus

            if confirmingDelete {
                deleteConfirmation
            } else {
                actionArea
            }
        }
        .disabled(recordingManager.postRecordingAction.isBusy)
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
            if appSettings.effectiveCalendarSource == .claudeCLI,
               let recording = appState.currentRecording {
                refreshCalendarPicker(for: recording, force: false)
            }
        }
        .onDisappear {
            calendarPickerTask?.cancel()
            calendarPickerRefreshing = false
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

    // MARK: - Title

    /// The editable meeting title, set as the screen's heading. It names the output
    /// files, so it stays a text field; it wraps to three lines, then scrolls.
    private var titleBlock: some View {
        VStack(spacing: 6) {
            if let action = recordingManager.postRecordingAction.action, recordingManager.postRecordingAction.isBusy {
                Label(action.title, systemImage: "hourglass")
                    .uiFont(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.secondary.color)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TextField("Meeting title", text: $meetingTitle, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .multilineTextAlignment(.center)
                    .uiFont(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                    .focused($titleFocused)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Meeting title")
                    .accessibilityHint("Edit to rename the recording")
                    .onChange(of: meetingTitle) { _, title in
                        // A title is one line; a pasted or Option-Return newline would leak into file names.
                        if title.contains(where: \.isNewline) {
                            meetingTitle = title.components(separatedBy: .newlines).joined(separator: " ")
                        }
                    }
                Button { titleFocused = true } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(titleFocused || titleHovered ? palette.accentText.color : palette.secondary.color)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rename recording")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(titleFocused ? palette.primary.color : titleHovered ? palette.divider.color : .clear, lineWidth: 1)
            }
            .onHover { titleHovered = $0 }
            .help("Click to rename · used for file naming (YYYY-MM-DD_HHMM_[meeting-title].md)")
            if let recording = appState.currentRecording {
                HStack(spacing: 6) {
                    Text("\(recording.formattedDuration) · \(recording.formattedFileSize)")
                    if recording.calendarEvent != nil {
                        Text("·")
                        Label("Calendar linked", systemImage: "calendar")
                    }
                    if recordingManager.postRecordingAction.isBusy {
                        ProgressView().controlSize(.mini).accessibilityLabel("Saving recording")
                    }
                }
                .uiFont(.system(size: 11))
                .foregroundStyle(palette.secondary.color)
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Meeting details

    private func showsMeetingDetails(_ recording: Recording) -> Bool {
        appSettings.effectiveCalendarSource == .claudeCLI || !recording.calendarCandidates.isEmpty
    }

    /// Folded meeting details + participants while Processing settings is open.
    private var meetingSummaryRow: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { showProcessingSettings = false }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meeting details")
                        .uiFont(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.heading.color)
                    Text([appState.currentRecording?.calendarEvent?.title ?? "No meeting linked",
                          participantNames.isEmpty ? "no participants" : "\(participantNames.count) participant\(participantNames.count == 1 ? "" : "s")"]
                        .joined(separator: " · "))
                        .uiFont(.system(size: 11))
                        .foregroundStyle(palette.secondary.color)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.secondary.color)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows meeting details and participants")
    }

    @ViewBuilder
    private func meetingDetails(for recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Meeting details")
                    .uiFont(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.heading.color)
                Spacer()
                if appSettings.effectiveCalendarSource == .claudeCLI {
                    Button { refreshCalendarPicker(for: recording, force: true) } label: {
                        HStack(spacing: 5) {
                            if calendarPickerRefreshing {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Refresh")
                        }
                    }
                    .buttonStyle(MenuPanelButtonStyle(kind: .quiet, height: 24, fontSize: 12))
                    .disabled(calendarPickerRefreshing)
                    .accessibilityLabel("Refresh meeting list")
                }
            }
            Menu {
                Button("None") { calendarSelection(recording).wrappedValue = nil }
                ForEach(recording.calendarCandidates) { event in
                    Button {
                        calendarSelection(recording).wrappedValue = event.id
                    } label: {
                        if event.id == recording.calendarEvent?.id {
                            Label(pickerLabel(event), systemImage: "checkmark")
                        } else {
                            Text(pickerLabel(event))
                        }
                    }
                }
            } label: {
                MenuPanelSelectorLabel(text: recording.calendarEvent.map(pickerLabel) ?? "No meeting linked", height: 36)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Meeting")
            .accessibilityValue(recording.calendarEvent.map(pickerLabel) ?? "None")

            if appSettings.effectiveCalendarSource == .claudeCLI {
                calendarPickerStatus
                calendarAttendeesBlock(for: recording)
            } else if recording.calendarEvent != nil {
                Text("Calendar attendees are already included with the selected meeting.")
                    .uiFont(.system(size: 11)).foregroundStyle(palette.secondary.color)
            }
        }
    }

    // MARK: - Processing settings

    private var profileNoticeOnSurface: Bool {
        MenuPanelProgress.profileNoticeOnSurface(isDeferred: appState.currentRecording?.profileSelection.isDeferred ?? false)
    }

    private var selectedTaskCount: Int {
        MenuPanelProgress.selectedTaskCount(transcribe: transcribe, summary: summary, actionItems: actionItems,
                                            tags: tags, aiEnabled: reviewAIEnabled)
    }

    private var processingSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showProcessingSettings.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Processing settings")
                            .uiFont(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.heading.color)
                        Text("\(reviewProfile.name) profile · \(selectedTaskCount) task\(selectedTaskCount == 1 ? "" : "s") selected")
                            .uiFont(.system(size: 11))
                            .foregroundStyle(palette.secondary.color)
                    }
                    Spacer()
                    Image(systemName: showProcessingSettings ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.secondary.color)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showProcessingSettings ? "expanded" : "collapsed")

            if showProcessingSettings {
                processingSettingsDetail
            }
        }
    }

    @ViewBuilder
    private var processingSettingsDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Profile")
                    .uiFont(.system(size: 11))
                    .foregroundStyle(palette.secondary.color)
                profileMenu
            }
            if !profileNoticeOnSurface {
                profileContext
            }

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
                        .uiFont(.system(size: 11))
                        .foregroundStyle(status.warning.color)
                }
            } else {
                Text("AI processing is disabled in Settings.")
                    .uiFont(.system(size: 11))
                    .foregroundStyle(palette.secondary.color)
            }

            if appSettings.obsidianEnabled, let recording = appState.currentRecording {
                ObsidianFolderPicker(
                    title: "Obsidian output folder",
                    currentRelativePath: currentObsidianFolder(for: recording)
                ) { relativePath in
                    recording.obsidianFolderRelativePath = relativePath
                    if reviewProfile.isProtectedDefault {
                        appSettings.obsidianDefaultFolderRelativePath = relativePath
                    }
                }
            }

            if !enabledDestinationNames.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Auto-send destinations")
                        .uiFont(.system(size: 11))
                        .foregroundStyle(palette.secondary.color)
                    Text(enabledDestinationNames.joined(separator: ", "))
                        .uiFont(.system(size: 11))
                        .foregroundStyle(palette.text.color)
                    if appSettings.integrations.webhook.enabled {
                        Text("Webhook fields: \(webhookFieldsDescription)")
                            .uiFont(.system(size: 11))
                            .foregroundStyle(palette.secondary.color)
                    }
                }
            }
        }
    }

    /// Why this recording got its profile (manual, automatic match, or still deciding).
    @ViewBuilder
    private var profileContext: some View {
        if let recording = appState.currentRecording {
            if recording.awaitingProfileContext {
                Text("Checking calendar context for profile selection…")
                    .uiFont(.system(size: 11)).foregroundStyle(palette.secondary.color)
            } else if recording.profileSelection.isManual {
                Text("Profile chosen manually for this recording")
                    .uiFont(.system(size: 11)).foregroundStyle(palette.secondary.color)
            } else if let match = recording.profileSelection.match,
                      let profile = appSettings.profiles.first(where: { $0.id == match.profileID }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.profileSelection.isDeferred
                         ? "Suggested: \(profile.name) — waiting for the current job"
                         : "Selected automatically: \(profile.name)")
                        .uiFont(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.text.color)
                    Text(match.reasons.joined(separator: " · "))
                        .uiFont(.system(size: 11)).foregroundStyle(palette.secondary.color)
                    if recording.profileSelection.isDeferred {
                        Button("Keep current profile") { recordingManager.cancelPostRecordingAutomation() }
                            .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 26, fontSize: 11, fillsWidth: false))
                    }
                }
            }
        }
    }

    private func currentObsidianFolder(for recording: Recording) -> String {
        recording.obsidianFolderRelativePath
            ?? reviewProfile.overrides.obsidianDefaultFolderRelativePath
            ?? appSettings.obsidianDefaultFolderRelativePath
    }

    // MARK: - Actions

    private var actionArea: some View {
        VStack(spacing: 10) {
            Button {
                applyFieldsToRecording()
                recordingManager.startProcessing(
                    transcribe: transcribe,
                    summary: summary && transcribe,
                    actionItems: actionItems && transcribe,
                    tags: tags && transcribe,
                    loadCalendarParticipants: acceptedCalendarParticipantLoad
                )
            } label: {
                Label("Process recording", systemImage: "play")
            }
            .buttonStyle(MenuPanelButtonStyle(kind: .hero, height: 36, fontSize: 14))
            .disabled(processDisabled)

            if appSettings.obsidianEnabled, let recording = appState.currentRecording {
                Text("Output folder · \(appSettings.obsidianFolderDisplayName(relativePath: currentObsidianFolder(for: recording)))")
                    .uiFont(.system(size: 11))
                    .foregroundStyle(palette.secondary.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if reviewNeedsTranscriptionEndpoint && transcribe {
                Text("No transcription endpoint configured. Add one in Settings.")
                    .uiFont(.system(size: 11))
                    .foregroundStyle(status.danger.color)
            }

            HStack(spacing: 8) {
                Button("Keep audio only") {
                    applyFieldsToRecording()
                    Task { await recordingManager.skipProcessing() }
                }
                .disabled(sanitizedMeetingTitle.isEmpty)
                .help("Keep the audio and stop here")

                Button("Queue") {
                    applyFieldsToRecording()
                    Task {
                        await recordingManager.queueForLater(
                            transcribe: transcribe,
                            summary: summary && transcribe,
                            actionItems: actionItems && transcribe,
                            tags: tags && transcribe,
                            loadCalendarParticipants: acceptedCalendarParticipantLoad
                        )
                    }
                }
                .disabled(sanitizedMeetingTitle.isEmpty)
                .help("Finalize audio and queue processing for later")

                Button {
                    withAnimation(.easeOut(duration: 0.15)) { confirmingDelete = true }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(MenuPanelButtonStyle(kind: .danger, height: 30, fillsWidth: false))
                .accessibilityLabel("Delete recording")
                .help("Delete recording")
            }
            .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 30))
        }
    }

    @ViewBuilder
    private var postRecordingStatus: some View {
        let state = recordingManager.postRecordingAction
        if state.isBusy {
            VStack(alignment: .leading, spacing: 5) {
                if let progress = state.progress {
                    ProgressView(value: progress)
                        .tint(palette.primary.color)
                        .accessibilityLabel("Audio saving progress")
                }
                Text(state.progress == 1
                     ? "Finishing save… Please keep dBrief open."
                     : "Preparing your audio. Longer recordings can take a few minutes. Please keep dBrief open.")
                    .uiFont(.system(size: 11))
                    .foregroundStyle(palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if state.recordingID == appState.currentRecording?.id, let error = state.error {
            Label("Couldn’t finish: \(error) Try again, or choose another action.", systemImage: "exclamationmark.triangle")
                .uiFont(.system(size: 11))
                .foregroundStyle(status.danger.color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else if appState.processingJob != nil {
            Text("Another recording is processing. Process saves this recording and queues it to run automatically.")
                .uiFont(.system(size: 11))
                .foregroundStyle(palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Inline delete confirmation shown in place of the action area.
    private var deleteConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Delete this recording?")
                .uiFont(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.heading.color)
            Text(appState.currentRecording?.importSourceURL != nil
                ? "dBrief’s copy of this audio is removed. The original isn’t touched."
                : "The audio file is permanently removed from disk. This can’t be undone.")
                .uiFont(.system(size: 11))
                .foregroundStyle(palette.text.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {
                    withAnimation(.easeOut(duration: 0.15)) { confirmingDelete = false }
                }
                .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 32, fillsWidth: false))
                .keyboardShortcut(.cancelAction)

                Button("Delete") {
                    Task { await recordingManager.discardRecording() }
                }
                .buttonStyle(MenuPanelButtonStyle(kind: .dangerFilled, height: 32, fillsWidth: false))
            }
        }
        .padding(16)
        .background(status.dangerFill.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(status.dangerBorder.color, lineWidth: 1))
    }

    /// Profile switcher for this recording.
    private var profileMenu: some View {
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
            MenuPanelSelectorLabel(text: reviewProfile.name)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(appState.processingJob != nil)
        .accessibilityLabel("Profile for this recording")
        .accessibilityValue(reviewProfile.name)
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
                            onRemove: { removeParticipant(name) },
                            onEdit: { editingParticipant = name })
                    }
                }
                TextField("Add a name", text: $participantInput)
                    .textFieldStyle(.plain)
                    .uiFont(.system(size: 12))
                    .foregroundStyle(palette.heading.color)
                    .frame(minWidth: 90)
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(palette.surface.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(palette.divider.color, lineWidth: 1))
                    .focused($participantFieldFocused)
                    .onSubmit(addParticipant)
                if !participantInput.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(action: addParticipant) {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 30, fontSize: 11, fillsWidth: false))
                    .help("Add this name (or press Return)")
                }
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
        .padding(12)
        .background(palette.canvas.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.divider.color, lineWidth: 1))
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
            lastAutoFilledParticipants = event.attendeeNames
        }
    }

    // MARK: - Explicit attendee load (Claude CLI source)

    @ViewBuilder
    private var calendarPickerStatus: some View {
        if let refreshed = calendarPickerLastRefresh {
            Text("Updated at \(refreshed.formatted(date: .omitted, time: .shortened))")
                .uiFont(.system(size: 11)).foregroundStyle(palette.secondary.color)
        }
        switch calendarPickerOutcome {
        case .manualOnly:
            Text("Manual mode: press Refresh for the latest meetings.")
                .uiFont(.system(size: 11)).foregroundStyle(palette.secondary.color)
        case .partial, .failed:
            Label(calendarPickerLastRefresh == nil
                  ? "Meeting list unavailable. Press Refresh to retry."
                  : "Showing saved meetings; refresh failed. Press Refresh to retry.",
                  systemImage: "exclamationmark.triangle")
                .uiFont(.system(size: 11)).foregroundStyle(status.warning.color)
        case .blocked:
            Label("Calendar access blocked. Check Claude connector approval, then press Refresh.", systemImage: "lock")
                .uiFont(.system(size: 11)).foregroundStyle(status.warning.color)
        case .saveFailed:
            Label("Loaded, but could not save the cache.", systemImage: "exclamationmark.triangle")
                .uiFont(.system(size: 11)).foregroundStyle(status.warning.color)
        case .selectionMissing:
            Label("Selected meeting changed or disappeared. Review your selection.", systemImage: "exclamationmark.triangle")
                .uiFont(.system(size: 11)).foregroundStyle(status.warning.color)
        case .unconfigured:
            Text("Add a mailbox in Calendar settings to load meetings.")
                .uiFont(.system(size: 11)).foregroundStyle(palette.secondary.color)
        case .complete, .none:
            if !calendarPickerRefreshing, calendarPickerLastRefresh != nil,
               appState.currentRecording?.calendarCandidates.isEmpty == true {
                Text("No meetings for this day.").uiFont(.system(size: 11)).foregroundStyle(palette.secondary.color)
            }
        }
    }

    private func refreshCalendarPicker(for recording: Recording, force: Bool) {
        guard !calendarPickerRefreshing else { return }
        calendarPickerRefreshing = true
        calendarPickerTask = Task { @MainActor in
            let outcome = await recordingManager.refreshCalendarCLIPicker(for: recording, force: force)
            guard !Task.isCancelled else { return }
            calendarPickerOutcome = outcome
            calendarPickerLastRefresh = await recordingManager.calendarCLIStatus(for: recording)?.lastSuccessfulRefresh
            calendarPickerRefreshing = false
        }
    }

    private enum AttendeeLoadState: Equatable {
        case idle, loading
        case done(String)
        case omittedLarge(Int)
        case unavailable
        case failed

        var isLoaded: Bool {
            if case .done = self { return true }
            return false
        }
    }

    @ViewBuilder
    private func calendarAttendeesBlock(for recording: Recording) -> some View {
        let allowed = recording.calendarEvent != nil
            && appSettings.effectiveCalendarCLIConfig.attendeePolicy == .onDemand
        // Attendees only mean something once a meeting is linked; until then the
        // block is all disabled controls, so leave it out.
        if recording.calendarEvent != nil {
        VStack(alignment: .leading, spacing: 6) {
            Text("Calendar attendees")
                .uiFont(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.heading.color)
                .padding(.top, 6)
            HStack(spacing: 8) {
                BrandCheckRow(title: "Load during processing", isOn: $loadCalendarParticipants, enabled: allowed)
                Button {
                    loadAttendees(for: recording)
                } label: {
                    Label(attendeeLoadState == .loading ? "Loading…"
                          : attendeeLoadState.isLoaded ? "Refresh" : "Load now",
                          systemImage: "person.2")
                }
                .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 30, fillsWidth: false))
                .disabled(!allowed || attendeeLoadState == .loading)
            }
            .help("Fetch invitees during processing; you can start immediately.")
            if !allowed {
                Text(recording.calendarEvent == nil
                     ? "Choose a meeting to load its attendees."
                     : "Attendee loading is set to Never in Calendar settings.")
                    .uiFont(.system(size: 11)).foregroundStyle(palette.secondary.color)
            }
            Group {
                switch attendeeLoadState {
                case .idle:
                    EmptyView()
                case .loading:
                    ProgressView().controlSize(.small)
                case .done(let message):
                    Text(message)
                case .omittedLarge(let count):
                    Text("Attendees omitted: meeting exceeds your limit (\(count) invitees)")
                        
                case .unavailable:
                    Text("Attendee roster unavailable")
                case .failed:
                    Text("Attendee load failed — try again")
                }
            }
            .uiFont(.system(size: 11))
            .foregroundStyle(palette.secondary.color)
        }
        }
    }

    private func loadAttendees(for recording: Recording) {
        guard attendeeLoadState != .loading else { return }
        attendeeLoadState = .loading
        Task { @MainActor in
            let outcome = await recordingManager.loadCalendarCLIAttendees(for: recording)
            switch outcome {
            case .loaded(let count):
                attendeeLoadState = .done("\(count) attendee\(count == 1 ? "" : "s") loaded")
                applyLoadedRoster(to: recording)
            case .noInvitees:
                attendeeLoadState = .done("No invitees")
                applyLoadedRoster(to: recording)
            case .omittedLargeMeeting(let count):
                attendeeLoadState = .omittedLarge(count)
            case .unavailable:
                attendeeLoadState = .unavailable
            case .failed:
                attendeeLoadState = .failed
            case .cancelled, .discarded:
                attendeeLoadState = .idle
            case .policyForbids, .sourceInactive, .noOccurrence:
                attendeeLoadState = .unavailable
            }
        }
    }

    /// Reflects the just-loaded roster into the participants field unless the
    /// user typed their own list.
    private func applyLoadedRoster(to recording: Recording) {
        guard let event = recording.calendarEvent else { return }
        if participantNames.isEmpty || participantNames == lastAutoFilledParticipants {
            participantNames = event.attendeeNames
            lastAutoFilledParticipants = event.attendeeNames
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
    /// wiping fields the user may have typed. Routing goes through the manager, which records
    /// the selection revision; the sheet then updates its own fields.
    private func selectCalendarEvent(_ event: CalendarEvent?, to recording: Recording) {
        let previousID = recording.calendarEvent?.id
        recordingManager.selectCalendarCandidate(event, for: recording)
        guard let event else { return }
        if !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            meetingTitle = event.title
        }
        participantNames = event.attendeeNames
        lastAutoFilledParticipants = event.attendeeNames
        if event.id != previousID {
            attendeeLoadState = .idle
        }
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

    @Environment(\.viewerPalette) private var palette
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
            .uiFont(.system(size: 11.5))
            .focused($focused)
            // Hug the text like the pill it replaces; FlowLayout needs a concrete width.
            .frame(width: max(80, CGFloat(text.count) * 7.2 + 20))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
                .background(palette.selected.color, in: Capsule())
            .overlay(Capsule().strokeBorder(palette.primary.color.opacity(0.55), lineWidth: 1))
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
