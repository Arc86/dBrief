import SwiftUI
import AppKit
import OSLog
import dBriefWire

/// Right-hand detail pane of the recording viewer. A calm shared document header
/// sits above one of three views — Summary, Transcript, or Chat — switched from
/// the toolbar. The active view is data-driven on open: Summary when a summary
/// exists, otherwise Transcript.
struct TranscriptDetailView: View {
    let recording: Recording
    /// Called after the recording's files are deleted, so the browser can drop
    /// it from the sidebar and clear selection.
    var onDeleted: () -> Void = {}

    @Environment(AppContext.self) private var context
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(TranscriptChatStore.self) private var chatStore
    @Environment(\.colorScheme) private var colorScheme

    // Persisted display preferences
    @AppStorage("transcriptFontSize") private var fontSize: Int = 16
    @AppStorage("showSpeakerNames") private var showSpeakerNames: Bool = true

    /// Which of the two views is showing.
    private enum ViewerMode { case transcript, chat }
    @State private var mode: ViewerMode = .transcript

    /// Whether the AI Analysis inspector panel is open.
    @AppStorage("showTranscriptInspector") private var showInspector: Bool = false

    /// In live mode, chat is a right-hand side panel (so the in-progress transcript
    /// stays visible) rather than a full-screen swap like the finished-recording view.
    @State private var showLiveChat = false

    @State private var richTranscript: RichTranscript?
    @State private var loadFailed = false
    @State private var currentTime: TimeInterval = 0
    @State private var chatService: TranscriptChatService?
    @State private var insights: RecordingInsights?
    @State private var copied = false
    @State private var showDeleteConfirm = false
    @State private var isGenerating = false

    // Transcript search (finished-recording transcript only)
    @State private var searchQuery = ""
    @State private var isSearchPresented = false
    @State private var searchResult = TranscriptSearch.Result.empty
    @State private var matchesByTurn: [UUID: [TranscriptSearch.Match]] = [:]
    @State private var currentMatchIndex = 0
    @State private var searchDebounce: Task<Void, Never>?
    /// Bumped to ask the transcript `ScrollViewReader` to scroll to the current match.
    @State private var searchScrollTick = 0

    // Speaker reassignment
    @State private var customRenameTurn: SpeakerTurn?

    // Diarization (after-the-fact speaker detection)
    @State private var isDiarizing = false
    @State private var showDiarizeConfirm = false
    @State private var diarizeError: String?

    // Voice library (Phase 2): known-people names offered as rename candidates,
    // and a normalized-name → personId map to link a label on rename.
    @State private var knownPeopleNames: [String] = []
    @State private var knownPersonIds: [String: String] = [:]
    @State private var embeddedSpeakerIds: Set<String> = []
    @State private var enrolledSpeakerIds: Set<String> = []
    // Phase 3: after a rename changes who-said-what, offer to regenerate analysis.
    @State private var offerReanalysis = false

    private var displayedTurns: [SpeakerTurn] {
        richTranscript?.speakerTurns() ?? []
    }

    private var uniqueSpeakerIds: [String] {
        guard let t = richTranscript else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for seg in t.segments {
            if let id = seg.speakerId, !seen.contains(id) {
                seen.insert(id)
                result.append(id)
            }
        }
        return result
    }

    private var meSpeakerId: String? { richTranscript?.meSpeakerId }

