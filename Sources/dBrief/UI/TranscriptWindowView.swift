import SwiftUI
import UniformTypeIdentifiers
import AppKit
import OSLog
import dBriefWire

/// Right-hand detail pane of the recording viewer. A calm shared document header
/// sits above Summary, Transcript, Actions, or Meeting Insights. Chat remains
/// an independent inspector. The initial document is Summary when available,
/// otherwise Transcript.
struct TranscriptDetailView: View, Equatable {
    let recording: Recording
    /// Called after the recording's files are deleted, so the browser can drop
    /// it from the sidebar and clear selection.
    var onDeleted: () -> Void = {}
    /// Everything else this view shows comes from its own state and observed
    /// models, so the recording's identity is its whole input. Comparing only
    /// that lets the browser re-render (selection, sidebar drag, library
    /// refresh) without re-running this body; `onDeleted` is a fresh closure on
    /// every browser render and would otherwise never compare equal.
    private let recordingIdentity: ObjectIdentifier

    init(recording: Recording, onDeleted: @escaping () -> Void = {}) {
        self.recording = recording
        self.onDeleted = onDeleted
        self.recordingIdentity = ObjectIdentifier(recording)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.recordingIdentity == rhs.recordingIdentity
    }

    @Environment(AppContext.self) private var context
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(TranscriptChatStore.self) private var chatStore
    @Environment(\.calmAppearance) private var calm
    @Environment(\.viewerPalette) private var palette
    @Environment(\.viewerReading) private var reading
    @Environment(\.viewerMode) private var appearanceMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Persisted display preferences
    private var showSpeakerNames: Bool {
        get { context.appSettings.viewerAppearance.showSpeakerNames }
        nonmutating set { context.appSettings.viewerAppearance.showSpeakerNames = newValue }
    }
    @State private var showReadingOptions = false
    @State private var showTranscriptReadingOptions = false

    private var readingPreferencesBinding: Binding<ViewerAppearancePreferences> {
        Binding(
            get: { context.appSettings.viewerAppearance },
            set: { context.appSettings.viewerAppearance = $0 }
        )
    }

    /// Which content view is showing in the main pane.
    @State private var mode: ViewerDocumentMode = .transcript
    /// Whether the data-driven default tab was applied for this recording.
    @State private var didApplyInitialMode = false
    /// Tabs opened at least once for this recording; they stay mounted.
    @State private var visitedModes: Set<ViewerDocumentMode> = []
    @State private var analysisEditorPresented = false
    @State private var analysisEditorBaseline: RecordingInsights?
    @State private var analysisSaveError: String?
    /// Inline summary edit in progress (Summary tab); persisted per recording in
    /// `SummaryDraftCache` so switching recordings never loses a dirty draft.
    @State private var summaryEdit: SummaryEditState?
    @FocusState private var transcriptSearchFocused: Bool

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
    /// The lit turn, written by `PlaybackFollower` only when it changes.
    @State private var activeTurnID: UUID?
    /// Whether this recording is playing (drives the row pulse).
    @State private var isPlaybackRunning = false
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
    @State private var showPrivacyReceipt = false
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
    @State private var transcriptScrollFollow = TranscriptScrollFollowController()

    // Speaker reassignment
    @State private var customRenameTurn: SpeakerTurn?

    // Diarization (after-the-fact speaker detection)
    @State private var reprocessingOperation: ReprocessingOperation?
    @State private var spokenSummaryTask: Task<Void, Never>?

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
    /// evaluation. Written only by `setTranscript(_:)`, together with
    /// `richTranscript`, which is only ever replaced wholesale (load,
    /// re-diarize, rename, edit).
    @State private var displayedTurns: [SpeakerTurn] = []
    /// Bumped by `setTranscript(_:)`; keys the per-speaker menu cache.
    @State private var transcriptRevision = 0
    /// Per-speaker rename/move menu data, shared by every row of that speaker.
    @State private var speakerMenuCache = SpeakerMenuCache()

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

    /// True while this view shows the recording currently being **captured**.
    private var isCaptureLive: Bool {
        guard let current = context.appState.currentRecording else { return false }
        return current.id == recording.id && context.appState.recordingState != .idle
    }

    /// True while this view shows the recording currently being **processed** in the
    /// background (progressive transcript arriving on the job).
    private var isReprocessing: Bool {
        context.recordingManager.isReprocessing(recording.finalizedAudioURL ?? recording.fileURL)
    }

    private var isProcessingLive: Bool {
        context.appState.processingJob?.showsTranscriptPreview(for: recording) == true
    }

    /// True while this view shows the in-progress (recording or processing) recording —
    /// drives the real-time live transcript + chat mode.
    private var isLive: Bool { isCaptureLive || isProcessingLive }

    /// The live segment source for this recording: the background job's progressive
    /// segments when processing, otherwise the shared capture live-set.
    private var liveSegments: [LiveTranscriptSegment] {
        if isProcessingLive { return context.appState.processingJob?.transcriptPreviewSegments ?? [] }
        return context.appState.liveTranscriptSegments
    }

    /// Finalized live turns, cached so a volatile partial (which arrives many
    /// times per second) doesn't re-run `speakerTurns()` over every finalized
    /// segment. Rebuilt only when the live segments grow.
    @State private var liveTurns: [SpeakerTurn] = []

    /// Rebuilds `liveTurns` from the current live segments, keeping row identity.
    private func refreshLiveTurns() {
        liveTurns = LiveTurnBuilder.turns(from: liveSegments)
    }

    /// Assigns the transcript and its display turns in the same update, so no
    /// frame renders new segments with the previous turn grouping. Every transcript
    /// mutation (rename, moved turns, speaker-review reload) passes through here, so
    /// this is also where an open chat is re-pointed at the new text.
    private func setTranscript(_ transcript: RichTranscript?) {
        richTranscript = transcript
        transcriptRevision += 1
        displayedTurns = transcript?.speakerTurns() ?? []
        rebindChat()
    }

    /// What a finished recording's chat reads; the one builder for new and rebound sessions.
    private var chatTranscriptContent: ChatTranscriptContent {
        .make(richTranscript: richTranscript, fallbackText: recording.transcription?.text ?? "")
    }

