import SwiftUI
import AppKit
import OSLog

/// Right-hand detail pane of the transcript browser: a single flat transcript
/// (speaker label + line), a speaker-chip bar, a waveform player, and a toolbar
/// whose chat toggle swaps the transcript for the AI chat view.
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

    @State private var richTranscript: RichTranscript?
    @State private var loadFailed = false
    @State private var currentTime: TimeInterval = 0
    @State private var chatService: TranscriptChatService?
    @State private var showChat = false
    @State private var copied = false
    @State private var showDeleteConfirm = false

    // Speaker rename
    @State private var renamingSpeakerId: String?
    @State private var speakerRenameText = ""

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

    var body: some View {
        VStack(spacing: 0) {
            if loadFailed {
                failedState
            } else if showChat {
                chatContent
            } else if richTranscript != nil {
                if showSpeakerNames, !uniqueSpeakerIds.isEmpty {
                    speakerChipBar
                    Divider()
                }
                transcriptList
                Divider()
                playerBar
            } else {
                loadingState
            }
        }
        .navigationTitle(recording.generatedTitle ?? recording.meetingTitleDraft)
        .toolbar { toolbarContent }
        .task { await loadTranscript() }
        .confirmationDialog("Delete this recording?",
                            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteRecording() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(recording.generatedTitle ?? recording.meetingTitleDraft)” and its audio will be permanently removed.")
        }
        .sheet(item: Binding(
            get: { renamingSpeakerId.map { IdentifiedString(value: $0) } },
            set: { renamingSpeakerId = $0?.value })) { boxed in
            speakerRenameSheet(for: boxed.value)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                toggleChat()
            } label: {
                Image(systemName: "bubble.left")
                    .symbolVariant(showChat ? .fill : .none)
                    .foregroundStyle(showChat ? Color.accentColor : Color.secondary)
            }
            .help(showChat ? "Show transcript" : "Chat with transcript")

            Button {
                copyTranscript()
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? Color.green : Color.secondary)
            }
            .disabled(richTranscript == nil)
            .help("Copy full transcript")

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

    // MARK: - Speaker chip bar

    private var speakerChipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(uniqueSpeakerIds, id: \.self) { id in
                    SpeakerPillView(speakerId: id, displayName: displayName(for: id)) {
                        speakerRenameText = displayName(for: id)
                        renamingSpeakerId = id
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    // MARK: - Transcript

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(displayedTurns) { turn in
                    transcriptRow(turn)
                        .listRowBackground(
                            isTurnActive(turn)
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear
                        )
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

    @ViewBuilder
    private func transcriptRow(_ turn: SpeakerTurn) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if showSpeakerNames, let id = turn.speakerId {
                speakerLabel(id: id)
            }
            Text(turn.text)
                .font(.system(size: CGFloat(fontSize)))
                .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: colorScheme))
                .lineSpacing(CGFloat(fontSize) * 0.4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { seek(to: turn.startTime) }
    }

    private func speakerLabel(id: String) -> some View {
        Menu {
            Button("Rename…") {
                speakerRenameText = displayName(for: id)
                renamingSpeakerId = id
            }
        } label: {
            Text(displayName(for: id))
                .font(.caption.weight(.semibold))
                .foregroundStyle(TranscriptDesignTokens.speakerColor(for: id))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func displayName(for id: String) -> String {
        richTranscript?.speakerLabels.first(where: { $0.id == id })?.displayName ?? id
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

    private func toggleChat() {
        showChat.toggle()
        if showChat, chatService == nil { buildChatService() }
    }

    private func isTurnActive(_ turn: SpeakerTurn) -> Bool {
        currentTime >= turn.startTime && currentTime < turn.endTime
    }

    private func seek(to time: TimeInterval) {
        guard let audioURL = recording.finalizedAudioURL else { return }
        if audioPlayer.currentFileURL != audioURL { audioPlayer.play(url: audioURL) }
        audioPlayer.seek(to: time)
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
        let text = richTranscript?.segments.map { $0.text }.joined(separator: "\n")
            ?? recording.transcription?.text ?? ""
        let labels = richTranscript?.speakerLabels ?? []
        let service = TranscriptChatService(
            transcriptText: text,
            speakerLabels: labels,
            appSettings: context.appSettings,
            localPlugin: context.recordingManager.localPlugin
        )
        chatStore.set(service, for: recording.fileURL)
        chatService = service
    }

    private func deleteRecording() {
        guard let audioURL = recording.finalizedAudioURL else { return }
        let base = audioURL.deletingPathExtension()
        let candidates = [
            audioURL,
            base.appendingPathExtension("md"),
            base.appendingPathExtension("transcript.json"),
            base.appendingPathExtension("richtranscript.json"),
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

    private func loadTranscript() async {
        richTranscript = nil
        loadFailed = false

        // Restore any in-progress chat session for this recording.
        if let existing = chatStore.session(for: recording.fileURL) {
            chatService = existing
            if !existing.messages.isEmpty { showChat = true }
        } else {
            chatService = nil
        }

        if let cached = recording.richTranscript {
            richTranscript = cached
            return
        }
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