    private var hasSummary: Bool {
        guard let s = insights?.summary else { return false }
        return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True while this view shows the in-progress (recording or processing)
    /// recording — drives the real-time live transcript + chat mode.
    private var isLive: Bool {
        guard let current = context.appState.currentRecording else { return false }
        return current.id == recording.id && context.appState.recordingState != .idle
    }

    /// Live transcript assembled on the fly from the growing `liveTranscriptSegments`.
    private var liveRichTranscript: RichTranscript {
        let segs = context.appState.liveTranscriptSegments.map { seg in
            RichSegment(start: seg.start, end: seg.end, text: seg.text,
                        originalText: seg.text, speakerId: seg.speaker)
        }
        return RichTranscript(segments: segs)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLive {
                // In-progress recording: keep the real-time transcript visible and
                // slide chat in as a right-hand side panel, so you can watch the
                // transcript grow while chatting with it.
                HStack(spacing: 0) {
                    liveTranscriptContent
                        .frame(maxWidth: .infinity)
                    if showLiveChat {
                        Divider()
                        liveChatPanel
                    }
                }
            } else if loadFailed {
                failedState
            } else if richTranscript != nil {
                documentHeader
                Divider()
                if offerReanalysis && mode != .chat { reanalysisBanner }
                switch mode {
                case .transcript: transcriptList
                case .chat:       chatContent
                }
                Divider()
                if let _ = richTranscript, recording.duration > 0 {
                    speakerTimeline
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                }
                playerBar
            } else {
                loadingState
            }
        }
        .navigationTitle(recording.generatedTitle ?? recording.meetingTitleDraft)
        .toolbar { toolbarContent }
        .task { await loadTranscript() }
        .modifier(TranscriptSearchableModifier(
            enabled: !isLive,
            query: $searchQuery,
            isPresented: $isSearchPresented,
            onSubmitSearch: gotoNextMatch))
        .background { if !isLive { findShortcuts } }
        .onChange(of: searchQuery) { _, _ in scheduleSearchRecompute() }
        .onChange(of: isSearchPresented) { _, presented in
            if !presented {
                searchQuery = ""
                searchDebounce?.cancel()
                recomputeSearch()
            }
        }
        .onChange(of: context.appState.recordingState) { _, newState in
            // When the live recording finishes, swap the live preview for the
            // authoritative on-disk transcript. Keep a non-empty live chat and
            // re-point it at that transcript (so the Q&A history carries over);
            // drop an empty one so a fresh chat is built against the final text.
            guard newState == .idle, context.appState.currentRecording?.id == recording.id else { return }
            showLiveChat = false
            let liveChat = chatStore.session(for: recording.fileURL)
            if liveChat?.hasHistory != true {
                chatStore.remove(for: recording.fileURL)
            }
            Task {
                await loadTranscript()
                if let liveChat, liveChat.hasHistory {
                    let text = richTranscript?.segments.map { $0.text }.joined(separator: "\n")
                        ?? recording.transcription?.text ?? ""
                    liveChat.rebindTranscript(text: text, speakerLabels: richTranscript?.speakerLabels ?? [])
                    // The recording is finalized now, so a stable sidecar exists:
                    // bind persistence and flush the carried-over conversation.
                    if let url = recording.chatSidecarURL {
                        liveChat.enablePersistence(store: context.chatStore, url: url)
                        liveChat.persistNow()
                    }
                }
            }
        }
        .onChange(of: context.appState.speakerReviewCommit) { _, commit in
            // A confirm-first re-diarize review committed names for this recording —
            // reload the persisted transcript and offer optional re-analysis.
            guard let commit, commit.recordingID == recording.id else { return }
            Task {
                await loadTranscript()
                recomputeSearch()
                if !showSpeakerNames { showSpeakerNames = true }
                if commit.offerReanalysis && hasSummary { offerReanalysis = true }
            }
        }
        .overlay { if isDiarizing { diarizingOverlay } }
        .inspector(isPresented: $showInspector) {
            SummaryView(
                insights: insights,
                isGenerating: isGenerating,
                canGenerate: richTranscript != nil,
                onGenerate: { Task { await generateSummary() } },
                onSave: { updated in await saveInsights(updated) }
            )
            .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .confirmationDialog("Delete this recording?",
                            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteRecording() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(recording.generatedTitle ?? recording.meetingTitleDraft)” and its audio will be permanently removed.")
        }
        .confirmationDialog("Detect speakers?",
                            isPresented: $showDiarizeConfirm, titleVisibility: .visible) {
            Button("Detect Speakers") { Task { await runDiarization() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runs on-device speaker detection for this recording and assigns speakers to the transcript. This replaces any current speakers and custom names. The first run downloads the speaker model.")
        }
        .alert("Speaker detection failed", isPresented: Binding(
            get: { diarizeError != nil },
            set: { if !$0 { diarizeError = nil } })) {
            Button("OK", role: .cancel) { diarizeError = nil }
        } message: {
            Text(diarizeError ?? "")
        }
    }

    // MARK: - Document header

    private var documentHeader: some View {
        RecordingDocumentHeader(
            title: recording.generatedTitle ?? recording.meetingTitleDraft,
            sentiment: insights?.sentiment,
            speakers: headerSpeakers,
            date: recording.date,
            metrics: headerMetrics
        )
    }

    /// Shown after a speaker rename changes who-said-what: offers to regenerate
    /// the (name-aware) AI analysis. Opt-in — never auto-regenerates.
    private var reanalysisBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.text.rectangle")
                .foregroundStyle(.secondary)
            Text("Speaker names changed — regenerate analysis?")
                .font(.callout)
            Spacer(minLength: 8)
            if isGenerating {
                ProgressView().controlSize(.small)
            } else {
                Button("Regenerate") {
                    offerReanalysis = false
                    Task { await generateSummary() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button {
                    offerReanalysis = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var headerSpeakers: [HeaderSpeaker] {
        // Respect the "Speaker Names" display toggle: when off, the header avatar
        // stack hides too, matching the transcript rows.
        guard showSpeakerNames else { return [] }
        return uniqueSpeakerIds.map { id in
            HeaderSpeaker(id: id, name: displayName(for: id), isMe: id == meSpeakerId)
        }
    }

    /// Borderless metric group, built as a filtered array so dividers are always
    /// correct: a metric appears only when its data exists.
    private var headerMetrics: [ViewerMetric] {
        var metrics: [ViewerMetric] = []
        if let insights, !insights.actionItems.isEmpty {
            metrics.append(ViewerMetric(id: "actions", label: "Actions", value: "\(insights.actionItems.count)"))
        }
        if let insights, !insights.tags.isEmpty {
            metrics.append(ViewerMetric(id: "tags", label: "Tags", value: "\(insights.tags.count)"))
        }
        if recording.duration > 0 {
            metrics.append(ViewerMetric(id: "audio", label: "Audio", value: recording.formattedDuration))
        }
        return metrics
    }

    private var diarizingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("Detecting speakers…")
                    .font(.callout)
                Text("First run downloads the speaker model, which can take a while.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            // Empty: let the window navigation title show in the centre.
            EmptyView()
        }

        ToolbarItem(placement: .primaryAction) {
            if isLive {
                Button {
                    showLiveChat.toggle()
                    if showLiveChat, chatService == nil { buildChatService() }
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .symbolVariant(showLiveChat ? .fill : .none)
                        .foregroundStyle(showLiveChat ? Color.accentColor : Color.secondary)
                }
                .help(showLiveChat ? "Hide chat" : "Chat with the live transcript")
                .accessibilityAddTraits(showLiveChat ? .isSelected : [])
            } else {
                Picker("View", selection: $mode) {
                    Label("Transcript", systemImage: "list.bullet").tag(ViewerMode.transcript)
                    Label("Chat", systemImage: "bubble.left.and.bubble.right").tag(ViewerMode.chat)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: mode) { _, newMode in
                    if newMode == .chat, chatService == nil { buildChatService() }
                }
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if !isLive {
                Button {
                    withAnimation { showInspector.toggle() }
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .symbolVariant(showInspector ? .fill : .none)
                        .foregroundStyle(showInspector ? Color.accentColor : Color.secondary)
                }
                .keyboardShortcut("i", modifiers: .command)
                .help(showInspector ? "Hide Analysis (⌘I)" : "Show Analysis (⌘I)")
                .accessibilityAddTraits(showInspector ? .isSelected : [])

                Menu {
                    if let path = insights?.markdownPath,
                       FileManager.default.fileExists(atPath: path) {
                        ShareLink("Share Markdown Note",
                                  item: URL(fileURLWithPath: path),
                                  preview: SharePreview(
                                      recording.generatedTitle ?? recording.meetingTitleDraft,
                                      image: Image(systemName: "doc.text")))
                    }
                    if let audioURL = recording.finalizedAudioURL {
                        ShareLink("Share Audio",
                                  item: audioURL,
                                  preview: SharePreview(
                                      recording.generatedTitle ?? recording.meetingTitleDraft,
                                      image: Image(systemName: "waveform")))
                    }
                    Divider()
                    Button("Copy Transcript") { copyTranscript() }
                        .disabled(richTranscript == nil)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Share")
                .disabled(richTranscript == nil && recording.finalizedAudioURL == nil)
            }

            Button {
                copyTranscript()
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? Color.green : Color.secondary)
            }
            .disabled(richTranscript == nil)
            .help("Copy full transcript")

            Button {
                showDiarizeConfirm = true
            } label: {
                Image(systemName: "person.2.wave.2")
                    .foregroundStyle(Color.secondary)
            }
            .disabled(isDiarizing || richTranscript == nil || recording.finalizedAudioURL == nil)
            .help("Detect speakers")

            Menu {
                Stepper(value: $fontSize, in: 12...24) {
                    Text("Font Size: \(fontSize) pt")
                }
                Toggle("Speaker Names", isOn: $showSpeakerNames)
            } label: {
                Image(systemName: "textformat.size")
            }
            .help("Display options")

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete recording")

            // Search match counter + prev/next, kept adjacent to the trailing
            // `.searchable` field (which the system pins to the toolbar's edge).
            if isSearching {
                Divider()
                Text(searchCounterLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Search matches")
                Button { gotoPrevMatch() } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(searchResult.matches.isEmpty)
                .help("Previous match (⌘⇧G)")
                Button { gotoNextMatch() } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(searchResult.matches.isEmpty)
                .help("Next match (⌘G)")
            }
        }
    }

    // MARK: - Transcript

    private var speakerTimeline: some View {
        SpeakerTimelineView(
            segments: richTranscript?.segments ?? [],
            duration: recording.duration,
            currentTime: currentTime,
            onSeek: { time in seek(to: time) }
        )
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(displayedTurns) { turn in
                    transcriptRow(turn)
                        .listRowBackground(rowBackground(turn))
                        .id(turn.id)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .onChange(of: audioPlayer.currentTime) { _, newTime in
                currentTime = newTime
                guard let active = displayedTurns.first(where: {
                    newTime >= $0.startTime && newTime < $0.endTime
                }) else { return }
                withAnimation { proxy.scrollTo(active.id, anchor: .center) }
            }
            .onChange(of: searchScrollTick) { _, _ in
                guard searchResult.matches.indices.contains(currentMatchIndex) else { return }
                let turnId = searchResult.matches[currentMatchIndex].turnId
                withAnimation { proxy.scrollTo(turnId, anchor: .center) }
            }
        }
    }

    private func rowBackground(_ turn: SpeakerTurn) -> Color {
        if isTurnActive(turn) { return Color.accentColor.opacity(0.14) }
        if turn.speakerId != nil, turn.speakerId == meSpeakerId {
            return Color.accentColor.opacity(0.05)
        }
        return Color.clear
    }

    @ViewBuilder
    private func transcriptRow(_ turn: SpeakerTurn) -> some View {
        let isMe = turn.speakerId != nil && turn.speakerId == meSpeakerId
        let railColor = isMe ? Color.accentColor : TranscriptDesignTokens.speakerColor(for: turn.speakerId)
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(railColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if showSpeakerNames, turn.speakerId != nil {
                        speakerLabel(turn: turn, isMe: isMe)
                    }
                    Button {
                        seek(to: turn.startTime)
                    } label: {
                        Text(timecode(turn.startTime))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(TranscriptDesignTokens.timestampText(scheme: colorScheme))
                    }
                    .buttonStyle(.plain)
                    .help("Jump to this point")
                }
                Text(highlightedText(turn))
                    .font(.system(size: CGFloat(fontSize)))
                    .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: colorScheme))
                    .lineSpacing(CGFloat(fontSize) * 0.4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { seek(to: turn.startTime) }
    }

    private func speakerLabel(turn: SpeakerTurn, isMe: Bool) -> some View {
        let id = turn.speakerId ?? ""
        return Menu {
            speakerMenuContent(turn: turn, isMe: isMe)
        } label: {
            HStack(spacing: 4) {
                Text(displayName(for: id))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isMe ? Color.accentColor : TranscriptDesignTokens.speakerColor(for: id))
                if isMe {
                    Text("· You")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        // The "Custom name…" typing fallback. Each turn's label carries the popover, but
        // `customRenameTurn` is single-valued and `SpeakerTurn.id` is stable, so exactly one
        // label's binding is ever true — only the tapped badge presents.
        .popover(isPresented: Binding(
            get: { customRenameTurn?.id == turn.id },
            set: { if !$0 { customRenameTurn = nil } }
        ), arrowEdge: .bottom) {
            SpeakerRenamePopover(currentName: displayName(for: id)) { newName in
                renameSpeaker(turn: turn, to: newName)
            }
        }
    }

    /// Selection-based speaker actions, split into Rename / Move / This-is-me. Candidates are
    /// computed lazily here (only when the menu opens), not per row render.
    @ViewBuilder
    private func speakerMenuContent(turn: SpeakerTurn, isMe: Bool) -> some View {
        let transcript = richTranscript ?? RichTranscript(segments: [])
        let attendees = recording.calendarCandidates.flatMap { $0.attendees.map(\.name) }
        let cands = SpeakerReassignment.candidates(
            in: transcript,
            currentSpeakerId: turn.speakerId,
            participants: recording.participants,
            calendarAttendees: attendees,
            knownPeople: knownPeopleNames)
        // Names to rename to: known people + other speakers (picking another speaker swaps).
        let renameNames = cands.filter { !$0.isCurrent }.map(\.displayName)
        // Move targets: the other existing speakers.
        let others = cands.compactMap { c -> SpeakerMoveTarget? in
            guard let sid = c.existingSpeakerId, !c.isCurrent else { return nil }
            return SpeakerMoveTarget(id: sid, displayName: c.displayName)
        }
        let segCount = SpeakerReassignment.segmentCount(in: transcript, speakerId: turn.speakerId)
        let hasSegmentsBeyondTurn = segCount > turn.segments.count

        // Rename
        if renameNames.isEmpty {
            Button("Rename…") { customRenameTurn = turn }
        } else {
            Menu("Rename to") {
                ForEach(renameNames, id: \.self) { name in
                    Button(name) { renameSpeaker(turn: turn, to: name) }
                }
                Divider()
                Button("Custom name…") { customRenameTurn = turn }
            }
        }

        // Reassign (move segments to another existing speaker)
        if !others.isEmpty {
            Menu(hasSegmentsBeyondTurn ? "Move this turn to" : "Move to") {
                ForEach(others) { t in
                    Button(t.displayName) {
                        reassignTurn(turn: turn, toSpeakerId: t.id, scope: .theseSegments)
                    }
                }
            }
            if hasSegmentsBeyondTurn {
                Menu("Move all “\(displayName(for: turn.speakerId ?? ""))” to") {
                    ForEach(others) { t in
                        Button(t.displayName) {
                            reassignTurn(turn: turn, toSpeakerId: t.id, scope: .allOfSpeaker)
                        }
                    }
                }
            }
        }

        // Save voice to library (explicit enrollment — surfaces the growth loop
        // for an already-named speaker without renaming).
        let sid = turn.speakerId ?? ""
        let speakerName = displayName(for: sid)
        if VoiceLibraryDisplay.canEnroll(displayName: speakerName, speakerId: sid,
                                         hasEmbedding: embeddedSpeakerIds.contains(sid),
                                         alreadyEnrolled: enrolledSpeakerIds.contains(sid)) {
            Divider()
            Button("Save “\(speakerName)” voice to library") { saveVoice(turn: turn, name: speakerName) }
        }

        Divider()
        if isMe {
            Button("Clear “This is me”") { setMeSpeaker(nil) }
        } else {
            Button("This is me") { setMeSpeaker(turn.speakerId) }
        }
    }

    private func displayName(for id: String) -> String {
        richTranscript?.speakerLabels.first(where: { $0.id == id })?.displayName ?? id
    }

    private func timecode(_ time: TimeInterval) -> String {
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Player

    @ViewBuilder
    private var playerBar: some View {
        Group {
            if let audioURL = recording.finalizedAudioURL {
                TranscriptPlayerBar(audioURL: audioURL, currentTime: $currentTime)
            } else {
                Text("Audio file not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            if #available(macOS 26, *) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.regularMaterial)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(TranscriptDesignTokens.structureFill(scheme: colorScheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(TranscriptDesignTokens.structureBorder(scheme: colorScheme), lineWidth: 0.5)
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Chat

    @ViewBuilder
    private var chatContent: some View {
        if let chatService {
            TranscriptChatView(chatService: chatService)
        } else {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                Text("Preparing chat…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { buildChatService() }
        }
    }

    // MARK: - Live transcript

    /// Chat as a right-hand side panel during live recording — reuses `chatContent`
    /// (so it runs against the live transcript provider) inside a fixed-width column
    /// with its own header + close button, keeping the live transcript visible.
    private var liveChatPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(.secondary)
                Text("Chat")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showLiveChat = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide chat")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()
            chatContent
        }
        .frame(width: 360)
    }

    @ViewBuilder
    private var liveTranscriptContent: some View {
        VStack(spacing: 0) {
            liveStatusBanner
            Divider()
            liveTranscriptList
        }
    }

    private var liveStatusBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(context.appState.recordingState == .processing ? Color.orange : Color.red)
                .frame(width: 9, height: 9)
            Text(context.appState.recordingState == .processing ? "Processing…" : "Recording — live transcript")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(context.appState.liveTranscriptSegments.count) segments")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var liveTranscriptList: some View {
        let turns = liveRichTranscript.speakerTurns()
        let mic = context.appState.liveVolatileMic
        let system = context.appState.liveVolatileSystem
        if turns.isEmpty && mic.isEmpty && system.isEmpty {
            liveWaitingState
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(turns) { turn in
                        liveTurnRow(turn).id(turn.id)
                    }
                    if !mic.isEmpty {
                        liveVolatileRow(speaker: "You", text: mic).id("vol-mic")
                    }
                    if !system.isEmpty {
                        liveVolatileRow(speaker: "Participant", text: system).id("vol-system")
                    }
                    Color.clear.frame(height: 1).id("live-bottom")
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onChange(of: context.appState.liveTranscriptSegments.count) { _, _ in
                    withAnimation { proxy.scrollTo("live-bottom", anchor: .bottom) }
                }
            }
        }
    }

    private var liveWaitingState: some View {
        // Surface live status (e.g. "Preparing language…" while a first-run speech
        // asset downloads) when present; otherwise the default listening/preparing copy.
        let status = context.appState.liveStatusMessage
        let headline = !status.isEmpty
            ? status
            : (context.appState.isLiveTranscribing ? "Listening…" : "Preparing live transcription…")
        return VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text(headline)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Spoken words appear here as you record.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func liveTurnRow(_ turn: SpeakerTurn) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if showSpeakerNames, let id = turn.speakerId {
                Text(id)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TranscriptDesignTokens.speakerColor(for: id))
            }
            Text(turn.text)
                .font(.system(size: CGFloat(fontSize)))
                .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: colorScheme))
                .lineSpacing(CGFloat(fontSize) * 0.4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private func liveVolatileRow(speaker: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if showSpeakerNames {
                Text(speaker)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TranscriptDesignTokens.speakerColor(for: speaker))
            }
            Text(text)
                .font(.system(size: CGFloat(fontSize)).italic())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .opacity(0.6)
    }

    // MARK: - Placeholder states

    private var loadingState: some View {
        VStack {
            Spacer()
            ProgressView("Loading transcript…")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var failedState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("Transcript unavailable")
                .foregroundStyle(.secondary)
            Button("Rebuild") { rebuildTranscript() }
                .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Speaker assignment

    /// Rename the whole speaker (swap on name collision — see `SpeakerReassignment.rename`).
    private func renameSpeaker(turn: SpeakerTurn, to newName: String) {
        customRenameTurn = nil
        guard var transcript = richTranscript, let id = turn.speakerId else { return }
        // Link to a voice-library person when the chosen name is already known.
        let knownId = knownPersonIds[newName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
        transcript = SpeakerReassignment.rename(transcript, speakerId: id, to: newName, personId: knownId)
        richTranscript = transcript
        saveTranscript(transcript)
        recomputeSearch()
        // Growth loop (Phase 3): enroll this speaker's voiceprint, then link the
        // resulting (new or existing) library person id onto the label.
        Task {
            guard let personId = await context.recordingManager
                .enrollVoiceprintOnRename(recording: recording, speakerId: id, name: newName) else {
                if hasSummary { offerReanalysis = true }
                return
            }
            await loadKnownPeople()   // refresh rename candidates + name→id map
            if var t = richTranscript,
               let i = t.speakerLabels.firstIndex(where: { $0.id == id }),
               t.speakerLabels[i].personId != personId {
                t.speakerLabels[i].personId = personId
                richTranscript = t
                saveTranscript(t)
            }
            if hasSummary { offerReanalysis = true }
        }
    }

    /// Explicitly bank the speaker's voiceprint under their current display name,
    /// then link the resulting library person id onto the label. Reuses the same
    /// enrollment path as rename; no-op (and the menu item is hidden) when no
    /// embedding is available.
    private func saveVoice(turn: SpeakerTurn, name: String) {
        guard let id = turn.speakerId else { return }
        Task {
            guard let personId = await context.recordingManager
                .enrollVoiceprintOnRename(recording: recording, speakerId: id, name: name) else { return }
            enrolledSpeakerIds.insert(id)
            await loadKnownPeople()
            if var t = richTranscript,
               let i = t.speakerLabels.firstIndex(where: { $0.id == id }),
               t.speakerLabels[i].personId != personId {
                t.speakerLabels[i].personId = personId
                richTranscript = t
                saveTranscript(t)
            }
        }
    }

    /// Move this turn (or all of the speaker's segments) to another existing speaker.
    private func reassignTurn(turn: SpeakerTurn, toSpeakerId: String, scope: ReassignScope) {
        guard var transcript = richTranscript else { return }
        let ids = Set(turn.segments.map(\.id))
        transcript = SpeakerReassignment.apply(.existing(speakerId: toSpeakerId), to: transcript,
                                               segmentIds: ids, scope: scope, newId: "")
        richTranscript = transcript
        saveTranscript(transcript)
        recomputeSearch()
    }

    // MARK: - Actions

    private func isTurnActive(_ turn: SpeakerTurn) -> Bool {
        currentTime >= turn.startTime && currentTime < turn.endTime
    }

    private func seek(to time: TimeInterval) {
        guard let audioURL = recording.finalizedAudioURL else { return }
        if audioPlayer.currentFileURL != audioURL { audioPlayer.play(url: audioURL) }
        audioPlayer.seek(to: time)
    }

    private func setMeSpeaker(_ id: String?) {
        guard var transcript = richTranscript else { return }
        transcript.meSpeakerId = id
        richTranscript = transcript
        saveTranscript(transcript)
    }

    private func runDiarization() async {
        guard let audioURL = recording.finalizedAudioURL,
              let transcript = richTranscript else { return }
        isDiarizing = true
        defer { isDiarizing = false }
        do {
            // Confirm-first: resolve the new clusters against the voice library and
            // hold for review before committing names (mirrors the fresh-transcription
            // pipeline). Optimistic mode keeps the silent assign below.
            if context.appSettings.speakerIdMode == .confirmFirst {
                let (turns, embeddings) = try await context.recordingManager.localPlugin
                    .diarizeWithEmbeddings(fileURL: audioURL)
                guard !turns.isEmpty else {
                    diarizeError = "No speakers were detected in this recording."
                    return
                }
                // When a hold is armed the review window owns the commit; the viewer
                // reloads via `speakerReviewCommit`. Otherwise fall through to assign.
                if await context.recordingManager.presentReDiarizeReview(
                    recording: recording, turns: turns,
                    embeddings: embeddings, baseTranscript: transcript) {
                    return
                }
                applyDiarization(turns, to: transcript)
                return
            }

            let turns = try await context.recordingManager.localPlugin.diarize(fileURL: audioURL)
            guard !turns.isEmpty else {
                diarizeError = "No speakers were detected in this recording."
                return
            }
            applyDiarization(turns, to: transcript)
        } catch {
            diarizeError = error.localizedDescription
        }
    }

    /// Silent (optimistic) commit of a re-diarization onto the viewer's transcript.
    private func applyDiarization(_ turns: [DiarizedTurn], to transcript: RichTranscript) {
        let updated = SpeakerAssigner.assign(turns, to: transcript)
        richTranscript = updated
        recomputeSearch()
        if !showSpeakerNames { showSpeakerNames = true }
        saveTranscript(updated)
    }

    /// Re-runs the AI pipeline for this recording, then reloads the new insights.
    private func generateSummary() async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }
        await context.recordingManager.retryAIAnalysis(for: recording)
        await loadInsights()
        if hasSummary { showInspector = true }
    }

    private func copyTranscript() {
        guard let transcript = richTranscript else { return }
        let text = transcript.segments.map { $0.text }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func buildChatService() {
        // Reuse an existing session for this recording so the conversation
        // survives switching recordings and coming back.
        if let existing = chatStore.session(for: recording.fileURL) {
            chatService = existing
            return
        }
        let labels = richTranscript?.speakerLabels ?? []
        let service: TranscriptChatService
        if isLive {
            // Chat against the live, growing transcript: the provider re-reads the
            // current segments + volatile lines on each send().
            let appState = context.appState
            service = TranscriptChatService(
                transcriptProvider: { Self.liveTranscriptText(appState: appState) },
                speakerLabels: labels,
                appSettings: context.appSettings,
                localPlugin: context.recordingManager.localPlugin
            )
        } else {
            let text = richTranscript?.segments.map { $0.text }.joined(separator: "\n")
                ?? recording.transcription?.text ?? ""
            service = TranscriptChatService(
                transcriptText: text,
                speakerLabels: labels,
                appSettings: context.appSettings,
                localPlugin: context.recordingManager.localPlugin
            )
            // A finished recording has a stable sidecar location: bind it for
            // on-disk persistence and adopt any previously-saved conversation.
            if let url = recording.chatSidecarURL {
                service.enablePersistence(store: context.chatStore, url: url)
                service.startLoadingPersisted()
            }
        }
        chatStore.set(service, for: recording.fileURL)
        chatService = service
        service.prewarm()
    }

    /// Snapshot of the live transcript (finalized segments + in-progress lines),
    /// speaker-prefixed, for the live chat provider.
    @MainActor
    private static func liveTranscriptText(appState: AppState) -> String {
        var lines: [String] = appState.liveTranscriptSegments.map { seg in
            if let speaker = seg.speaker { return "\(speaker): \(seg.text)" }
            return seg.text
        }
        if !appState.liveVolatileMic.isEmpty { lines.append("You: \(appState.liveVolatileMic)") }
        if !appState.liveVolatileSystem.isEmpty { lines.append("Participant: \(appState.liveVolatileSystem)") }
        return lines.joined(separator: "\n")
    }

    private func deleteRecording() {
        guard let audioURL = recording.finalizedAudioURL else { return }
        let base = audioURL.deletingPathExtension()
        let candidates = [
            audioURL,
            base.appendingPathExtension("md"),
            base.appendingPathExtension("transcript.json"),
            base.appendingPathExtension("richtranscript.json"),
            base.appendingPathExtension("insights.json"),
            base.appendingPathExtension("chat.json"),
            base.appendingPathExtension("json"),
        ]
        for url in candidates {
            try? FileManager.default.removeItem(at: url)
        }
        if audioPlayer.currentFileURL == audioURL { audioPlayer.stop() }
        onDeleted()
    }

    // MARK: - Search

    /// True while the user has an active (non-blank) query.
    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Status text for the toolbar accessory.
    private var searchCounterLabel: String {
        guard isSearching else { return "" }
        if !searchResult.isValid { return "Invalid pattern" }
        if searchResult.matches.isEmpty { return "No results" }
        return "\(currentMatchIndex + 1) of \(searchResult.matches.count)"
    }

    /// Recomputes matches over the currently displayed turns. Keeps
    /// `currentMatchIndex` in bounds; callers decide when to reset it to 0.
    private func recomputeSearch() {
        let turns = displayedTurns.map { (id: $0.id, text: $0.text) }
        let result = TranscriptSearch.search(turns: turns, query: searchQuery)
        searchResult = result
        matchesByTurn = Dictionary(grouping: result.matches, by: \.turnId)
        if result.matches.isEmpty {
            currentMatchIndex = 0
        } else if currentMatchIndex >= result.matches.count {
            currentMatchIndex = result.matches.count - 1
        }
    }

    /// Debounced recompute triggered on each keystroke; resets to the first match.
    private func scheduleSearchRecompute() {
        searchDebounce?.cancel()
        searchDebounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            if Task.isCancelled { return }
            currentMatchIndex = 0
            recomputeSearch()
            // Surface results: jump to the transcript view if elsewhere.
            if isSearching, mode != .transcript { mode = .transcript }
            searchScrollTick &+= 1
        }
    }

    private func gotoNextMatch() {
        guard !searchResult.matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % searchResult.matches.count
        searchScrollTick &+= 1
    }

    private func gotoPrevMatch() {
        guard !searchResult.matches.isEmpty else { return }
        let n = searchResult.matches.count
        currentMatchIndex = (currentMatchIndex - 1 + n) % n
        searchScrollTick &+= 1
    }

    /// Zero-size buttons that register Find keyboard shortcuts without adding any
    /// visible UI (the `.searchable` field is the only visible search affordance):
    /// ⌘F focuses search, ⌘G / ⌘⇧G step next/previous match.
    private var findShortcuts: some View {
        Group {
            Button("") { if !isLive { isSearchPresented = true } }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { gotoNextMatch() }
                .keyboardShortcut("g", modifiers: .command)
            Button("") { gotoPrevMatch() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// Builds the row text with search highlights. Returns plain (un-highlighted)
    /// text when there is no active query or no matches in this turn.
    private func highlightedText(_ turn: SpeakerTurn) -> AttributedString {
        var attr = AttributedString(turn.text)
        guard isSearching, let turnMatches = matchesByTurn[turn.id], !turnMatches.isEmpty else {
            return attr
        }
        let chars = attr.characters
        let count = chars.count
        for match in turnMatches {
            guard match.location >= 0, match.location + match.length <= count else { continue }
            let lower = chars.index(chars.startIndex, offsetBy: match.location)
            let upper = chars.index(lower, offsetBy: match.length)
            attr[lower..<upper].backgroundColor = match.globalIndex == currentMatchIndex
                ? TranscriptDesignTokens.searchHighlightCurrent(scheme: colorScheme)
                : TranscriptDesignTokens.searchHighlight(scheme: colorScheme)
        }
        return attr
    }

    // MARK: - Persistence

    private func saveTranscript(_ transcript: RichTranscript) {
        let store = context.transcriptStore
        Task {
            do {
                try await store.save(transcript, for: recording)
            } catch {
                Logger.recording.error("TranscriptDetailView: failed to save: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func loadInsights() async {
        insights = (try? await context.insightsStore.load(for: recording)) ?? nil
    }

    private func saveInsights(_ updated: RecordingInsights) async {
        do {
            try await context.insightsStore.save(updated, for: recording)
            insights = updated
            if let path = updated.markdownPath {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: url.path),
                   let existing = try? String(contentsOf: url, encoding: .utf8) {
                    let rewritten = MarkdownInsightsUpdater.update(markdown: existing, with: updated)
                    try? rewritten.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        } catch {
            Logger.recording.error("Failed to save insights: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Best-effort load of voice-library people for the rename menu. Empty on
    /// failure — the menu must work even with no library.
    private func loadKnownPeople() async {
        let library = await context.voiceLibraryStore.load()
        knownPeopleNames = library.people.map(\.name)
        knownPersonIds = Dictionary(
            library.people.map { ($0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), $0.id) },
            uniquingKeysWith: { first, _ in first })
        embeddedSpeakerIds = context.recordingManager.embeddedSpeakerIds(for: recording)
    }

    private func loadTranscript() async {
        richTranscript = nil
        loadFailed = false
        insights = nil
        await loadKnownPeople()

        // Live recording: nothing on disk yet — the view renders from the
        // in-memory live segments, and chat uses the live provider.
        if isLive {
            chatService = chatStore.session(for: recording.fileURL)
            return
        }

        await loadInsights()

        // Restore any in-progress chat session for this recording.
        var resumedChat = false
        if let existing = chatStore.session(for: recording.fileURL) {
            chatService = existing
            if !existing.messages.isEmpty { resumedChat = true }
        } else {
            chatService = nil
        }

        if let cached = recording.richTranscript {
            richTranscript = cached
        } else {
            do {
                richTranscript = try await context.transcriptStore.load(for: recording)
            } catch {
                if let result = recording.transcription {
                    richTranscript = RichTranscriptBuilder().build(from: result)
                } else {
                    loadFailed = true
                }
            }
        }

        // Data-driven default view: an in-progress chat wins; otherwise open
        // the inspector when a summary exists, showing Transcript underneath.
        if resumedChat {
            mode = .chat
        } else {
            mode = .transcript
            if hasSummary { showInspector = true }
        }
        recomputeSearch()
    }

    private func rebuildTranscript() {
        guard let result = recording.transcription else { return }
        let built = RichTranscriptBuilder().build(from: result)
        richTranscript = built
        loadFailed = false
        recomputeSearch()
        saveTranscript(built)
    }
}

/// Applies the native macOS toolbar search field only when `enabled` (finished
/// recordings). On macOS the field shows full-width when the toolbar has room and
/// collapses to a magnifying-glass loupe when the window is narrow — no extra code.
private struct TranscriptSearchableModifier: ViewModifier {
    let enabled: Bool
    @Binding var query: String
    @Binding var isPresented: Bool
    let onSubmitSearch: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .searchable(text: $query,
                            isPresented: $isPresented,
                            placement: .toolbar,
                            prompt: "Search transcript")
                .onSubmit(of: .search, onSubmitSearch)
        } else {
            content
        }
    }
}
