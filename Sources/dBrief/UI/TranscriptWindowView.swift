import SwiftUI
import OSLog

enum TranscriptViewMode: String, CaseIterable {
    case transcript = "Transcript"
    case segments = "Segments"
    case chat = "Chat"
}

struct TranscriptWindowView: View {
    @Binding var recordingId: UUID?

    @Environment(AppContext.self) private var context
    @Environment(AppState.self) private var appState
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(\.colorScheme) private var colorScheme

    // Persisted display preferences
    @AppStorage("transcriptFontSize") private var fontSize: Int = 16
    @AppStorage("showSpeakerNames") private var showSpeakerNames: Bool = true
    @AppStorage("showTranscriptSidePanel") private var showSidePanel: Bool = true

    // Per-window state
    @State private var richTranscript: RichTranscript?
    @State private var loadFailed = false
    @State private var viewMode: TranscriptViewMode = .transcript
    @State private var searchText = ""
    @State private var currentTime: TimeInterval = 0
    @State private var chatService: TranscriptChatService?
    @State private var copied = false

    private var recording: Recording? {
        guard let id = recordingId else { return nil }
        if let r = appState.currentRecording, r.id == id { return r }
        return appState.recording(for: id)
    }

    private var displayedSegments: [RichSegment] {
        guard let t = richTranscript else { return [] }
        let segments = t.segments
        guard !searchText.isEmpty else { return segments }
        let q = searchText.lowercased()
        return segments.filter { $0.text.lowercased().contains(q) }
    }

    private var displayedTurns: [SpeakerTurn] {
        guard let t = richTranscript else { return [] }
        let turns = t.speakerTurns()
        guard !searchText.isEmpty else { return turns }
        let q = searchText.lowercased()
        return turns.filter { turn in
            turn.text.lowercased().contains(q)
        }
    }

    var body: some View {
        if let recording {
            ZStack {
                TranscriptDesignTokens.windowBackground(scheme: colorScheme)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    toolbar

                    Divider()

                    HStack(spacing: 0) {
                        mainContent(for: recording)

                        if showSidePanel, let _ = richTranscript {
                            Divider()
                            sidePanelPane(for: recording)
                        }
                    }
                }
            }
            .navigationTitle(recording.generatedTitle ?? recording.meetingTitleDraft)
            .frame(minWidth: 700, minHeight: 500)
            .task(id: recordingId) {
                await loadTranscript(for: recording)
            }
            .onChange(of: viewMode) { _, newMode in
                if newMode == .chat, chatService == nil {
                    buildChatService(for: recording)
                }
            }
        } else {
            Text("No recording selected")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            // Mode picker
            Picker("Mode", selection: $viewMode) {
                ForEach(TranscriptViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)

            // Search (only for transcript/segments)
            if viewMode != .chat {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: 6).fill(TranscriptDesignTokens.cardFill(scheme: colorScheme))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(width: 180)
            }

            Spacer()

            // Copy transcript
            Button {
                copyTranscript()
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? Color.green : Color.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(richTranscript == nil)
            .help("Copy full transcript")

            // Toggle sidebar
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSidePanel.toggle()
                }
            } label: {
                Image(systemName: showSidePanel ? "sidebar.right" : "sidebar.right")
                    .symbolVariant(showSidePanel ? .fill : .none)
                    .foregroundStyle(showSidePanel ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(showSidePanel ? "Hide sidebar" : "Show sidebar")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            TranscriptDesignTokens.structureFill(scheme: colorScheme)
                .background(.ultraThinMaterial)
        )
    }

    // MARK: - Main content

