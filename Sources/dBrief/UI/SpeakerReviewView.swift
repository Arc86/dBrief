import SwiftUI

/// Shared review content for a menu-bar window or a transcript-viewer sheet.
struct SpeakerReviewView: View {
    let onConfirm: (UUID, [String: ConfirmedSpeaker]) -> Void
    let onCancel: (UUID) -> Void

    static let contentSize = CGSize(width: 780, height: 700)

    @Environment(AppState.self) private var appState
    @Environment(RecordingManager.self) private var recordingManager
    @State private var draft: SpeakerReviewDraft?
    @State private var editingSessionID: UUID?
    @State private var library = VoiceLibrary()
    @State private var libraryLoading = true
    // Reviewing a voice must not move or stop playback in the transcript viewer.
    @State private var samplePlayer = AudioPlayer()

    var body: some View {
        Group {
            if let session = appState.pendingSpeakerReview,
               session.id == editingSessionID, let draft {
                SpeakerReviewContent(
                    draft: draft,
                    meetingTitle: session.recording.calendarEvent?.title,
                    meetingNames: session.recording.participants + (session.recording.calendarEvent?.attendeeNames ?? []),
                    library: library, libraryLoading: libraryLoading,
                    masterAudioURL: session.masterAudioURL,
                    samplePlayer: samplePlayer,
                    beforeAnalysis: session.origin == .pipeline,
                    onConfirm: {
                        guard appState.pendingSpeakerReview?.id == session.id else { return }
                        // Include a name still being typed if Confirm is clicked directly.
                        draft.useManualName()
                        samplePlayer.stop()
                        onConfirm(session.id, draft.edits)
                    },
                    onCancel: {
                        guard appState.pendingSpeakerReview?.id == session.id else { return }
                        samplePlayer.stop()
                        onCancel(session.id)
                    }
                )
            } else {
                ProgressView("Loading speakers…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .panelWindowChrome()
        .task(id: appState.pendingSpeakerReview?.id) {
            samplePlayer.stop()
            guard let session = appState.pendingSpeakerReview else { return }
            editingSessionID = session.id
            draft = SpeakerReviewDraft(items: session.items)
            library = VoiceLibrary()
            libraryLoading = true
            let loaded = await recordingManager.loadVoiceLibrary()
            guard !Task.isCancelled, appState.pendingSpeakerReview?.id == session.id else { return }
            library = loaded
            libraryLoading = false
        }
        .onDisappear { samplePlayer.stop() }
    }
}

/// Separate from session ownership so the actual layout can be previewed with local data.
struct SpeakerReviewContent: View {
    @Bindable var draft: SpeakerReviewDraft
    let meetingTitle: String?
    let meetingNames: [String]
    let library: VoiceLibrary
    let libraryLoading: Bool
    let masterAudioURL: URL?
    let samplePlayer: AudioPlayer
    let beforeAnalysis: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SpeakerReviewHeader(meetingTitle: meetingTitle,
                                attendeeCount: PersonName.displayList(meetingNames).count,
                                beforeAnalysis: beforeAnalysis)
            MenuPanelHairline()
            HStack(spacing: 0) {
                speakerList
                Rectangle().fill(palette.divider.color).frame(width: 1)
                if let item = draft.selectedItem {
                    SpeakerReviewPicker(
                        draft: draft, item: item,
                        meetingChoices: SpeakerReviewCandidates.meetingChoices(
                            names: meetingNames, library: library, search: draft.search),
                        libraryChoices: SpeakerReviewCandidates.libraryChoices(
                            library: library, search: draft.search, clusterEmbedding: item.clusterEmbedding),
                        hasMeetingNames: !PersonName.displayList(meetingNames).isEmpty,
                        hasLibraryPeople: !library.people.isEmpty,
                        libraryLoading: libraryLoading,
                        masterAudioURL: masterAudioURL, samplePlayer: samplePlayer
                    )
                    .id(item.id)
                } else {
                    ContentUnavailableView("Select a speaker", systemImage: "person.wave.2",
                                           description: Text("Choose a voice from the list to give it a name."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            MenuPanelHairline()
            SpeakerReviewFooter(reviewedCount: draft.reviewedIDs.count, speakerCount: draft.items.count,
                                canConfirm: !draft.items.isEmpty && !libraryLoading,
                                onConfirm: onConfirm, onCancel: onCancel)
        }
        .onChange(of: draft.selectedID) { _, _ in
            draft.clearInput()
            samplePlayer.stop()
        }
    }

    /// The detected voices, styled like the library sidebar; arrow keys move the selection.
    private var speakerList: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(draft.items) { item in
                    Button { draft.selectedID = item.id } label: {
                        SpeakerReviewListRow(
                            item: item,
                            name: draft.edits[item.id]?.name ?? item.proposedName,
                            reviewed: draft.reviewedIDs.contains(item.id),
                            selected: draft.selectedID == item.id
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(draft.selectedID == item.id ? .isSelected : [])
                }
            }
            .padding(10)
        }
        .frame(width: 220)
        .background(LinearGradient(colors: [palette.sidebarTop.color, palette.sidebarBottom.color], startPoint: .top, endPoint: .bottom))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
        .accessibilityLabel("Detected speakers")
    }

    private func moveSelection(by offset: Int) {
        guard !draft.items.isEmpty else { return }
        let current = draft.items.firstIndex { $0.id == draft.selectedID } ?? -1
        let next = min(max(current + offset, 0), draft.items.count - 1)
        draft.selectedID = draft.items[next].id
    }
}

private struct SpeakerReviewHeader: View {
    let meetingTitle: String?
    let attendeeCount: Int
    let beforeAnalysis: Bool

    var body: some View {
        PanelWindowHeader(
            title: "Who’s speaking?",
            subtitle: beforeAnalysis ? "Name the voices before continuing with analysis." : "Choose who each voice belongs to.",
            detail: meetingTitle.map { "\($0) · \(attendeeCount) attendee\(attendeeCount == 1 ? "" : "s")" }
                ?? (attendeeCount > 0 ? "\(attendeeCount) meeting participant\(attendeeCount == 1 ? "" : "s")" : nil)
        )
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }
}

private struct SpeakerReviewListRow: View {
    let item: SpeakerReviewItem
    let name: String
    let reviewed: Bool
    var selected = false
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var panelStatus

    var body: some View {
        HStack(spacing: 10) {
            SpeakerReviewAvatar(name: name, named: name != item.id, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).uiFont(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? palette.accentText.color : palette.heading.color).lineLimit(2)
                Text(status).uiFont(.system(size: 11)).foregroundStyle(palette.secondary.color)
            }
            Spacer(minLength: 0)
            if reviewed {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(panelStatus.success.color)
                    .accessibilityLabel("Reviewed")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? palette.selected.color : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .help("\(name) — \(status)")
    }

    private var status: String {
        if reviewed { return name == item.id ? "Kept unnamed" : "Named" }
        if name != item.id {
            return item.reason == .matched ? "Suggested · \(Int(item.confidence * 100))%" : "Suggested name"
        }
        return "Needs a name"
    }
}

private struct SpeakerReviewPicker: View {
    @Bindable var draft: SpeakerReviewDraft
    let item: SpeakerReviewItem
    let meetingChoices: [SpeakerReviewCandidates.Choice]
    let libraryChoices: [SpeakerReviewCandidates.Choice]
    let hasMeetingNames: Bool
    let hasLibraryPeople: Bool
    let libraryLoading: Bool
    let masterAudioURL: URL?
    let samplePlayer: AudioPlayer
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(draft.edits[item.id]?.name ?? item.proposedName)
                    .uiFont(.system(size: 15, weight: .semibold)).lineLimit(2)
                    .foregroundStyle(palette.heading.color)
                Text("Choose who this voice belongs to.")
                    .uiFont(.system(size: 12))
                    .foregroundStyle(palette.secondary.color)
                SpeakerReviewVoiceSample(item: item, url: masterAudioURL, player: samplePlayer)
                    .padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Search meeting & library").uiFont(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                TextField("Find a person…", text: $draft.search)
                    .panelTextField()
                    .accessibilityLabel("Search meeting and library")
            }
            ScrollView {
                HStack(alignment: .top, spacing: 18) {
                    SpeakerReviewChoiceGroup(
                        title: "From this meeting", choices: meetingChoices,
                        current: draft.edits[item.id], loading: false,
                        emptyMessage: hasMeetingNames ? "No matching attendees." : "No meeting participants are available.",
                        onSelect: draft.assign
                    )
                    SpeakerReviewChoiceGroup(
                        title: "From your library", choices: libraryChoices,
                        current: draft.edits[item.id], loading: libraryLoading,
                        emptyMessage: hasLibraryPeople ? "No matching people." : "No people saved yet. Enter a name below.",
                        onSelect: draft.assign
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            MenuPanelHairline()
            SpeakerReviewManualName(name: $draft.manualName,
                                    canApply: !draft.trimmedManualName.isEmpty,
                                    onApply: draft.useManualName)
            Button("Keep as \(item.id)", action: draft.keepUnnamed)
                .buttonStyle(MenuPanelButtonStyle(kind: .quiet, height: 24, fontSize: 12))
                .help("Leave this voice unnamed and keep its speaker label.")
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SpeakerReviewChoiceGroup: View {
    let title: String
    let choices: [SpeakerReviewCandidates.Choice]
    let current: ConfirmedSpeaker?
    let loading: Bool
    let emptyMessage: String
    let onSelect: (SpeakerReviewCandidates.Choice) -> Void
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).uiFont(.system(size: 11, weight: .semibold)).foregroundStyle(palette.secondary.color)
                .padding(.bottom, 3)
            if loading {
                ProgressView("Loading library…").controlSize(.small)
            } else if choices.isEmpty {
                Text(emptyMessage).uiFont(.system(size: 12)).foregroundStyle(palette.secondary.color)
            } else {
                ForEach(choices) { choice in
                    SpeakerReviewPersonRow(choice: choice, selected: isSelected(choice)) {
                        onSelect(choice)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func isSelected(_ choice: SpeakerReviewCandidates.Choice) -> Bool {
        if let personId = choice.personId { return current?.personId == personId }
        return current?.name.caseInsensitiveCompare(choice.name) == .orderedSame
    }
}

private struct SpeakerReviewPersonRow: View {
    let choice: SpeakerReviewCandidates.Choice
    let selected: Bool
    let onSelect: () -> Void
    @Environment(\.viewerPalette) private var palette
    @State private var hovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                SpeakerReviewAvatar(name: choice.name, named: selected, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.name).uiFont(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.heading.color)
                        .multilineTextAlignment(.leading)
                    if let detail = choice.detail, !detail.isEmpty {
                        Text(detail).uiFont(.system(size: 11)).foregroundStyle(palette.secondary.color).lineLimit(1)
                    }
                }
                Spacer(minLength: 2)
                Image(systemName: selected ? "checkmark" : "plus")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.accentText.color)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? palette.selected.color : hovered ? palette.canvas.color : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .onHover { hovered = $0 }
        .buttonStyle(.plain)
        .help(choice.detail.map { "\(choice.name) · \($0)" } ?? choice.name)
        .accessibilityLabel(choice.detail.flatMap { $0.isEmpty ? nil : "Use \(choice.name), \($0)" } ?? "Use \(choice.name)")
        .accessibilityValue(selected ? "Selected" : "")
    }
}

private struct SpeakerReviewManualName: View {
    @Binding var name: String
    let canApply: Bool
    let onApply: () -> Void
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enter a name manually").uiFont(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.heading.color)
            HStack(spacing: 8) {
                TextField("e.g. Alex de Jong", text: $name)
                    .panelTextField()
                    .accessibilityLabel("Enter a name manually")
                    .onSubmit(onApply)
                Button("Use name", action: onApply).disabled(!canApply)
                    .buttonStyle(MenuPanelButtonStyle(kind: .secondary, fillsWidth: false))
            }
            PanelNote("No meeting or library match needed.")
        }
    }
}

private struct SpeakerReviewVoiceSample: View {
    let item: SpeakerReviewItem
    let url: URL?
    let player: AudioPlayer

    private var playing: Bool { player.playingTag == item.id && player.isPlaying }

    var body: some View {
        if let snippet = item.snippet, let url {
            Button {
                if playing { player.stop() }
                else { player.playRange(url: url, from: snippet.start, to: snippet.end, tag: item.id) }
            } label: {
                Label(playing ? "Stop sample" : "Play voice sample", systemImage: playing ? "stop.fill" : "play.fill")
            }
            .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 26, fontSize: 11, fillsWidth: false))
        } else {
            Label("Voice sample unavailable", systemImage: "waveform.slash")
                .uiFont(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct SpeakerReviewFooter: View {
    let reviewedCount: Int
    let speakerCount: Int
    let canConfirm: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                .buttonStyle(MenuPanelButtonStyle(kind: .secondary, fillsWidth: false))
            Text("\(reviewedCount) of \(speakerCount) reviewed").uiFont(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("Confirm speakers", action: onConfirm)
                .buttonStyle(MenuPanelButtonStyle(kind: .hero, height: 30, fontSize: 12, fillsWidth: false))
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

private struct SpeakerReviewAvatar: View {
    let name: String
    let named: Bool
    let size: CGFloat
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        Text(Theme.initials(for: name))
            .uiFont(.system(size: size / 3, weight: .semibold))
            .foregroundStyle(named ? palette.accentText.color : palette.secondary.color)
            .frame(width: size, height: size)
            .background(named ? palette.selected.color : palette.canvas.color, in: Circle())
            .overlay(Circle().strokeBorder(palette.divider.color, lineWidth: named ? 0 : 1))
            .accessibilityHidden(true)
    }
}
