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
                                speakerCount: draft.items.count,
                                beforeAnalysis: beforeAnalysis)
            MenuPanelHairline()
            HStack(spacing: 0) {
                // One voice needs no list to choose from.
                if draft.items.count > 1 {
                    speakerList
                    Rectangle().fill(palette.divider.color).frame(width: 1)
                }
                if let item = draft.selectedItem {
                    SpeakerReviewPicker(
                        draft: draft, item: item,
                        meetingChoices: SpeakerReviewCandidates.meetingChoices(
                            names: meetingNames, library: library, search: draft.search,
                            clusterEmbedding: item.clusterEmbedding),
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
                                // Return belongs to the name field while it holds text.
                                returnConfirms: draft.trimmedSearch.isEmpty,
                                onConfirm: onConfirm, onCancel: onCancel)
        }
        .background {
            // ⌘↑ / ⌘↓ step through the voices from anywhere, including the name field.
            Group {
                Button("Previous speaker") { draft.moveSelection(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Next speaker") { draft.moveSelection(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onChange(of: draft.selectedID) { _, _ in
            draft.clearInput()
            samplePlayer.stop()
        }
    }

    /// The detected voices, styled like the library sidebar.
    private var speakerList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Voices").uiFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.secondary.color)
                    .padding(.horizontal, 8).padding(.bottom, 2)
                ForEach(draft.items) { item in
                    Button { draft.selectSpeaker(item.id) } label: {
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
        .help("⌘↑ and ⌘↓ move between voices")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Detected speakers")
    }
}

/// The one-line state of a voice, shared by the list row and the picker header.
private enum SpeakerReviewStatus {
    static func text(item: SpeakerReviewItem, name: String, reviewed: Bool) -> String {
        if reviewed { return name == item.id ? "Kept unnamed" : "Named" }
        if name != item.id {
            return item.reason == .matched ? "Suggested · \(Int(item.confidence * 100))% voice match" : "Suggested name"
        }
        return "Needs a name"
    }
}

private struct SpeakerReviewHeader: View {
    let meetingTitle: String?
    let attendeeCount: Int
    let speakerCount: Int
    let beforeAnalysis: Bool

    var body: some View {
        PanelWindowHeader(
            title: speakerCount == 1 ? "Who’s this voice?" : "Who’s speaking?",
            subtitle: beforeAnalysis
                ? "Name \(speakerCount == 1 ? "the voice" : "the \(speakerCount) voices") before the analysis continues."
                : "Choose who each voice belongs to.",
            detail: meetingTitle.map { "\($0) · \(attendeeCount) attendee\(attendeeCount == 1 ? "" : "s")" }
                ?? (attendeeCount > 0 ? "\(attendeeCount) meeting participant\(attendeeCount == 1 ? "" : "s")" : nil)
        )
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
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
                Text(status).uiFont(.system(size: 11)).foregroundStyle(palette.secondary.color).lineLimit(1)
            }
            Spacer(minLength: 0)
            if reviewed {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
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
        let text = SpeakerReviewStatus.text(item: item, name: name, reviewed: reviewed)
        // The sidebar is narrow; the percentage alone says enough there.
        return text.replacingOccurrences(of: " voice match", with: "")
    }
}

/// One row of the picker's list: a person to choose, or the typed text as a new name.
private enum SpeakerReviewRow: Identifiable {
    case person(SpeakerReviewCandidates.Choice)
    case typed(String)

    var id: String {
        switch self {
        case .person(let choice): choice.id
        case .typed: "typed"
        }
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
    @FocusState private var fieldFocused: Bool
    @State private var highlighted = 0

    private var name: String { draft.edits[item.id]?.name ?? item.proposedName }
    private var meetingIDs: Set<String> { Set(meetingChoices.map(\.id)) }

    /// Every selectable row in display order, so ↑/↓ and Return walk the same list the user sees.
    private var rows: [SpeakerReviewRow] {
        let people = SpeakerReviewCandidates.combined(meeting: meetingChoices, library: libraryChoices)
        let typed = draft.trimmedSearch
        return people.map(SpeakerReviewRow.person)
            + (SpeakerReviewCandidates.offersTypedName(typed, among: people) ? [.typed(typed)] : [])
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 14) {
            identity
            TextField(hasLibraryPeople || hasMeetingNames ? "Type a name, or search people…" : "Type a name…",
                      text: $draft.search)
                .panelTextField()
                .focused($fieldFocused)
                .accessibilityLabel("Name for \(item.id)")
                .accessibilityHint("Type to search people or enter a new name")
                .onSubmit { choose(rows.indices.contains(highlighted) ? rows[highlighted] : nil) }
                .onKeyPress(.downArrow) { moveHighlight(by: 1, in: rows); return .handled }
                .onKeyPress(.upArrow) { moveHighlight(by: -1, in: rows); return .handled }
                .onChange(of: draft.search) { _, _ in highlighted = 0 }
            ScrollViewReader { proxy in
                ScrollView {
                    list(rows)
                }
                .overlayScrollers()
                .onChange(of: highlighted) { _, index in
                    guard rows.indices.contains(index) else { return }
                    proxy.scrollTo(rows[index].id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            MenuPanelHairline()
            HStack(spacing: 12) {
                Text(rows.isEmpty ? "Return confirms all voices" : "↑↓ to choose · Return to assign · ⌘↓ next voice")
                    .uiFont(.system(size: 11)).foregroundStyle(palette.secondary.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Keep as \(item.id)", action: draft.keepUnnamed)
                    .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 26, fontSize: 11, fillsWidth: false))
                    .help("Leave this voice unnamed and keep its speaker label.")
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { fieldFocused = true }
    }

    /// Who this voice is now, how sure dBrief is, and what they said — so it can be placed without listening.
    private var identity: some View {
        HStack(alignment: .top, spacing: 14) {
            SpeakerReviewAvatar(name: name, named: name != item.id, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).uiFont(.system(size: 16, weight: .semibold)).lineLimit(2)
                    .foregroundStyle(palette.heading.color)
                Text(SpeakerReviewStatus.text(item: item, name: name, reviewed: draft.reviewedIDs.contains(item.id)))
                    .uiFont(.system(size: 12)).foregroundStyle(palette.secondary.color)
                if let quote = item.quote {
                    Text("“\(quote)”")
                        .uiFont(.system(size: 12).italic())
                        .foregroundStyle(palette.text.color)
                        .lineLimit(2)
                        .padding(.top, 2)
                        .help(quote)
                        .accessibilityLabel("They said: \(quote)")
                }
            }
            Spacer(minLength: 8)
            SpeakerReviewVoiceSample(item: item, url: masterAudioURL, player: samplePlayer)
        }
    }

    @ViewBuilder
    private func list(_ rows: [SpeakerReviewRow]) -> some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            if libraryLoading {
                ProgressView("Loading library…").controlSize(.small).padding(.vertical, 6)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if let title = sectionTitle(at: index, in: rows) {
                    Text(title).uiFont(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.secondary.color)
                        .padding(.horizontal, 8).padding(.top, index == 0 ? 0 : 10).padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                }
                switch row {
                case .person(let choice):
                    SpeakerReviewPersonRow(choice: choice, selected: isSelected(choice),
                                           highlighted: index == highlighted) { choose(row) }
                        .id(row.id)
                case .typed(let typed):
                    SpeakerReviewTypedRow(name: typed, highlighted: index == highlighted) { choose(row) }
                        .id(row.id)
                }
            }
            if rows.isEmpty, !libraryLoading {
                Text(emptyMessage).uiFont(.system(size: 12)).foregroundStyle(palette.secondary.color)
                    .padding(.horizontal, 8).padding(.vertical, 6)
            }
        }
        .padding(.trailing, 4)
    }

    private func sectionTitle(at index: Int, in rows: [SpeakerReviewRow]) -> String? {
        func section(_ row: SpeakerReviewRow) -> String {
            switch row {
            case .person(let choice): meetingIDs.contains(choice.id) ? "In this meeting" : "Voice library"
            case .typed: "New name"
            }
        }
        let current = section(rows[index])
        return index == 0 || section(rows[index - 1]) != current ? current : nil
    }

    private var emptyMessage: String {
        if !draft.trimmedSearch.isEmpty { return "No matching people." }
        return "No attendees or saved voices yet — type this person’s name above."
    }

    private func moveHighlight(by offset: Int, in rows: [SpeakerReviewRow]) {
        guard !rows.isEmpty else { return }
        highlighted = min(max(highlighted + offset, 0), rows.count - 1)
    }

    private func choose(_ row: SpeakerReviewRow?) {
        switch row {
        case .person(let choice): draft.assign(choice)
        case .typed: draft.useTypedName()
        case nil: return
        }
    }

    private func isSelected(_ choice: SpeakerReviewCandidates.Choice) -> Bool {
        let current = draft.edits[item.id]
        if let personId = choice.personId { return current?.personId == personId }
        return current?.name.caseInsensitiveCompare(choice.name) == .orderedSame
    }
}

private struct SpeakerReviewPersonRow: View {
    let choice: SpeakerReviewCandidates.Choice
    let selected: Bool
    let highlighted: Bool
    let onSelect: () -> Void
    @Environment(\.viewerPalette) private var palette
    @State private var hovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                SpeakerReviewAvatar(name: choice.name, named: selected, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.name).uiFont(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.heading.color)
                        .multilineTextAlignment(.leading)
                    if let detail = choice.detail, !detail.isEmpty {
                        Text(detail).uiFont(.system(size: 11)).foregroundStyle(palette.secondary.color).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if let score = choice.score, score >= SpeakerReviewCandidates.visibleScore {
                    SpeakerReviewMatchBadge(score: score)
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.accentText.color)
                        .frame(width: 14)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? palette.selected.color : (hovered || highlighted) ? palette.canvas.color : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                if highlighted && !selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(palette.divider.color, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .onHover { hovered = $0 }
        .buttonStyle(.plain)
        .help(choice.detail.map { "\(choice.name) · \($0)" } ?? choice.name)
        .accessibilityLabel(choice.detail.flatMap { $0.isEmpty ? nil : "Use \(choice.name), \($0)" } ?? "Use \(choice.name)")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if selected { parts.append("Selected") }
        if let score = choice.score, score >= SpeakerReviewCandidates.visibleScore {
            parts.append("\(Int(score * 100)) percent voice match")
        }
        return parts.joined(separator: ", ")
    }
}

/// How closely a known voice resembles this speaker; strong only at the level auto-recognition trusts.
private struct SpeakerReviewMatchBadge: View {
    let score: Float
    @Environment(\.viewerPalette) private var palette

    private var strong: Bool { score >= VoiceIdentityResolver.defaultMinConfidence }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "waveform").font(.system(size: 9, weight: .semibold))
            Text("\(Int(score * 100))%").uiFont(.system(size: 10, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(strong ? palette.accentText.color : palette.secondary.color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(strong ? palette.selected.color : .clear, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.divider.color, lineWidth: strong ? 0 : 1))
        .help(strong ? "Strong voice match" : "Possible voice match")
        .accessibilityHidden(true)
    }
}

private struct SpeakerReviewTypedRow: View {
    let name: String
    let highlighted: Bool
    let onSelect: () -> Void
    @Environment(\.viewerPalette) private var palette
    @State private var hovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.accentText.color)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(palette.divider.color, lineWidth: 1))
                Text("Use “\(name)”").uiFont(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.heading.color).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((hovered || highlighted) ? palette.canvas.color : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                if highlighted {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(palette.divider.color, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .onHover { hovered = $0 }
        .buttonStyle(.plain)
        .accessibilityLabel("Use \(name) as a new name")
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
                Label(playing ? "Stop" : "Play \(Int((snippet.end - snippet.start).rounded())) s",
                      systemImage: playing ? "stop.fill" : "play.fill")
            }
            .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 28, fontSize: 11, fillsWidth: false))
            .keyboardShortcut(.space, modifiers: .option)
            .help(playing ? "Stop the voice sample (⌥Space)" : "Play a sample of this voice (⌥Space)")
            .accessibilityLabel(playing ? "Stop voice sample" : "Play voice sample")
        } else {
            Label("No sample", systemImage: "waveform.slash")
                .uiFont(.system(size: 11)).foregroundStyle(.secondary)
                .help("No clear stretch of this voice to play.")
        }
    }
}

private struct SpeakerReviewFooter: View {
    let reviewedCount: Int
    let speakerCount: Int
    let canConfirm: Bool
    let returnConfirms: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @Environment(\.menuPanelPalette) private var panelStatus

    var body: some View {
        HStack(spacing: 12) {
            Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                .buttonStyle(MenuPanelButtonStyle(kind: .secondary, fillsWidth: false))
            progress
            Spacer()
            Button(speakerCount == 1 ? "Confirm speaker" : "Confirm speakers", action: onConfirm)
                .buttonStyle(MenuPanelButtonStyle(kind: .hero, height: 30, fontSize: 12, fillsWidth: false))
                .keyboardShortcut(returnConfirms ? .defaultAction : nil)
                .disabled(!canConfirm)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var progress: some View {
        if speakerCount > 0, reviewedCount == speakerCount {
            Label("All voices reviewed", systemImage: "checkmark.circle.fill")
                .uiFont(.system(size: 11))
                .foregroundStyle(panelStatus.success.color)
        } else if speakerCount > 1 {
            Text("\(reviewedCount) of \(speakerCount) reviewed").uiFont(.system(size: 11)).foregroundStyle(.secondary)
                .help("Voices you skip keep the name shown in the list.")
        }
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