    @ViewBuilder
    private func mainContent(for recording: Recording) -> some View {
        VStack(spacing: 0) {
            if loadFailed {
                failedState(for: recording)
            } else if viewMode == .chat {
                chatContent(for: recording)
            } else if let _ = richTranscript {
                segmentScrollView(for: recording)
                Divider()
                if let audioURL = recording.finalizedAudioURL {
                    TranscriptPlayerBar(audioURL: audioURL, currentTime: $currentTime)
                } else {
                    Text("Audio file not found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            } else {
                loadingState
            }
        }
    }

    private func segmentScrollView(for recording: Recording) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: TranscriptDesignTokens.cardGap) {
                    ForEach(displayedTurns) { turn in
                        SpeakerTurnCard(
                            turn: turn,
                            speakerLabels: richTranscript?.speakerLabels ?? [],
                            isActive: isTurnActive(turn),
                            showSpeakerNames: showSpeakerNames,
                            fontSize: fontSize,
                            onSeek: { time in seek(to: time, in: recording) },
                            onRenameSpeaker: { id, name in
                                renameSpeaker(speakerId: id, displayName: name, in: recording)
                            }
                        )
                        .id(turn.id)
                    }

                    if displayedTurns.isEmpty && !searchText.isEmpty {
                        Text("No results for \"\(searchText)\"")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(24)
                    }
                }
                .padding(TranscriptDesignTokens.scrollPadding)
            }
            .onChange(of: audioPlayer.currentTime) { _, newTime in
                currentTime = newTime
                guard viewMode != .chat,
                      let active = displayedTurns.first(where: { newTime >= $0.startTime && newTime < $0.endTime })
                else { return }
                withAnimation { proxy.scrollTo(active.id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func chatContent(for recording: Recording) -> some View {
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
            .task { buildChatService(for: recording) }
        }
    }

    private var loadingState: some View {
        VStack {
            Spacer()
            ProgressView("Loading transcript…")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func failedState(for recording: Recording) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Text("Transcript unavailable")
                .foregroundStyle(.secondary)
            Button("Rebuild") { rebuildTranscript(for: recording) }
                .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Side panel

    @ViewBuilder
    private func sidePanelPane(for recording: Recording) -> some View {
        if richTranscript != nil {
            TranscriptSidePanel(
                richTranscript: Binding(
                    get: { richTranscript ?? RichTranscript(segments: []) },
                    set: { updated in
                        richTranscript = updated
                        saveTranscript(updated, for: recording)
                    }
                ),
                recording: recording,
                fontSize: $fontSize,
                showSpeakerNames: $showSpeakerNames
            )
            .frame(width: 220)
            .transition(.move(edge: .trailing))
        }
    }

    // MARK: - Actions

    private func isTurnActive(_ turn: SpeakerTurn) -> Bool {
        currentTime >= turn.startTime && currentTime < turn.endTime
    }

    private func seek(to time: TimeInterval, in recording: Recording) {
        guard let audioURL = recording.finalizedAudioURL else { return }
        if audioPlayer.currentFileURL != audioURL { audioPlayer.play(url: audioURL) }
        audioPlayer.seek(to: time)
    }

    private func renameSpeaker(speakerId: String, displayName: String, in recording: Recording) {
        guard var transcript = richTranscript else { return }
        if let idx = transcript.speakerLabels.firstIndex(where: { $0.id == speakerId }) {
            transcript.speakerLabels[idx].displayName = displayName
        } else {
            transcript.speakerLabels.append(SpeakerLabel(id: speakerId, displayName: displayName))
        }
        richTranscript = transcript
        saveTranscript(transcript, for: recording)
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

    private func buildChatService(for recording: Recording) {
        guard chatService == nil else { return }
        let text = richTranscript?.segments.map { $0.text }.joined(separator: "\n") ?? recording.transcription?.text ?? ""
        let labels = richTranscript?.speakerLabels ?? []
        chatService = TranscriptChatService(
            transcriptText: text,
            speakerLabels: labels,
            appSettings: context.appSettings,
            localPlugin: context.recordingManager.localPlugin
        )
    }

    // MARK: - Persistence

    private func saveTranscript(_ transcript: RichTranscript, for recording: Recording) {
        let store = context.transcriptStore
        Task {
            do {
                try await store.save(transcript, for: recording)
            } catch {
                Logger.recording.error("TranscriptWindowView: failed to save: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func loadTranscript(for recording: Recording) async {
        richTranscript = nil
        loadFailed = false
        chatService = nil

        if let cached = recording.richTranscript {
            richTranscript = cached
            return
        }
        do {
            let loaded = try await context.transcriptStore.load(for: recording)
            richTranscript = loaded
        } catch {
            if let result = recording.transcription {
                richTranscript = RichTranscriptBuilder().build(from: result)
            } else {
                loadFailed = true
            }
        }
    }

    private func rebuildTranscript(for recording: Recording) {
        guard let result = recording.transcription else { return }
        let built = RichTranscriptBuilder().build(from: result)
        richTranscript = built
        loadFailed = false
        saveTranscript(built, for: recording)
    }
}

private struct TranscriptFilterButtonStyle: ButtonStyle {
    let isActive: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
            .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }
}
