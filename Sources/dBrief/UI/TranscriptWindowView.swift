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
    @Environment(\.calmAppearance) private var calm

    // Persisted display preferences
    @AppStorage("transcriptFontSize") private var fontSize: Int = 16
    @AppStorage("showSpeakerNames") private var showSpeakerNames: Bool = true

    /// Which content view is showing in the main pane.
    private enum ViewerMode: Hashable { case summary, transcript }
    @State private var mode: ViewerMode = .transcript

    /// Whether the assistant (chat) side panel is open beside the content.
    @AppStorage("transcriptAssistantOpen") private var assistantOpen = false

    /// Drag-resizable width of the assistant side panel (persisted, clamped to
    /// `assistantPanelWidthRange`). Replaces the native `.inspector` resize.
    @AppStorage("transcriptAssistantPanelWidth") private var assistantPanelWidth = 336.0
    private let assistantPanelWidthRange: ClosedRange<Double> = 300...480
    /// Live width while a resize drag is in flight (nil when not dragging). The
    /// drag tracks this `@State` directly and only commits to `@AppStorage` on
    /// release, so we don't write UserDefaults every frame.
    @State private var assistantPanelLiveWidth: Double?
    /// Panel width captured at the start of a resize drag (anchor for the global-X delta).
    @State private var assistantPanelDragStartWidth: Double?

    /// In live mode, chat is a right-hand side panel (so the in-progress transcript
    /// stays visible) rather than a full-screen swap like the finished-recording view.
    @State private var showLiveChat = false

    @State private var richTranscript: RichTranscript?
    @State private var loadFailed = false
    @State private var currentTime: TimeInterval = 0
    @State private var chatService: TranscriptChatService?
    @State private var insights: RecordingInsights?
    @State private var spokenSummaryService: SpokenSummaryService?
    /// Dedicated player for the spoken-summary sheet so it never commandeers the
    /// main transcript `audioPlayer` (which keeps the recording's position/state).
    @State private var spokenSummaryPlayer = AudioPlayer()
    @State private var hasSpokenSummary = false
    private let spokenSummaryStore = SpokenSummaryStore()
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

    /// Turns derived from `richTranscript`, cached so playback ticks (10 Hz
    /// `currentTime` updates) don't re-run the O(segments) merge on every body
    /// evaluation. Rebuilt by `.onChange(of: richTranscript)` — `richTranscript`
    /// is only ever replaced wholesale (load, re-diarize, rename, edit), and
    /// unchanged arrays compare by COW buffer identity, so the check is O(1)
    /// on ticks.
    @State private var displayedTurns: [SpeakerTurn] = []

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
                // Header (and the toolbar search) stay full-width on top; the
                // assistant panel sits beside the body region below the divider
                // (a plain HStack, not `.inspector`, which spans the full window
                // height and would overlap the header).
                VStack(spacing: 0) {
                    documentHeader
                    Divider()
                    if offerReanalysis { reanalysisBanner }
                    HStack(spacing: 0) {
                        bodyContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if assistantOpen {
                            assistantResizeHandle
                            assistantPanel
                        }
                    }
                }
            } else {
                loadingState
            }
        }
        // Empty title: the styled document header below is the single visible
        // title. With a unified toolbar SwiftUI renders `navigationTitle` as a
        // centered toolbar label, so an empty string (not titleVisibility) is
        // what actually removes the duplicate.
        .navigationTitle("")
        .toolbar { toolbarContent }
        .task { await loadTranscript() }
        .onChange(of: richTranscript) { _, newValue in
            displayedTurns = newValue?.speakerTurns() ?? []
        }
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
        .sheet(item: $spokenSummaryService) { service in
            SpokenSummaryPlayerView(
                service: service,
                audioPlayer: spokenSummaryPlayer,
                onSave: {
                    do {
                        _ = try await service.save(for: recording)
                        hasSpokenSummary = true
                        spokenSummaryService = nil
                    } catch {
                        // service.save set phase = .failed; keep the sheet open so the error shows
                    }
                },
                onClose: {
                    service.discard()
                    spokenSummaryService = nil
                },
                onRetry: { startSpokenSummary() }
            )
            .environment(\.calmAppearance, context.appSettings.reduceNeon)
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
        ToolbarItemGroup(placement: .principal) {
            if isLive {
                // Live recording: a single chat toggle that slides the chat panel in
                // beside the transcript, instead of the summary/transcript/chat tabs.
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
                    Text("Summary").tag(ViewerMode.summary)
                    Text("Transcript").tag(ViewerMode.transcript)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if !isLive {
                Button {
                    assistantOpen.toggle()
                    if assistantOpen, chatService == nil { buildChatService() }
                } label: {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                        .symbolVariant(assistantOpen ? .fill : .none)
                }
                .foregroundStyle(assistantOpen ? Color.accentColor : Color.secondary)
                .help(assistantOpen ? "Hide assistant" : "Chat with this transcript")
                .accessibilityAddTraits(assistantOpen ? .isSelected : [])
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

    // MARK: - Body (mode-switched content the inspector sits beside)

    @ViewBuilder
    private var bodyContent: some View {
        switch mode {
        case .summary:    summaryBody
        case .transcript: transcriptBody
        }
    }

    // MARK: - Summary

    private var summaryBody: some View {
        SummaryView(
            insights: insights,
            isGenerating: isGenerating,
            canGenerate: richTranscript != nil,
            onGenerate: { Task { await generateSummary() } },
            onSave: { updated in await saveInsights(updated) },
            hasSpokenSummary: hasSpokenSummary,
            onGenerateSpoken: { startSpokenSummary() },
            onPlaySpoken: { Task { await playSavedSpokenSummary() } }
        )
    }

    // MARK: - Transcript

    private var transcriptBody: some View {
        VStack(spacing: 0) {
            transcriptList
            Divider()
            playerBar
        }
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            // A `List` (not `ScrollView { LazyVStack }`) so offscreen rows are
            // recycled/released as you scroll. `LazyVStack` realizes-and-retains
            // every row it has shown, and each turn renders one
            // `.textSelection(.enabled)` Text per segment — those NSText-backed
            // selection views accumulate without bound and exhaust memory on long
            // transcripts (freeze → crash partway down). `List` keeps memory flat
            // while preserving text selection. (Audio-scrub-to-end stayed fine
            // because `scrollTo` only ever realized the destination rows.)
            List {
                ForEach(displayedTurns) { turn in
                    transcriptRow(turn)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 3, leading: 36, bottom: 3, trailing: 36))
                        .id(turn.id)
                }
            }
            .listStyle(.plain)
            .contentMargins(.vertical, 19, for: .scrollContent)
            .overlayScrollers()
            .scrollContentBackground(.hidden)
            .scrollIndicators(.automatic)
            .onChange(of: audioPlayer.currentTime) { _, newTime in
                currentTime = newTime
                guard let active = activeTurn(at: newTime) else { return }
                withAnimation { proxy.scrollTo(active.id, anchor: .center) }
            }
            .onChange(of: searchScrollTick) { _, _ in
                guard searchResult.matches.indices.contains(currentMatchIndex) else { return }
                let turnId = searchResult.matches[currentMatchIndex].turnId
                withAnimation { proxy.scrollTo(turnId, anchor: .center) }
            }
        }
    }

    /// Border drawn around the active speaker's presence dot — matches the panel
    /// base so the dot reads as sitting on the avatar.
    private var avatarRingBorder: Color {
        colorScheme == .dark ? Color(hex: "07070b") : .white
    }

    /// One speaker turn: an avatar + connecting lane on the left, a capped-measure
    /// content column on the right. The currently-playing turn is "lit" — a ring +
    /// pulsing presence dot on the avatar and a tinted card around the text.
    @ViewBuilder
    private func transcriptRow(_ turn: SpeakerTurn) -> some View {
        let active = isTurnActive(turn)
        let hasSpeaker = turn.speakerId != nil
        let isMe = hasSpeaker && turn.speakerId == meSpeakerId
        let color = isMe ? Color.accentColor : TranscriptDesignTokens.speakerColor(for: turn.speakerId)
        let isLast = turn.id == displayedTurns.last?.id

        HStack(alignment: .top, spacing: 14) {
            if hasSpeaker {
                avatarLane(turn: turn, color: color, active: active, drawLane: !isLast)
                    .frame(width: 34)
            }
            turnContent(turn: turn, color: color, active: active, isMe: isMe, hasSpeaker: hasSpeaker)
                .frame(maxWidth: active ? 660 : 640, alignment: .leading)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { seek(to: turn.startTime) }
    }

    private func avatarLane(turn: SpeakerTurn, color: Color, active: Bool, drawLane: Bool) -> some View {
        VStack(spacing: 7) {
            SpeakerAvatar(
                speakerId: turn.speakerId ?? "",
                name: displayName(for: turn.speakerId ?? ""),
                size: 34,
                overrideColor: color
            )
            .background {
                if active { Circle().fill(color.opacity(0.25)).frame(width: 42, height: 42) }
            }
            .overlay(alignment: .bottomTrailing) {
                if active { PresenceDot(border: avatarRingBorder) }
            }
            if drawLane {
                Capsule()
                    .fill(color.opacity(active ? 0.30 : 0.22))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func turnContent(turn: SpeakerTurn, color: Color, active: Bool, isMe: Bool, hasSpeaker: Bool) -> some View {
        VStack(alignment: .leading, spacing: active ? 10 : 6) {
            HStack(spacing: 10) {
                if showSpeakerNames, hasSpeaker {
                    speakerLabel(turn: turn, isMe: isMe)
                }
                timecodeChip(turn.startTime, color: active ? color : nil)
                if active {
                    Spacer(minLength: 8)
                    HStack(spacing: 5) {
                        PulsingDot(color: Color(hex: "30d158"), size: 5)
                        Text("PLAYING").font(.system(size: 10).monospaced())
                    }
                    .foregroundStyle(color)
                }
            }
            ForEach(Array(paragraphs(for: turn).enumerated()), id: \.offset) { _, para in
                Text(para)
                    .font(.system(size: CGFloat(fontSize)))
                    .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: colorScheme).opacity(active ? 1 : 0.92))
                    .lineSpacing(CGFloat(fontSize) * 0.45)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(active ? EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16) : EdgeInsets())
        .background {
            if active {
                RoundedRectangle(cornerRadius: 12)
                    .fill(color.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.16), lineWidth: 1))
            }
        }
    }

    private func timecodeChip(_ time: TimeInterval, color: Color?) -> some View {
        Button { seek(to: time) } label: {
            Text(timecode(time))
                .font(.system(size: 11).monospaced())
                .foregroundStyle(color ?? TranscriptDesignTokens.timestampText(scheme: colorScheme))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background {
                    if let color {
                        RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.14))
                    }
                }
        }
        .buttonStyle(.plain)
        .help("Jump to this point")
    }

    /// Splits the (search-highlighted) turn text back into per-segment paragraphs so
    /// long monologues read as paragraphs. Slicing the already-highlighted string by
    /// segment offsets keeps search-match positions intact.
    private func paragraphs(for turn: SpeakerTurn) -> [AttributedString] {
        let full = highlightedText(turn)
        guard turn.segments.count > 1 else { return [full] }
        let chars = full.characters
        let total = chars.count
        var result: [AttributedString] = []
        var offset = 0
        for seg in turn.segments {
            if offset >= total { break }
            let lower = chars.index(chars.startIndex, offsetBy: offset)
            let upper = chars.index(lower, offsetBy: min(seg.text.count, total - offset))
            let slice = AttributedString(full[lower..<upper])
            if !String(slice.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(slice)
            }
            offset += seg.text.count + 1   // + the single space `SpeakerTurn.text` joins with
        }
        return result.isEmpty ? [full] : result
    }

    private func speakerLabel(turn: SpeakerTurn, isMe: Bool) -> some View {
        let id = turn.speakerId ?? ""
        return Menu {
            speakerMenuContent(turn: turn, isMe: isMe)
        } label: {
            HStack(spacing: 4) {
                Text(displayName(for: id))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isMe ? Color.accentColor : TranscriptDesignTokens.speakerColor(for: id))
                if isMe {
                    Text("· You")
                        .font(.system(size: 11))
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
        // Rename targets, grouped by source. Picking a meeting/library name that already
        // belongs to another speaker swaps them (handled in `SpeakerReassignment.rename`).
        let meetingNames = cands.filter { $0.source == .meeting }.map(\.displayName)
        let libraryNames = cands.filter { $0.source == .library }.map(\.displayName)
        // Move targets: the other existing speakers.
        let others = cands.compactMap { c -> SpeakerMoveTarget? in
            guard let sid = c.existingSpeakerId, !c.isCurrent else { return nil }
            return SpeakerMoveTarget(id: sid, displayName: c.displayName)
        }
        let segCount = SpeakerReassignment.segmentCount(in: transcript, speakerId: turn.speakerId)
        let hasSegmentsBeyondTurn = segCount > turn.segments.count

        // Rename — grouped into "In this meeting" and "Voice library", plus a custom fallback.
        if meetingNames.isEmpty && libraryNames.isEmpty {
            Button("Rename…") { customRenameTurn = turn }
        } else {
            Menu("Rename to") {
                if !meetingNames.isEmpty {
                    Section("In this meeting") {
                        ForEach(meetingNames, id: \.self) { name in
                            Button(name) { renameSpeaker(turn: turn, to: name) }
                        }
                    }
                }
                if !libraryNames.isEmpty {
                    Section("Voice library") {
                        ForEach(libraryNames, id: \.self) { name in
                            Button(name) { renameSpeaker(turn: turn, to: name) }
                        }
                    }
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

    /// Proportional who-spoke-when timeline for the audio bar, merged from the
    /// transcript's speaker segments (silence collapses into adjacent runs).
    private var speakerStripSegments: [SpeakerStripSegment] {
        guard let t = richTranscript else { return [] }
        var segs: [SpeakerStripSegment] = []
        for seg in t.segments {
            let dur = max(0, seg.end - seg.start)
            guard dur > 0 else { continue }
            let key = seg.speakerId ?? "·nil"
            let isMe = seg.speakerId != nil && seg.speakerId == meSpeakerId
            let color = isMe ? Color.accentColor : TranscriptDesignTokens.speakerColor(for: seg.speakerId)
            if !segs.isEmpty, segs[segs.count - 1].colorKey == key {
                segs[segs.count - 1].weight += dur
            } else {
                segs.append(SpeakerStripSegment(colorKey: key, color: color, weight: dur))
            }
        }
        // A single-speaker (or un-diarized) timeline adds no information.
        return segs.count > 1 ? segs : []
    }

    @ViewBuilder
    private var playerBar: some View {
        if let audioURL = recording.finalizedAudioURL {
            TranscriptPlayerBar(audioURL: audioURL, currentTime: $currentTime, speakerStrip: speakerStripSegments)
        } else {
            Text("Audio file not found")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    // MARK: - Assistant panel (finished recording)

    private var isOnDeviceAI: Bool {
        switch context.appSettings.aiEngine {
        case .appleIntelligence, .qwenLocal: return true
        default: return false
        }
    }

    /// The assistant chat shown as a right-hand side panel below the document
    /// header (collapsible via the toolbar Chat toggle, drag-resizable via the
    /// handle on its leading edge). A side column below the header, so it sits
    /// beside the body without the native `.inspector` chrome that would span the
    /// full window height and overlap the header.
    private var assistantPanel: some View {
        VStack(spacing: 0) {
            assistantHeader
            Divider()
            chatContent
        }
        .frame(width: assistantPanelLiveWidth ?? assistantPanelWidth)
    }

    /// Draggable divider on the panel's leading edge. Dragging left widens the
    /// panel; the new width is clamped and persisted via `assistantPanelWidth`.
    private var assistantResizeHandle: some View {
        Divider()
            .overlay(Color.clear.frame(width: 8).contentShape(Rectangle()))
            .gesture(
                // Measure in `.global` space: the handle moves as the panel
                // resizes, so a handle-local `translation` feeds back on itself
                // and jitters. Global X doesn't move with the handle.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let start = assistantPanelDragStartWidth ?? assistantPanelWidth
                        if assistantPanelDragStartWidth == nil { assistantPanelDragStartWidth = start }
                        let delta = value.location.x - value.startLocation.x
                        let proposed = start - delta            // panel grows leftward
                        let clamped = min(max(proposed, assistantPanelWidthRange.lowerBound),
                                          assistantPanelWidthRange.upperBound)
                        // Track the cursor 1:1 — no implicit animation interpolating
                        // toward each new width (a source of the erratic feel).
                        var t = Transaction(); t.disablesAnimations = true
                        withTransaction(t) { assistantPanelLiveWidth = clamped }
                    }
                    .onEnded { _ in
                        if let live = assistantPanelLiveWidth { assistantPanelWidth = live }
                        assistantPanelLiveWidth = nil
                        assistantPanelDragStartWidth = nil
                    }
            )
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    private var assistantHeader: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(TranscriptDesignTokens.brandFill(calm: calm), in: RoundedRectangle(cornerRadius: 7))
            Text("dBrief Assistant")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: colorScheme))
            Spacer(minLength: 8)
            if isOnDeviceAI {
                Text("ON-DEVICE")
                    .font(.system(size: 10).monospaced())
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
            }
            Button { assistantOpen = false } label: {
                Image(systemName: "xmark").font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide assistant")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(.bar)
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

    /// The turn containing `time`, via binary search — `displayedTurns` is
    /// sorted by start and non-overlapping, and this runs on every 100 ms
    /// playback tick.
    private func activeTurn(at time: TimeInterval) -> SpeakerTurn? {
        var lo = 0
        var hi = displayedTurns.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if displayedTurns[mid].startTime <= time { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return nil }
        let candidate = displayedTurns[lo - 1]
        return time < candidate.endTime ? candidate : nil
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
        if hasSummary { mode = .summary }
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
            base.appendingPathExtension("spokensummary.json"),
            base.appendingPathExtension("spokensummary.m4a"),
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

    /// Recomputes matches over the current transcript's turns. Derives them from
    /// `richTranscript` (not the cached `displayedTurns`) because several callers
    /// run synchronously right after assigning `richTranscript`, before the
    /// `.onChange` refresh of the cache has fired. Keeps `currentMatchIndex` in
    /// bounds; callers decide when to reset it to 0.
    private func recomputeSearch() {
        let turns = (richTranscript?.speakerTurns() ?? []).map { (id: $0.id, text: $0.text) }
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
        refreshSpokenSummaryAvailability()
    }

    private func startSpokenSummary() {
        guard let insights else { return }
        let service = SpokenSummaryService(
            appSettings: context.appSettings,
            plugin: context.recordingManager.localPlugin,
            store: spokenSummaryStore
        )
        spokenSummaryService = service
        Task { await service.generate(insights: insights) }
    }

    private func playSavedSpokenSummary() async {
        guard let audioURL = recording.spokenSummaryAudioURL,
              let scriptURL = recording.spokenSummaryScriptURL,
              FileManager.default.fileExists(atPath: audioURL.path) else { return }
        let saved = try? await spokenSummaryStore.load(from: scriptURL)
        let service = SpokenSummaryService(
            appSettings: context.appSettings,
            plugin: context.recordingManager.localPlugin,
            store: spokenSummaryStore
        )
        service.presentSaved(audioURL: audioURL, script: saved?.script ?? "")
        spokenSummaryService = service
    }

    private func refreshSpokenSummaryAvailability() {
        guard let audioURL = recording.spokenSummaryAudioURL,
              let scriptURL = recording.spokenSummaryScriptURL else {
            hasSpokenSummary = false
            return
        }
        hasSpokenSummary = FileManager.default.fileExists(atPath: audioURL.path)
            && FileManager.default.fileExists(atPath: scriptURL.path)
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

        // Data-driven default view: Summary when one exists, else Transcript.
        // A resumed (non-empty) chat opens the assistant panel beside it.
        mode = hasSummary ? .summary : .transcript
        if resumedChat { assistantOpen = true }
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

/// A small dot that gently pulses (opacity + scale) forever — the live presence
/// indicator on the active speaker's avatar and the PLAYING pill.
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 6
    @State private var on = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(on ? 1.15 : 0.85)
            .opacity(on ? 1 : 0.5)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// Green presence dot with a panel-matching border, pulsing on the active avatar.
struct PresenceDot: View {
    let border: Color
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color(hex: "30d158"))
            .frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(border, lineWidth: 2))
            .scaleEffect(on ? 1.1 : 0.9)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
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