    /// Re-point this recording's chat session (open or cached) at the current transcript,
    /// keeping its messages. No-op while live, or when nothing the model sees changed.
    private func rebindChat() {
        guard !isLive, let session = chatService ?? chatStore.session(for: recording.fileURL),
              !session.isInvalidatedForReprocessing else { return }
        session.rebind(chatTranscriptContent, insightsURL: recording.insightsSidecarURL,
                       indexURL: recording.chatIndexSidecarURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !context.recordingManager.reprocessingRecoveryReady && !isCaptureLive {
                ReprocessingRecoveryView()
                    .environment(context.recordingManager)
                    .environment(context.appState)
            } else if isLive {
                // In-progress recording: keep the real-time transcript visible and
                // slide chat in as the right-hand assistant, so you can watch the
                // transcript grow while chatting with it.
                ViewerDocumentLayout {
                    viewerHeader(tabs: [], canDelete: false, assistantOpen: showLiveChat,
                                 onToggleAssistant: toggleLiveChat) { EmptyView() }
                } document: {
                    liveTranscriptContent
                } playback: {
                    EmptyView()
                } assistant: {
                    // Live chat is built only when first opened, as before.
                    assistantColumn(isOpen: showLiveChat, mountsChat: showLiveChat || chatService != nil) {
                        showLiveChat = false
                    }
                }
                .background(palette.canvas.color)
            } else if loadFailed {
                ViewerDocumentLayout {
                    viewerHeader(tabs: [], showsAssistantToggle: false, assistantOpen: false,
                                 onToggleAssistant: {}) {
                        ReprocessingMenu(recording: recording, hasTranscript: false, label: "Transcribe")
                            .environment(context.appSettings)
                            .environment(context.recordingManager)
                            .environment(context.appState)
                            .uiFont(.system(size: 12))
                            .buttonStyle(ViewerCommandButtonStyle())
                            .tint(palette.accentText.color)
                    }
                } document: {
                    ViewerNoTranscriptState(
                        canRebuild: recording.transcription != nil,
                        isPending: isReprocessing,
                        isBusy: !context.recordingManager.reprocessingRecoveryReady,
                        onRebuild: rebuildTranscript,
                        onTranscribe: { reprocessingOperation = .transcribe })
                } playback: {
                    if recording.finalizedAudioURL != nil { playerBar }
                } assistant: {
                    EmptyView()
                }
                .background(palette.canvas.color)
            } else if richTranscript != nil {
                ViewerDocumentLayout {
                    documentHeader
                    if isReprocessing {
                        Label("Reprocessing pending — current results are read-only. Manage the attempt in Queue & Recovery.", systemImage: "clock")
                            .uiFont(.callout).foregroundStyle(palette.secondary.color).padding(12)
                    } else if offerReanalysis { reanalysisBanner }
                    if mode != .transcript, insights?.basedOnPreviousTranscript == true {
                        Label("Based on the previous transcript", systemImage: "exclamationmark.circle")
                            .uiFont(.callout)
                            .foregroundStyle(palette.secondary.color)
                            .frame(maxWidth: 920, alignment: .leading)
                    }
                } document: {
                    bodyContent
                } playback: {
                    if ViewerPresentationPolicy.showsPlayback(mode: mode,
                        hasFinalizedAudio: recording.finalizedAudioURL != nil, isLive: isLive) {
                        playerBar.transition(documentModeTransition)
                    }
                } assistant: {
                    assistantColumn(isOpen: assistantOpen) { assistantOpen = false }
                }
                .background(palette.canvas.color)
                .animation(reduceMotion ? nil : ViewerMotion.document, value: mode)
            } else {
                loadingState
            }
        }
        // Empty title: the styled document header below is the single visible
        // title. With a unified toolbar SwiftUI renders `navigationTitle` as a
        // centered toolbar label, so an empty string (not titleVisibility) is
        // what actually removes the duplicate.
        .navigationTitle("")
        .focusedSceneValue(\.recordingViewer, viewerActions)
        .task(id: context.recordingManager.reprocessingRecoveryReady) {
            await loadTranscript()
        }
        .onChange(of: assistantOpen) { _, isOpen in
            // The animated panel stays mounted. Preserve the previous hide
            // behavior, which stopped read-aloud through onDisappear.
            if !isOpen { chatService?.stopReading() }
        }
        .onChange(of: context.recordingManager.reprocessingRecoveryReady) { _, ready in
            if !ready { invalidateDerivedWork(); setTranscript(nil); insights = nil }
        }
        .onChange(of: isReprocessing, initial: true) { _, locked in
            if locked { invalidateDerivedWork() }
        }
        .onChange(of: context.recordingManager.reprocessingResultsRevision) { _, _ in
            invalidateDerivedWork()
            Task { await reloadReprocessedResults() }
        }
        .background { if !isLive { findShortcuts } }
        .onChange(of: searchQuery) { _, _ in scheduleSearchRecompute() }
        .onChange(of: transcriptSearchFocused) { _, focused in
            if focused { isSearchPresented = true }
        }
        .onChange(of: isSearchPresented) { _, presented in
            if !presented {
                searchQuery = ""
                searchDebounce?.cancel()
                recomputeSearch()
            }
        }
        .onChange(of: isLive) { _, live in
            // When this recording stops being live — capture ended AND no background job is
            // processing it — swap the live preview for the authoritative on-disk transcript.
            // Keep a non-empty live chat and re-point it at that transcript (so the Q&A
            // history carries over); drop an empty one so a fresh chat is built against the
            // final text.
            guard !live else { return }
            showLiveChat = false
            let liveChat = chatStore.session(for: recording.fileURL)
            if liveChat?.hasHistory != true {
                chatStore.remove(for: recording.fileURL)
            }
            Task {
                await loadTranscript()
                if let liveChat, liveChat.hasHistory {
                    // Turns + `[hh:mm:ss] Name:` text, so the carried-over chat gets long mode.
                    liveChat.rebind(chatTranscriptContent, insightsURL: recording.insightsSidecarURL,
                                    indexURL: recording.chatIndexSidecarURL)
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
        .sheet(isPresented: $analysisEditorPresented) {
            if let baseline = analysisEditorBaseline {
                RecordingAnalysisEditor(baseline: baseline, isReadOnly: isReprocessing, saveError: analysisSaveError,
                    onSave: { edited in
                        if await saveInsights(edited, basedOn: baseline) { analysisEditorPresented = false }
                    },
                    onCancel: { analysisEditorPresented = false })
            }
        }
        .sheet(isPresented: $showPrivacyReceipt) {
            PrivacyReceiptView(recording: recording)
        }
        .sheet(item: $spokenSummaryService) { service in
            SpokenSummaryPlayerView(
                phase: service.phase,
                isSaved: service.resultIsSaved,
                recordingTitle: recording.generatedTitle ?? recording.meetingTitleDraft,
                audioPlayer: spokenSummaryPlayer,
                onSave: {
                    guard !isReprocessing else { return }
                    do {
                        _ = try await service.save(for: recording)
                        hasSpokenSummary = true
                        spokenSummaryService = nil
                    } catch {
                        // service.save set phase = .failed; keep the sheet open so the error shows
                    }
                },
                onClose: {
                    spokenSummaryTask?.cancel()
                    service.invalidateForReprocessing()
                    spokenSummaryService = nil
                },
                onRetry: { startSpokenSummary() }
            )
            .modifier(ViewerAppearanceScope(settings: context.appSettings))
        }
        .confirmationDialog("Delete this recording?",
                            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteRecording() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(recording.generatedTitle ?? recording.meetingTitleDraft)”, its audio, local sidecars, queued work, and saved recovery content will be permanently removed. Separately exported Markdown and content already sent to integrations are kept.")
        }
        .sheet(isPresented: Binding(get: { reprocessingOperation != nil }, set: { if !$0 { reprocessingOperation = nil } })) {
            if let operation = reprocessingOperation {
                ReprocessingSheet(recording: recording, operation: operation)
                    .environment(context.appSettings)
                    .environment(context.recordingManager)
                    .environment(context.appState)
            }
        }

    }

    // MARK: - Menu bar and keyboard

    /// The Recording/View menu commands and Space for this recording; `nil` while live.
    private var viewerActions: RecordingViewerActions? {
        guard !isLive else { return nil }
        let hasTranscript = richTranscript != nil
        let audioURL = recording.finalizedAudioURL
        let canReprocess = !isReprocessing && context.recordingManager.reprocessingRecoveryReady
        return RecordingViewerActions(
            mode: mode,
            availableModes: hasTranscript ? ViewerDocumentMode.allCases : [],
            selectMode: { mode = $0 },
            copy: hasTranscript ? { copySelectedDocument() } : nil,
            isPlaying: audioURL != nil && audioPlayer.currentFileURL == audioURL && audioPlayer.isPlaying,
            togglePlayback: audioURL.map { url in { audioPlayer.togglePlayPause(url: url) } },
            assistantOpen: assistantOpen,
            toggleAssistant: hasTranscript ? {
                assistantOpen.toggle()
                if assistantOpen, chatService == nil { buildChatService() }
            } : nil,
            reprocess: canReprocess ? { reprocessingOperation = $0 } : nil,
            hasTranscript: hasTranscript,
            revealInFinder: audioURL.map { url in { NSWorkspace.shared.activateFileViewerSelecting([url]) } },
            // Not while editing the summary: ⌘⌫ belongs to the editor then.
            delete: audioURL != nil && summaryEdit == nil ? { showDeleteConfirm = true } : nil
        )
    }

    // MARK: - Document header

    private var documentHeader: some View {
        viewerHeader(assistantOpen: assistantOpen, onToggleAssistant: {
            assistantOpen.toggle()
            if assistantOpen, chatService == nil { buildChatService() }
        }) {
            documentCommands
        }
    }

    /// "Thursday 8 October 2026 at 15:04 · 14m"; live recordings have no duration yet.
    private var headerSubtitle: String {
        let when = recording.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
        let duration = LibraryRowFormat.duration(recording.duration)
        return duration.isEmpty ? when : "\(when) · \(duration)"
    }

    /// The one document header for every state. Live and not-yet-transcribed
    /// recordings pass no tabs; delete is withheld while the recording is live.
    private func viewerHeader<Commands: View>(
        tabs: [ViewerDocumentMode] = ViewerDocumentMode.allCases,
        showsAssistantToggle: Bool = true,
        canDelete: Bool = true,
        assistantOpen: Bool,
        onToggleAssistant: @escaping () -> Void,
        @ViewBuilder commands: @escaping () -> Commands
    ) -> some View {
        ViewerHeader(
            title: recording.generatedTitle ?? recording.meetingTitleDraft,
            subtitle: headerSubtitle,
            tabs: tabs,
            showsAssistantToggle: showsAssistantToggle,
            mode: $mode,
            readingOptionsPresented: $showReadingOptions,
            readingPreferences: readingPreferencesBinding,
            unfinishedActions: insights?.unfinishedActionItems.count ?? 0,
            assistantOpen: assistantOpen,
            onToggleAssistant: onToggleAssistant,
            onPrivacyReceipt: { showPrivacyReceipt = true },
            onDelete: canDelete ? { showDeleteConfirm = true } : nil,
            commands: commands
        )
        .frame(maxWidth: 920)
    }

    private func toggleLiveChat() {
        showLiveChat.toggle()
        if showLiveChat, chatService == nil { buildChatService() }
    }

    /// Two command groups; the header's wrap layout keeps each group on one row.
    private var documentCommands: some View {
        Group {
            HStack(spacing: 8) { copyAndEditCommands }
            HStack(spacing: 8) { processingCommands }
        }
        .uiFont(.system(size: 12))
        .buttonStyle(ViewerCommandButtonStyle())
        .tint(palette.accentText.color)
    }

    @ViewBuilder private var copyAndEditCommands: some View {
        Button { copySelectedDocument() } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        if mode != .transcript {
            Button {
                analysisSaveError = nil
                if mode == .summary {
                    if summaryEdit == nil, let insights { summaryEdit = SummaryEditState(insights: insights) }
                } else {
                    analysisEditorBaseline = insights
                    analysisEditorPresented = true
                }
            } label: { Label("Edit", systemImage: "pencil") }
                .disabled(isReprocessing || insights == nil || (mode == .summary && summaryEdit != nil))
        }
    }

    @ViewBuilder private var processingCommands: some View {
        ReprocessingMenu(recording: recording, hasTranscript: richTranscript != nil, label: "Re-process")
            .environment(context.appSettings)
            .environment(context.recordingManager)
            .environment(context.appState)
        if mode == .summary {
            Menu {
                if hasSpokenSummary {
                    Button("Play Spoken Summary") { Task { await playSavedSpokenSummary() } }
                }
                Button(hasSpokenSummary ? "Regenerate Spoken Summary" : "Generate Spoken Summary") { startSpokenSummary() }
            } label: { Label("Spoken Summary", systemImage: "waveform") }
                .disabled(isReprocessing || insights?.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
        }
    }

    /// Shown after a speaker rename changes who-said-what: offers to regenerate
    /// the (name-aware) AI analysis. Opt-in — never auto-regenerates.
    private var reanalysisBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.text.rectangle")
                .foregroundStyle(.secondary)
            Text("Speaker names changed — regenerate analysis?")
                .uiFont(.callout)
            Spacer(minLength: 8)
            if isGenerating {
                ProgressView().controlSize(.small)
            } else {
                Button("Regenerate") {
                    offerReanalysis = false
                    Task { await generateSummary() }
                }
                .buttonStyle(.typographyProminent)
                .controlSize(.small)
                Button {
                    offerReanalysis = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.typographyBorderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss speaker-name prompt")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: - Body (mode-switched content the inspector sits beside)

    private var bodyContent: some View {
        // Visited tabs stay mounted and cross-fade in one shared frame (ZStack), so
        // switching back does not rebuild them. Hidden tabs are inert.
        ZStack {
            ForEach(ViewerPresentationPolicy.mountedModes(visited: visitedModes, current: mode), id: \.self) { tab in
                let isCurrent = tab == mode
                documentContent(for: tab)
                    .modifier(ViewerMountedTab(isCurrent: isCurrent))
            }
        }
        .onChange(of: mode, initial: true) { previous, current in
            visitedModes.insert(previous)
            visitedModes.insert(current)
            if current == .transcript { transcriptScrollFollow.resumeFollowing() }
            // Typing must never go into the hidden transcript's search field.
            else if transcriptSearchFocused { transcriptSearchFocused = false }
        }
    }

    @ViewBuilder
    private func documentContent(for tab: ViewerDocumentMode) -> some View {
            switch tab {
                case .summary:
                    summaryBody
                case .actions:
                    RecordingActionsView(insights: insights,
                        owners: recording.participants + (recording.calendarEvent?.attendeeNames ?? []),
                        isReadOnly: isReprocessing, speakerLabels: richTranscript?.speakerLabels ?? [], isGenerating: isGenerating,
                        canGenerate: richTranscript != nil && !isReprocessing,
                        onGenerate: { Task { await generateSummary() } },
                        onSetActionCompleted: { action, completed in
                            guard !isReprocessing else { throw CancellationError() }
                            guard let url = recording.insightsSidecarURL else { throw InsightsStoreError.noSidecarURL }
                            let revision = context.recordingManager.reprocessingResultsRevision
                            let saved = try await context.insightsStore.setActionCompleted(action, completed: completed, at: url)
                            guard !isReprocessing, revision == context.recordingManager.reprocessingResultsRevision else { throw CancellationError() }
                            insights = saved
                            return saved
                        })
                case .meetingInsights:
                    MeetingInsightsView(recording: recording, richTranscript: richTranscript, insights: insights,
                                        isReadOnly: isReprocessing, onPrivacyReceipt: { showPrivacyReceipt = true }) {
                        ForEach(uniqueSpeakerIds, id: \.self) { id in
                            if let turn = displayedTurns.first(where: { $0.speakerId == id }) {
                                speakerLabel(turn: turn, isMe: id == meSpeakerId)
                            }
                        }
                    }
                case .transcript:
                    transcriptBody
            }
    }

    private var documentModeTransition: AnyTransition {
        reduceMotion ? .identity : .opacity
    }

    private var summaryBody: some View {
        SummaryView(insights: insights, isGenerating: isGenerating,
                    canGenerate: richTranscript != nil && !isReprocessing,
                    isReadOnly: isReprocessing, onGenerate: { Task { await generateSummary() } },
                    edit: $summaryEdit, isCurrentTab: mode == .summary,
                    saveError: summaryEdit == nil ? nil : analysisSaveError,
                    onSaveEdit: { await saveSummaryEdit() })
            .onChange(of: summaryEdit) { _, state in
                SummaryDraftCache.shared.store(state, for: recording.fileURL)
            }
    }

    /// Saves the inline summary draft through the same path as the modal.
    private func saveSummaryEdit() async -> Bool {
        guard let edit = summaryEdit else { return false }
        guard !edit.isStale(currentSummary: insights?.summary) else {
            analysisSaveError = "The summary was regenerated while you were editing. Copy your text, cancel, and edit the new summary."
            return false
        }
        var edited = edit.insightsBaseline
        edited.summary = edit.draft.current
        guard await saveInsights(edited, basedOn: edit.insightsBaseline) else { return false }
        summaryEdit = nil
        return true
    }

    // MARK: - Transcript

    private var transcriptBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.secondary.color)
                TextField("Search transcript", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .focused($transcriptSearchFocused)
                    .onSubmit { gotoNextMatch() }
                    .onExitCommand { transcriptSearchFocused = false; isSearchPresented = false }
                    .accessibilityLabel("Search transcript")
                if isSearching {
                    Text(searchCounterLabel).uiFont(.caption.monospacedDigit()).foregroundStyle(palette.secondary.color)
                    Button { gotoPrevMatch() } label: { Image(systemName: "chevron.up") }
                        .disabled(searchResult.matches.isEmpty).help("Previous match (⌘⇧G)")
                        .accessibilityLabel("Previous search match")
                    Button { gotoNextMatch() } label: { Image(systemName: "chevron.down") }
                        .disabled(searchResult.matches.isEmpty).help("Next match (⌘G)")
                        .accessibilityLabel("Next search match")
                    Button { searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .help("Clear search")
                        .accessibilityLabel("Clear search")
                }
                Button { showTranscriptReadingOptions.toggle() } label: { Image(systemName: "textformat.size") }
                    .help("Display options").accessibilityLabel("Display options")
                    .popover(isPresented: $showTranscriptReadingOptions) {
                        ViewerPopoverContent {
                            ViewerReadingOptions(preferences: readingPreferencesBinding)
                        }
                    }
            }
            .buttonStyle(.plain)
            .padding(16)
            Divider().overlay(palette.divider.color)
            transcriptList
        }
        .modifier(ViewerCard())
        .task { if isSearchPresented { transcriptSearchFocused = true } }
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
                let menuKey = speakerMenuKey
                let lastID = displayedTurns.last?.id
                ForEach(displayedTurns) { turn in
                    TranscriptTurnRow(model: rowModel(for: turn, lastID: lastID, menuKey: menuKey),
                                      onSeek: { seek(to: $0) }) {
                        speakerLabel(turn: turn, isMe: turn.speakerId != nil && turn.speakerId == meSpeakerId)
                    }
                        .equatable()
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .id(turn.id)
                }
            }
            .listStyle(.plain)
            .contentMargins(.vertical, 19, for: .scrollContent)
            .overlayScrollers()
            .background(TranscriptScrollFollowObserver(controller: transcriptScrollFollow))
            .scrollContentBackground(.hidden)
            .scrollIndicators(.automatic)
            .onAppear { transcriptScrollFollow.resumeFollowing() }
            .modifier(PlaybackFollower(audioURL: recording.finalizedAudioURL, turns: displayedTurns,
                                       isVisible: mode == .transcript,
                                       proxy: proxy, follow: transcriptScrollFollow,
                                       activeTurnID: $activeTurnID, isPlaying: $isPlaybackRunning))
            .onChange(of: searchScrollTick) { _, _ in
                guard searchResult.matches.indices.contains(currentMatchIndex) else { return }
                let turnId = searchResult.matches[currentMatchIndex].turnId
                if reduceMotion {
                    proxy.scrollTo(turnId, anchor: .center)
                } else {
                    withAnimation { proxy.scrollTo(turnId, anchor: .center) }
                }
            }
        }
    }

    /// Everything a row displays, as values. Rows whose model is unchanged skip
    /// their body on a parent re-render.
    private func rowModel(for turn: SpeakerTurn, lastID: UUID?, menuKey: Int) -> TranscriptTurnRowModel {
        let matches = isSearching ? matchesByTurn[turn.id] ?? [] : []
        let isRenaming = customRenameTurn?.id == turn.id
        let active = isTurnActive(turn)
        return .init(
            turn: turn,
            isActive: active,
            // A mounted-but-hidden transcript tab must not keep animating.
            isPulsing: active && isPlaybackRunning && mode == .transcript,
            isLast: turn.id == lastID,
            isMe: turn.speakerId != nil && turn.speakerId == meSpeakerId,
            showSpeakerName: showSpeakerNames,
            displayName: displayName(for: turn.speakerId ?? ""),
            color: ViewerSpeakerPalette.color(for: turn.speakerId, mode: appearanceMode).color,
            matches: matches,
            currentMatchIndex: TranscriptTurnRow<EmptyView>.rowMatchIndex(matches: matches, current: currentMatchIndex),
            rowPadding: transcriptRowPadding(turn),
            headerGap: CGFloat(reading.density.speakerHeaderGap),
            menuKey: isRenaming ? ~menuKey : menuKey)
    }

    /// Changes whenever anything the speaker menu shows or does changes.
    private var speakerMenuKey: Int {
        var hasher = Hasher()
        hasher.combine(transcriptRevision)
        hasher.combine(knownPeopleNames)
        hasher.combine(embeddedSpeakerIds)
        hasher.combine(enrolledSpeakerIds)
        hasher.combine(isReprocessing)
        hasher.combine(recording.participants)
        hasher.combine(recording.calendarEvent?.attendeeNames)
        hasher.combine(recording.calendarCandidates.flatMap(\.attendeeNames))
        return hasher.finalize()
    }

    private func transcriptRowPadding(_ turn: SpeakerTurn) -> CGFloat {
        CGFloat((turn.readingParagraphRanges.last?.upperBound ?? 0) < 120
            ? min(reading.density.rowVerticalPadding, 9)
            : reading.density.rowVerticalPadding)
    }

    private func speakerLabel(turn: SpeakerTurn, isMe: Bool) -> some View {
        let id = turn.speakerId ?? ""
        return Menu {
            speakerMenuContent(turn: turn, isMe: isMe)
        } label: {
            HStack(spacing: 4) {
                Text(displayName(for: id))
                    .uiFont(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ViewerSpeakerPalette.color(for: id, mode: appearanceMode).color)
                if isMe {
                    Text("· You")
                        .uiFont(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.typographyBorderless)
        .disabled(isReprocessing)
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

    /// Selection-based speaker actions, split into Rename / Move / This-is-me. `Menu` builds
    /// its items eagerly, so the candidate data comes from a per-speaker cache instead of
    /// scanning the transcript once per row.
    @ViewBuilder
    private func speakerMenuContent(turn: SpeakerTurn, isMe: Bool) -> some View {
        let menu = speakerMenuCache.data(for: turn.speakerId, inputs: .init(
            revision: transcriptRevision,
            transcript: richTranscript ?? RichTranscript(segments: []),
            participants: recording.participants,
            attendees: (recording.calendarEvent?.attendeeNames ?? []) + recording.calendarCandidates.flatMap(\.attendeeNames),
            knownPeople: knownPeopleNames))
        // Rename targets, grouped by source. Picking a meeting/library name that already
        // belongs to another speaker swaps them (handled in `SpeakerReassignment.rename`).
        let meetingNames = menu.meetingNames
        let libraryNames = menu.libraryNames
        // Move targets: the other existing speakers.
        let others = menu.others
        let hasSegmentsBeyondTurn = menu.segmentCount > turn.segments.count

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

    // MARK: - Player

    @ViewBuilder
    private var playerBar: some View {
        if let audioURL = recording.finalizedAudioURL {
            TranscriptPlayerBar(audioURL: audioURL,
                                recordingDuration: recording.duration, segments: richTranscript?.segments ?? [],
                                speakerLabels: richTranscript?.speakerLabels ?? [])
        } else {
            Text("Audio file not found")
                .uiFont(.caption)
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

    /// The assistant slot beside the document. It stays mounted and animates its
    /// width, so chat state survives hiding.
    private func assistantColumn(isOpen: Bool, mountsChat: Bool = true,
                                 onClose: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            assistantResizeHandle
            assistantPanel(mountsChat: mountsChat, onClose: onClose)
                .padding(.vertical, 20).padding(.trailing, 20)
        }
        .frame(width: isOpen
            ? (assistantPanelLiveWidth ?? assistantPanelWidth) + 21
            : 0)
        .opacity(isOpen ? 1 : 0)
        .clipped()
        .allowsHitTesting(isOpen)
        .disabled(!isOpen)
        .accessibilityHidden(!isOpen)
        .animation(reduceMotion ? nil : ViewerMotion.panel, value: isOpen)
    }

    private func assistantPanel(mountsChat: Bool, onClose: @escaping () -> Void) -> some View {
        ViewerAssistantPanel(
            onDevice: isOnDeviceAI,
            onClose: onClose,
            onClearChat: { chatService?.clearMessages() },
            clearChatDisabled: isReprocessing || chatService?.isStreaming != false || chatService?.messages.isEmpty != false,
            conversation: chatService.map { conversationActions(for: $0) },
            chatFontSize: Binding(
                get: { context.appSettings.viewerAppearance.chatFontSize },
                set: { size in
                    var preferences = context.appSettings.viewerAppearance
                    preferences.chatFontSize = size
                    context.appSettings.viewerAppearance = preferences
                }
            )
        ) {
            if mountsChat { chatContent } else { Color.clear }
        }
        .frame(width: assistantPanelLiveWidth ?? assistantPanelWidth)
    }

    /// Draggable divider on the panel's leading edge. Dragging left widens the
    /// panel; the new width is clamped and persisted via `assistantPanelWidth`.
    private var assistantResizeHandle: some View {
        Color.clear
            .frame(width: 1)
            .overlay(Color.clear.frame(width: 8).contentShape(Rectangle()).preventsWindowDrag())
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Assistant width")
            .accessibilityValue("\(Int(assistantPanelLiveWidth ?? assistantPanelWidth)) points")
            .accessibilityAdjustableAction { direction in
                let delta: Double
                switch direction {
                case .increment: delta = 20
                case .decrement: delta = -20
                @unknown default: return
                }
                assistantPanelWidth = min(max(assistantPanelWidth + delta, assistantPanelWidthRange.lowerBound), assistantPanelWidthRange.upperBound)
            }
    }

    // MARK: - Chat

    @ViewBuilder
    private var chatContent: some View {
        if isReprocessing {
            ContentUnavailableView("Chat paused", systemImage: "clock", description: Text("Finish or discard the pending reprocessing attempt to use chat."))
        } else if let chatService {
            TranscriptChatView(
                chatService: chatService,
                onSeek: chatSeekAction,
                people: chatPeople,
                savedPrompts: context.appSettings.savedChatPrompts,
                onSavePrompt: { question in
                    let settings = context.appSettings
                    guard !settings.savedChatPrompts.contains(where: { $0.prompt == question }) else { return }
                    settings.savedChatPrompts.append(SavedChatPrompt(question: question))
                    chatService.showNotice("Saved as a prompt. Manage your prompts in Settings → AI analysis.")
                },
                answerDestinations: chatAnswerDestinations(for: chatService)
            )
        } else {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                Text("Preparing chat…")
                    .uiFont(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { buildChatService() }
        }
    }

    // MARK: - Live transcript

    /// Same card as the finished transcript, with the live status where the
    /// search bar sits.
    @ViewBuilder
    private var liveTranscriptContent: some View {
        VStack(spacing: 0) {
            ViewerLiveStatus(appState: context.appState, isProcessing: isProcessingLive,
                             segmentCount: liveSegments.count)
            Divider().overlay(palette.divider.color)
            liveTranscriptList
        }
        .modifier(ViewerCard())
        // This observer must live outside the conditional empty/list branches:
        // the first arriving segment is what makes the list exist at all.
        .onChange(of: liveSegments.count, initial: true) { _, _ in refreshLiveTurns() }
        .onChange(of: recording.transcription?.text) { _, _ in refreshLiveTurns() }
    }

    @ViewBuilder
    private var liveTranscriptList: some View {
        // Volatile partials are a capture-only preview; a recording shown here because it's
        // being processed must not display a concurrent capture's volatile text.
        let mic = isCaptureLive ? context.appState.liveVolatileMic : ""
        let system = isCaptureLive ? context.appState.liveVolatileSystem : ""
        if liveTurns.isEmpty && mic.isEmpty && system.isEmpty {
            liveWaitingState
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(liveTurns) { turn in
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
                .listStyle(.plain)
                .contentMargins(.vertical, 12, for: .scrollContent)
                .overlayScrollers()
                .scrollContentBackground(.hidden)
                .onChange(of: liveSegments.count) { _, _ in
                    // A new finalized segment: refresh the cached turns (a volatile
                    // partial alone leaves the count unchanged, so this doesn't
                    // re-run speakerTurns() on every partial), then scroll.
                    if reduceMotion {
                        proxy.scrollTo("live-bottom", anchor: .bottom)
                    } else {
                        withAnimation { proxy.scrollTo("live-bottom", anchor: .bottom) }
                    }
                }
            }
        }
    }

    private var liveWaitingState: some View {
        // Surface live status (e.g. "Preparing language…" while a first-run speech
        // asset downloads) when present; otherwise the default copy.
        let status = isCaptureLive ? context.appState.liveStatusMessage : ""
        // The in-progress transcription step carries the determinate progress + ETA
        // (WS3), so a file being processed shows a real bar instead of a bare spinner —
        // including for engines (Parakeet/Apple) that don't stream partial segments.
        let inProgressStep = context.appState.processingSteps.first {
            if case .inProgress = $0.status { return true }
            return false
        }
        let headline: String
        let subtitle: String
        if isProcessingLive {
            if recording.transcription != nil {
                headline = "No speech found in this recording"
                subtitle = "Processing can continue without transcript text."
            } else {
                headline = inProgressStep?.name ?? "Preparing transcript…"
                subtitle = "Streaming engines show words as they arrive. Other engines show the transcript when transcription finishes."
            }
        } else {
            headline = !status.isEmpty
                ? status
                : (context.appState.isLiveTranscribing ? "Listening…" : "Preparing live transcription…")
            subtitle = "Spoken words appear here as you record."
        }
        return VStack(spacing: 12) {
            Spacer()
            if isProcessingLive, let progress = inProgressStep?.progress {
                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 240)
            } else {
                ProgressView()
            }
            Text(headline)
                .uiFont(.callout)
                .foregroundStyle(.secondary)
            if isProcessingLive, let detail = inProgressStep?.detail, !detail.isEmpty {
                Text(detail)
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(subtitle)
                .uiFont(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func liveTurnRow(_ turn: SpeakerTurn) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if showSpeakerNames, let id = turn.speakerId {
                Text(id)
                    .uiFont(.caption.weight(.semibold))
                    .foregroundStyle(ViewerSpeakerPalette.color(for: id, mode: appearanceMode).color)
            }
            Text(turn.text)
                .font(ViewerFonts.font(for: reading, effectiveMode: appearanceMode))
                .foregroundStyle(palette.text.color)
                .lineSpacing(ViewerFonts.additionalLineSpacing(for: reading, effectiveMode: appearanceMode))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private func liveVolatileRow(speaker: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if showSpeakerNames {
                Text(speaker)
                    .uiFont(.caption.weight(.semibold))
                    .foregroundStyle(ViewerSpeakerPalette.color(for: speaker, mode: appearanceMode).color)
            }
            Text(text)
                .font(reading.readingFont == .openDyslexic
                      ? ViewerFonts.font(for: reading, effectiveMode: appearanceMode)
                      : ViewerFonts.font(for: reading, effectiveMode: appearanceMode).italic())
                .lineSpacing(ViewerFonts.additionalLineSpacing(for: reading, effectiveMode: appearanceMode))
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

    // MARK: - Speaker assignment

    /// Rename the whole speaker (swap on name collision — see `SpeakerReassignment.rename`).
    private func renameSpeaker(turn: SpeakerTurn, to newName: String) {
        guard let id = turn.speakerId else { return }
        renameSpeaker(speakerId: id, to: newName)
    }

    private func renameSpeaker(speakerId id: String, to newName: String) {
        guard !isReprocessing else { return }
        customRenameTurn = nil
        guard var transcript = richTranscript else { return }
        // Link to a voice-library person when the chosen name is already known.
        let knownId = knownPersonIds[newName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
        transcript = SpeakerReassignment.rename(transcript, speakerId: id, to: newName, personId: knownId)
        setTranscript(transcript)
        saveTranscript(transcript)
        recomputeSearch()
        // Growth loop (Phase 3): enroll this speaker's voiceprint, then link the
        // resulting (new or existing) library person id onto the label.
        let revision = context.recordingManager.reprocessingResultsRevision
        Task {
            guard !isReprocessing else { return }
            guard let personId = await context.recordingManager
                .enrollVoiceprintOnRename(recording: recording, speakerId: id, name: newName) else {
                if hasSummary { offerReanalysis = true }
                return
            }
            await loadKnownPeople()   // refresh rename candidates + name→id map
            guard !isReprocessing, revision == context.recordingManager.reprocessingResultsRevision else { return }
            if var t = richTranscript,
               let i = t.speakerLabels.firstIndex(where: { $0.id == id }),
               t.speakerLabels[i].personId != personId {
                t.speakerLabels[i].personId = personId
                setTranscript(t)
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
        guard !isReprocessing else { return }
        guard let id = turn.speakerId else { return }
        let revision = context.recordingManager.reprocessingResultsRevision
        Task {
            guard !isReprocessing else { return }
            guard let personId = await context.recordingManager
                .enrollVoiceprintOnRename(recording: recording, speakerId: id, name: name) else { return }
            guard !isReprocessing, revision == context.recordingManager.reprocessingResultsRevision else { return }
            enrolledSpeakerIds.insert(id)
            await loadKnownPeople()
            guard !isReprocessing, revision == context.recordingManager.reprocessingResultsRevision else { return }
            if var t = richTranscript,
               let i = t.speakerLabels.firstIndex(where: { $0.id == id }),
               t.speakerLabels[i].personId != personId {
                t.speakerLabels[i].personId = personId
                setTranscript(t)
                saveTranscript(t)
            }
        }
    }

    /// Move this turn (or all of the speaker's segments) to another existing speaker.
    private func reassignTurn(turn: SpeakerTurn, toSpeakerId: String, scope: ReassignScope) {
        guard !isReprocessing else { return }
        guard var transcript = richTranscript else { return }
        let ids = Set(turn.segments.map(\.id))
        transcript = SpeakerReassignment.apply(.existing(speakerId: toSpeakerId), to: transcript,
                                               segmentIds: ids, scope: scope, newId: "")
        setTranscript(transcript)
        saveTranscript(transcript)
        recomputeSearch()
    }

    // MARK: - Actions

    private func isTurnActive(_ turn: SpeakerTurn) -> Bool {
        turn.id == activeTurnID
    }

    /// Speakers first (they spoke), then participants and calendar attendees.
    private var chatPeople: [String] {
        AnalysisRoster.names(
            participants: (richTranscript?.speakerLabels.map(\.displayName) ?? []) + recording.participants,
            attendees: recording.calendarEvent?.attendeeNames ?? [])
    }

    /// Adding an answer edits the analysis, so it needs one and no edit in progress.
    private func chatAnswerDestinations(for chatService: TranscriptChatService) -> ChatAnswerDestinations? {
        guard !isLive, !isReprocessing, summaryEdit == nil, insights != nil else { return nil }
        func save(_ change: (inout RecordingInsights) -> Void) async -> Bool {
            guard let baseline = insights else { return false }
            var updated = baseline
            change(&updated)
            if await saveInsights(updated, basedOn: baseline) { return true }
            analysisSaveError = nil
            chatService.showNotice("Couldn’t add this answer to the recording. Try again, or edit it from the Summary tab.")
            return false
        }
        return ChatAnswerDestinations(
            knownOwners: chatPeople,
            existingActionItems: insights?.actionItems ?? [],
            addToSummary: { answer, question in
                await save { $0.summary = ChatAnswerHarvest.summary($0.summary, adding: answer, question: question) }
            },
            addActionItems: { items in
                await save { $0.actionItems += items }
            })
    }

    private func conversationActions(for chatService: TranscriptChatService) -> ChatConversationActions {
        let title = recording.generatedTitle ?? recording.meetingTitleDraft
        let notePath = insights?.markdownPath
        let hasNote = !isLive && !isReprocessing && notePath.map { FileManager.default.fileExists(atPath: $0) } == true
        return .init(
            isEmpty: chatService.isStreaming || chatService.conversationBody.isEmpty,
            copy: {
                Task {
                    if await chatService.copyConversation(title: title) { chatService.showNotice("Conversation copied.") }
                }
            },
            save: { saveConversation(chatService, title: title) },
            addToNote: hasNote ? { Task { await addConversationToNote(chatService) } } : nil)
    }

    private func saveConversation(_ chatService: TranscriptChatService, title: String) {
        let panel = NSSavePanel()
        panel.title = "Save Conversation as Markdown"
        panel.allowedContentTypes = [UTType(filenameExtension: "md")
            ?? UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(title) - Ask dBrief.md"
        Task { @MainActor in
            guard await panel.begin() == .OK, let url = panel.url else { return }
            do {
                try await chatService.exportConversation(title: title, to: url)
                chatService.showNotice("Conversation saved.")
            } catch {
                chatService.showNotice("Couldn’t save the conversation: \(error.localizedDescription)")
            }
        }
    }

    /// Writes the conversation into the recording's Markdown note as an "Ask dBrief"
    /// section, replacing the one written last time.
    private func addConversationToNote(_ chatService: TranscriptChatService) async {
        guard !isReprocessing, let path = insights?.markdownPath else { return }
        let body = chatService.conversationBody
        guard !body.isEmpty else { return }
        let noteURL = URL(fileURLWithPath: path)
        let revision = context.recordingManager.reprocessingResultsRevision
        do {
            let receiptContext = await recording.privacyContext()
            try await PrivacyTrace.$context.withValue(receiptContext) {
                try await PrivacyTrace.perform(.init(stage: .markdownExport, data: [.text],
                                                     destination: .local(provider: .fileSystem))) {
                    guard !isReprocessing, revision == context.recordingManager.reprocessingResultsRevision else {
                        throw CancellationError()
                    }
                    let existing = try String(contentsOf: noteURL, encoding: .utf8)
                    let updated = MarkdownInsightsUpdater.upsertAskDBrief(markdown: existing, body: body)
                    try updated.write(to: noteURL, atomically: true, encoding: .utf8)
                }
            }
            chatService.showNotice("Conversation added to the recording note.")
        } catch {
            chatService.showNotice("Couldn’t update the recording note: \(error.localizedDescription)")
        }
    }

    /// Chat citations jump to their moment in the transcript; nil without audio to seek.
    private var chatSeekAction: ((TimeInterval) -> Void)? {
        guard !isLive, recording.finalizedAudioURL != nil else { return nil }
        return { time in
            if mode != .transcript { mode = .transcript }
            seek(to: time)
        }
    }

    private func seek(to time: TimeInterval) {
        guard time.isFinite, let audioURL = recording.finalizedAudioURL,
              FileManager.default.fileExists(atPath: audioURL.path) else { return }
        transcriptScrollFollow.resumeFollowing()
        if audioPlayer.currentFileURL != audioURL { audioPlayer.play(url: audioURL) }
        guard audioPlayer.currentFileURL == audioURL, audioPlayer.duration.isFinite, audioPlayer.duration > 0 else { return }
        audioPlayer.seek(to: min(audioPlayer.duration, max(0, time)))
    }

    private func setMeSpeaker(_ id: String?) {
        guard !isReprocessing else { return }
        guard var transcript = richTranscript else { return }
        transcript.meSpeakerId = id
        setTranscript(transcript)
        saveTranscript(transcript)
    }

    /// Every analysis request uses the same durable reprocessing path.
    private func generateSummary() async {
        guard !isReprocessing else { return }
        reprocessingOperation = .analysis
    }

    private func copyTranscript() {
        guard let transcript = richTranscript else { return }
        let text = transcript.segments.map { $0.text }.joined(separator: "\n")
        Task {
            copied = await RecordingClipboard.copy(text, for: recording)
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func copySelectedDocument() {
        let text: String
        switch mode {
        case .transcript:
            copyTranscript()
            return
        case .summary:
            // While editing, copy the draft: the stale-save advice tells the user to copy it.
            text = summaryEdit?.draft.current ?? insights?.summary ?? ""
        case .actions:
            text = insights?.actionItems.map { action in
                "- [\(insights?.completedActions.contains(action) == true ? "x" : " ")] \(action)"
            }.joined(separator: "\n") ?? ""
        case .meetingInsights:
            text = MeetingInsightsCopy.text(recording: recording, richTranscript: richTranscript, insights: insights)
        }
        guard !text.isEmpty else { return }
        Task {
            copied = await RecordingClipboard.copy(text, for: recording)
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func buildChatService() {
        guard !isReprocessing else { return }
        // Reuse an existing session for this recording so the conversation
        // survives switching recordings and coming back.
        if let existing = chatStore.session(for: recording.fileURL), !existing.isInvalidatedForReprocessing {
            chatService = existing
            rebindChat() // it may have been built from an older transcript
            return
        }
        chatStore.remove(for: recording.fileURL)
        let labels = richTranscript?.speakerLabels ?? []
        let service: TranscriptChatService
        if isLive {
            // Chat against the live, growing transcript: the provider re-reads the
            // current segments + volatile lines on each send().
            let appState = context.appState
            let recordingID = recording.id
            service = TranscriptChatService(
                transcriptProvider: { Self.liveTranscriptText(appState: appState, recordingID: recordingID) },
                speakerLabels: labels,
                appSettings: context.appSettings,
                localPlugin: context.recordingManager.localPlugin,
                recording: recording
            )
        } else {
            let content = chatTranscriptContent
            // Long recordings on Gemma answer from part notes + retrieved excerpts. The
            // service reads the insights sidecar itself when this view hasn't loaded it yet.
            service = TranscriptChatService(
                transcriptText: content.text,
                speakerLabels: content.speakerLabels,
                appSettings: context.appSettings,
                localPlugin: context.recordingManager.localPlugin,
                recording: recording,
                turns: content.turns,
                insights: insights,
                insightsURL: recording.insightsSidecarURL,
                indexURL: recording.chatIndexSidecarURL
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
    private static func liveTranscriptText(appState: AppState, recordingID: UUID) -> String {
        // Resolve the source for THIS recording specifically, so a concurrent capture can't
        // feed its transcript into a processing recording's chat (or vice versa).
        let isCapture = appState.currentRecording?.id == recordingID && appState.recordingState != .idle
        let segments: [LiveTranscriptSegment]
        if isCapture {
            segments = appState.liveTranscriptSegments
        } else if appState.processingJob?.recording.id == recordingID {
            segments = appState.processingJob?.transcriptPreviewSegments ?? []
        } else {
            segments = []
        }
        var lines: [String] = segments.map { seg in
            if let speaker = seg.speaker { return "\(speaker): \(seg.text)" }
            return seg.text
        }
        // Volatile partials are a capture-only preview.
        if isCapture {
            if !appState.liveVolatileMic.isEmpty { lines.append("You: \(appState.liveVolatileMic)") }
            if !appState.liveVolatileSystem.isEmpty { lines.append("Participant: \(appState.liveVolatileSystem)") }
        }
        return lines.joined(separator: "\n")
    }

    private func deleteRecording() {
        guard let audioURL = recording.finalizedAudioURL else { return }
        Task {
            do {
                try await context.recordingManager.deleteRecording(audioURL)
                if audioPlayer.currentFileURL == audioURL { audioPlayer.stop() }
                onDeleted()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't delete the recording"
                alert.informativeText = "Deletion could not finish. Some files may remain; wait for processing to finish and check storage before retrying."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
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

    /// Recomputes matches over the displayed turns. `setTranscript(_:)` keeps
    /// `displayedTurns` in sync, so callers may run this right after assigning.
    /// Keeps `currentMatchIndex` in bounds; callers decide when to reset it to 0.
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
    /// visible UI (the card header owns the visible search field):
    /// ⌘F focuses search, ⌘G / ⌘⇧G step next/previous match.
    private var findShortcuts: some View {
        Group {
            Button("") { if !isLive { mode = .transcript; isSearchPresented = true; transcriptSearchFocused = true } }
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
    // MARK: - Persistence

    private func saveTranscript(_ transcript: RichTranscript) {
        guard !isReprocessing else { return }
        // Keep processing/review snapshots aware of edits before the disk await.
        recording.richTranscript = transcript
        let store = context.transcriptStore
        Task {
            do {
                try await store.save(transcript, for: recording)
            } catch {
                Logger.recording.error("TranscriptDetailView: failed to save recording files")
            }
        }
    }

    /// Reads the insights sidecar. Outer `nil` = stale (cancelled or superseded by
    /// a reprocessing revision); `.some(nil)` = no sidecar.
    private func fetchInsights() async -> RecordingInsights?? {
        guard context.recordingManager.reprocessingRecoveryReady else { return nil }
        let revision = context.recordingManager.reprocessingResultsRevision
        let loaded = (try? await context.insightsStore.load(for: recording)) ?? nil
        guard !Task.isCancelled, context.recordingManager.reprocessingRecoveryReady,
              revision == context.recordingManager.reprocessingResultsRevision else { return nil }
        return .some(loaded)
    }

    private func loadInsights() async {
        guard let loaded = await fetchInsights() else { return }
        insights = loaded
        refreshSpokenSummaryAvailability()
    }

    private func startSpokenSummary() {
        guard !isReprocessing else { return }
        guard let insights else { return }
        let service = SpokenSummaryService(
            recording: recording,
            appSettings: context.appSettings,
            plugin: context.recordingManager.localPlugin,
            store: spokenSummaryStore
        )
        spokenSummaryService = service
        spokenSummaryTask?.cancel()
        spokenSummaryTask = Task { await service.generate(insights: insights) }
    }

    private func playSavedSpokenSummary() async {
        guard !isReprocessing else { return }
        let revision = context.recordingManager.reprocessingResultsRevision
        guard let audioURL = recording.spokenSummaryAudioURL,
              let scriptURL = recording.spokenSummaryScriptURL,
              FileManager.default.fileExists(atPath: audioURL.path) else { return }
        let saved = try? await spokenSummaryStore.load(from: scriptURL)
        guard !isReprocessing, revision == context.recordingManager.reprocessingResultsRevision else { return }
        let service = SpokenSummaryService(
            recording: recording,
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

    /// Saves an analysis edit (modal or inline summary). Returns true only when both the
    /// sidecar and any linked Markdown note were written; on false the caller keeps its draft.
    private func saveInsights(_ updated: RecordingInsights, basedOn baseline: RecordingInsights) async -> Bool {
        analysisSaveError = nil
        guard !isReprocessing else {
            analysisSaveError = "Reprocessing is in progress. Your draft has been kept."
            return false
        }
        guard let url = recording.insightsSidecarURL else {
            analysisSaveError = InsightsStoreError.noSidecarURL.localizedDescription
            return false
        }
        let revision = context.recordingManager.reprocessingResultsRevision
        do {
            let saved = try await context.insightsStore.saveAnalysisEdit(updated, basedOn: baseline, to: url)
            guard !isReprocessing, revision == context.recordingManager.reprocessingResultsRevision else {
                throw CancellationError()
            }
            insights = saved
            if let path = saved.markdownPath {
                let markdownURL = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: markdownURL.path) {
                    do {
                        let receiptContext = await recording.privacyContext()
                        try await PrivacyTrace.$context.withValue(receiptContext) {
                            try await PrivacyTrace.perform(.init(stage: .markdownExport, data: [.text, .metadata],
                                                                 destination: .local(provider: .fileSystem))) {
                                let latest = try await context.insightsStore.load(from: url) ?? saved
                                guard !isReprocessing, revision == context.recordingManager.reprocessingResultsRevision else {
                                    throw CancellationError()
                                }
                                let existing = try String(contentsOf: markdownURL, encoding: .utf8)
                                let rewritten = MarkdownInsightsUpdater.update(markdown: existing, with: latest)
                                try rewritten.write(to: markdownURL, atomically: true, encoding: .utf8)
                            }
                        }
                    } catch {
                        analysisSaveError = "Analysis saved, but the linked Markdown note could not be updated. Your draft is kept so you can retry. \(error.localizedDescription)"
                        return false
                    }
                }
            }
            return true
        } catch {
            analysisSaveError = "Analysis could not be saved. Your draft is kept. \(error.localizedDescription)"
            Logger.recording.error("Failed to save insights sidecar")
            return false
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
        let available = await context.recordingManager.embeddedSpeakerIds(for: recording)
        guard !Task.isCancelled else { return }
        embeddedSpeakerIds = available
    }

    private func loadTranscript() async {
        guard context.recordingManager.reprocessingRecoveryReady || isCaptureLive else { return }
        let revision = context.recordingManager.reprocessingResultsRevision
        func isCurrent() -> Bool {
            !Task.isCancelled && (context.recordingManager.reprocessingRecoveryReady || isCaptureLive)
                && revision == context.recordingManager.reprocessingResultsRevision
        }

        // Live recording: nothing on disk yet — the view renders from the
        // in-memory live segments, and chat uses the live provider.
        if isLive {
            chatService = chatStore.session(for: recording.fileURL)
            await loadKnownPeople()
            return
        }

        // The current document stays on screen until its replacement is ready; a
        // newly selected recording starts empty because the view is keyed by URL.
        guard let loadedInsights = await fetchInsights(), isCurrent() else { return }

        var transcript: RichTranscript?
        if let cached = recording.richTranscript {
            transcript = cached
        } else {
            do {
                transcript = try await context.transcriptStore.load(for: recording)
                guard isCurrent() else { return }
            } catch {
                transcript = recording.transcription.map { RichTranscriptBuilder().build(from: $0) }
            }
        }

        // Restore any in-progress chat session for this recording.
        var resumedChat = false
        if let existing = chatStore.session(for: recording.fileURL), !existing.isInvalidatedForReprocessing {
            chatService = existing
            if !existing.messages.isEmpty { resumedChat = true }
        } else {
            chatService = nil
        }

        // Publish insights, transcript and tab in one update.
        insights = loadedInsights
        refreshSpokenSummaryAvailability()
        setTranscript(transcript)
        loadFailed = transcript == nil
        mode = ViewerPresentationPolicy.modeAfterLoad(
            current: mode, hasAppliedInitialMode: didApplyInitialMode, hasSummary: hasSummary)
        didApplyInitialMode = true
        if summaryEdit == nil, let restored = SummaryDraftCache.shared.restore(for: recording.fileURL) {
            summaryEdit = restored
            mode = .summary
        }
        if resumedChat { assistantOpen = true }
        recomputeSearch()

        // Only the rename menu needs these; don't hold the first paint for them.
        await loadKnownPeople()
    }

    private func invalidateDerivedWork() {
        customRenameTurn = nil
        chatService?.invalidateForReprocessing()
        chatStore.session(for: recording.fileURL)?.invalidateForReprocessing()
        chatStore.remove(for: recording.fileURL)
        chatService = nil
        spokenSummaryTask?.cancel()
        spokenSummaryTask = nil
        spokenSummaryService?.invalidateForReprocessing()
        spokenSummaryService = nil
        spokenSummaryPlayer.stop()
    }

    private func reloadReprocessedResults() async {
        recording.richTranscript = nil
        enrolledSpeakerIds = []
        embeddedSpeakerIds = []
        offerReanalysis = false
        await loadTranscript()
        if assistantOpen && !isReprocessing { buildChatService() }
    }

    private func rebuildTranscript() {
        guard !isReprocessing else { return }
        guard let result = recording.transcription else { return }
        let built = RichTranscriptBuilder().build(from: result)
        setTranscript(built)
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
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if animated && !reduceMotion {
            PulsingDotAnimation(color: color, size: size)
        } else {
            Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}

private struct PulsingDotAnimation: View {
    let color: Color
    let size: CGFloat
    @State private var on = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(on ? 1.15 : 0.85)
            .opacity(on ? 1 : 0.5)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .accessibilityHidden(true)
    }
}

/// Speaker-coloured presence dot with a panel-matching border, pulsing on the active avatar.
struct PresenceDot: View {
    let border: Color
    let color: Color
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if animated && !reduceMotion {
            PresenceDotAnimation(border: border, color: color)
        } else {
            dot.accessibilityHidden(true)
        }
    }
    private var dot: some View {
        Circle().fill(color).frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(border, lineWidth: 2))
    }
}

private struct PresenceDotAnimation: View {
    let border: Color
    let color: Color
    @State private var on = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(border, lineWidth: 2))
            .scaleEffect(on ? 1.1 : 0.9)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .accessibilityHidden(true)
    }
}

/// A document tab that stays mounted while hidden. No `.disabled`: it writes
/// `isEnabled` into the environment, which bypasses the Equatable transcript rows
/// and re-renders every one of them on each tab switch.
struct ViewerMountedTab: ViewModifier {
    let isCurrent: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isCurrent ? 1 : 0)
            .allowsHitTesting(isCurrent)
            .accessibilityHidden(!isCurrent)
            .zIndex(isCurrent ? 1 : 0)
    }
}
