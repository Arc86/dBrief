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
        .background(Color(nsColor: .windowBackgroundColor))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SpeakerReviewHeader(meetingTitle: meetingTitle,
                                attendeeCount: PersonName.displayList(meetingNames).count,
                                beforeAnalysis: beforeAnalysis)
            Divider()
            HStack(spacing: 0) {
                List(selection: $draft.selectedID) {
                    ForEach(draft.items) { item in
                        SpeakerReviewListRow(
                            item: item,
                            name: draft.edits[item.id]?.name ?? item.proposedName,
                            reviewed: draft.reviewedIDs.contains(item.id)
                        )
                        .tag(item.id)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 210)
                .accessibilityLabel("Detected speakers")
                Divider()
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
            Divider()
            SpeakerReviewFooter(reviewedCount: draft.reviewedIDs.count, speakerCount: draft.items.count,
                                canConfirm: !draft.items.isEmpty && !libraryLoading,
                                onConfirm: onConfirm, onCancel: onCancel)
        }
        .onChange(of: draft.selectedID) { _, _ in
            draft.clearInput()
            samplePlayer.stop()
        }
    }
}

private struct SpeakerReviewHeader: View {
    let meetingTitle: String?
    let attendeeCount: Int
    let beforeAnalysis: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Who’s speaking?").font(.title2.weight(.semibold))
            Text(beforeAnalysis ? "Name the voices before continuing with analysis." : "Choose who each voice belongs to.")
                .foregroundStyle(.secondary)
            if let meetingTitle {
                Label("\(meetingTitle) · \(attendeeCount) attendees", systemImage: "calendar")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(meetingTitle)
                    .padding(.top, 5)
            } else if attendeeCount > 0 {
                Label("\(attendeeCount) meeting participants", systemImage: "person.2")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 5)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }
}

private struct SpeakerReviewListRow: View {
    let item: SpeakerReviewItem
    let name: String
    let reviewed: Bool

    var body: some View {
        HStack(spacing: 10) {
            SpeakerReviewAvatar(name: name, named: name != item.id, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if reviewed {
                Image(systemName: "checkmark").font(.caption.weight(.semibold))
                    .accessibilityLabel("Reviewed")
            }
        }
        .padding(.vertical, 8)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(draft.edits[item.id]?.name ?? item.proposedName)
                    .font(.title3.weight(.semibold)).lineLimit(2)
                Text("Choose who this voice belongs to.").foregroundStyle(.secondary)
                SpeakerReviewVoiceSample(item: item, url: masterAudioURL, player: samplePlayer)
                    .padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Search meeting & library").font(.callout.weight(.medium))
                TextField("Find a person…", text: $draft.search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search meeting and library")
                    .controlSize(.large)
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
            Divider()
            SpeakerReviewManualName(name: $draft.manualName,
                                    canApply: !draft.trimmedManualName.isEmpty,
                                    onApply: draft.useManualName)
            Button("Keep as \(item.id)", action: draft.keepUnnamed)
                .buttonStyle(.link)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.bottom, 3)
            if loading {
                ProgressView("Loading library…").controlSize(.small)
            } else if choices.isEmpty {
                Text(emptyMessage).font(.callout).foregroundStyle(.secondary)
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

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                SpeakerReviewAvatar(name: choice.name, named: false, size: 25)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.name).font(.callout).multilineTextAlignment(.leading)
                    if let detail = choice.detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 2)
                Image(systemName: selected ? "checkmark" : "plus")
                    .font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enter a name manually").font(.callout.weight(.medium))
            HStack(spacing: 8) {
                TextField("e.g. Alex de Jong", text: $name)
                    .textFieldStyle(.roundedBorder).controlSize(.large)
                    .accessibilityLabel("Enter a name manually")
                    .onSubmit(onApply)
                Button("Use name", action: onApply).disabled(!canApply)
            }
            Text("No meeting or library match needed.").font(.caption).foregroundStyle(.secondary)
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
            .controlSize(.small)
        } else {
            Label("Voice sample unavailable", systemImage: "waveform.slash")
                .font(.caption).foregroundStyle(.secondary)
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
            Text("\(reviewedCount) of \(speakerCount) reviewed").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Confirm speakers", action: onConfirm)
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
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

    var body: some View {
        Text(Theme.initials(for: name))
            .font(.system(size: size / 3, weight: .semibold))
            .foregroundStyle(named ? Color.accentColor : Color.secondary)
            .frame(width: size, height: size)
            .background(named ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.08), in: Circle())
            .accessibilityHidden(true)
    }
}
