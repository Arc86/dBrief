import SwiftUI
import AppKit
import OSLog

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

    /// Which of the three views is showing.
    private enum ViewerMode { case summary, transcript, chat }
    @State private var mode: ViewerMode = .transcript

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

    // Speaker rename
    @State private var renamingSpeakerId: String?
    @State private var speakerRenameText = ""

    // Diarization (after-the-fact speaker detection)
    @State private var isDiarizing = false
    @State private var showDiarizeConfirm = false
    @State private var diarizeError: String?

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
                switch mode {
                case .summary:    summaryBody
                case .transcript: transcriptBody
                case .chat:       chatContent
                }
            } else {
                loadingState
            }
        }
        .navigationTitle(recording.generatedTitle ?? recording.meetingTitleDraft)
        .toolbar { toolbarContent }
        .task { await loadTranscript() }
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
        .overlay { if isDiarizing { diarizingOverlay } }
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
        .sheet(item: Binding(
            get: { renamingSpeakerId.map { IdentifiedString(value: $0) } },
            set: { renamingSpeakerId = $0?.value })) { boxed in
            speakerRenameSheet(for: boxed.value)
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
                modeButton(.summary, systemImage: "doc.text", help: "Summary")
                modeButton(.transcript, systemImage: "list.bullet", help: "Transcript")
                modeButton(.chat, systemImage: "bubble.left.and.bubble.right", help: "Chat")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
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
        }
    }

    private func modeButton(_ target: ViewerMode, systemImage: String, help: String) -> some View {
        let active = mode == target
        return Button {
            mode = target
            if target == .chat, chatService == nil { buildChatService() }
        } label: {
            Image(systemName: systemImage)
                .symbolVariant(active ? .fill : .none)
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
        }
        .help(help)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: - Summary

    private var summaryBody: some View {
        SummaryView(
            insights: insights,
            isGenerating: isGenerating,
            canGenerate: richTranscript != nil,
            onGenerate: { Task { await generateSummary() } },
            onSave: { updated in await saveInsights(updated) }
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
                    if showSpeakerNames, let id = turn.speakerId {
                        speakerLabel(id: id, isMe: isMe)
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
                Text(turn.text)
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

    private func speakerLabel(id: String, isMe: Bool) -> some View {
        Menu {
            Button("Rename…") {
                speakerRenameText = displayName(for: id)
                renamingSpeakerId = id
            }
            if isMe {
                Button("Clear “This is me”") { setMeSpeaker(nil) }
            } else {
                Button("This is me") { setMeSpeaker(id) }
            }
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
        if let audioURL = recording.finalizedAudioURL {
            TranscriptPlayerBar(audioURL: audioURL, currentTime: $currentTime)
        } else {
            Text("Audio file not found")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
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

    // MARK: - Speaker rename sheet

    private func speakerRenameSheet(for speakerId: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Speaker").font(.headline)
            TextField("Name", text: $speakerRenameText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 240)
                .onSubmit { commitSpeakerRename(speakerId) }
            HStack {
                Spacer()
                Button("Cancel") { renamingSpeakerId = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commitSpeakerRename(speakerId) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(speakerRenameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func commitSpeakerRename(_ speakerId: String) {
        let name = speakerRenameText.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            renameSpeaker(speakerId: speakerId, displayName: name)
        }
        renamingSpeakerId = nil
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

    private func renameSpeaker(speakerId: String, displayName: String) {
        guard var transcript = richTranscript else { return }
        if let idx = transcript.speakerLabels.firstIndex(where: { $0.id == speakerId }) {
            transcript.speakerLabels[idx].displayName = displayName
        } else {
            transcript.speakerLabels.append(SpeakerLabel(id: speakerId, displayName: displayName))
        }
        richTranscript = transcript
        saveTranscript(transcript)
    }

    private func runDiarization() async {
        guard let audioURL = recording.finalizedAudioURL,
              let transcript = richTranscript else { return }
        isDiarizing = true
        defer { isDiarizing = false }
        do {
            let turns = try await context.recordingManager.localPlugin.diarize(fileURL: audioURL)
            guard !turns.isEmpty else {
                diarizeError = "No speakers were detected in this recording."
                return
            }
            let updated = SpeakerAssigner.assign(turns, to: transcript)
            richTranscript = updated
            if !showSpeakerNames { showSpeakerNames = true }
            saveTranscript(updated)
        } catch {
            diarizeError = error.localizedDescription
        }
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
                let svc = service
                Task { await svc.loadPersisted() }
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

    private func loadTranscript() async {
        richTranscript = nil
        loadFailed = false
        insights = nil

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

        // Data-driven default view: an in-progress chat wins; otherwise Summary
        // when one exists, else Transcript.
        if resumedChat {
            mode = .chat
        } else {
            mode = hasSummary ? .summary : .transcript
        }
    }

    private func rebuildTranscript() {
        guard let result = recording.transcription else { return }
        let built = RichTranscriptBuilder().build(from: result)
        richTranscript = built
        loadFailed = false
        saveTranscript(built)
    }
}

/// Small Identifiable wrapper so a `String` speaker id can drive `.sheet(item:)`.
private struct IdentifiedString: Identifiable {
    let value: String
    var id: String { value }
}
