import SwiftUI
import OSLog

struct TranscriptWindowView: View {
    @Binding var recordingId: UUID?

    @Environment(AppContext.self) private var context
    @Environment(AppState.self) private var appState
    @Environment(AudioPlayer.self) private var audioPlayer

    @State private var richTranscript: RichTranscript?
    @State private var loadFailed = false
    @State private var showStarredOnly = false
    @State private var currentTime: TimeInterval = 0

    private var recording: Recording? {
        guard let id = recordingId else { return nil }
        if let r = appState.currentRecording, r.id == id { return r }
        return appState.recording(for: id)
    }

    private var displayedSegments: [RichSegment] {
        guard let t = richTranscript else { return [] }
        return showStarredOnly ? t.segments.filter { $0.isStarred } : t.segments
    }

    var body: some View {
        if let recording {
            VStack(spacing: 0) {
                // Toolbar: All / Starred filter
                HStack(spacing: 8) {
                    Button("All") { showStarredOnly = false }
                        .buttonStyle(TranscriptFilterButtonStyle(isActive: !showStarredOnly))
                    Button("⭐ Starred") { showStarredOnly = true }
                        .buttonStyle(TranscriptFilterButtonStyle(isActive: showStarredOnly))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()

                if loadFailed {
                    VStack(spacing: 12) {
                        Spacer()
                        Text("Transcript unavailable")
                            .foregroundStyle(.secondary)
                        Button("Rebuild") {
                            rebuildTranscript(for: recording)
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let _ = richTranscript {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(displayedSegments) { segment in
                                    TranscriptSegmentRow(
                                        segment: segment,
                                        isActive: isSegmentActive(segment),
                                        currentTime: audioPlayer.currentTime,
                                        onSeek: { time in seek(to: time, in: recording) },
                                        onToggleStar: { toggleStar(segment: segment, in: recording) },
                                        onSave: { newText in editSegment(segment, newText: newText, in: recording) }
                                    )
                                    .id(segment.id)
                                }
                            }
                            .padding(12)
                        }
                        .onChange(of: audioPlayer.currentTime) { _, newTime in
                            currentTime = newTime
                            if let t = richTranscript,
                               let active = t.segments.first(where: { newTime >= $0.start && newTime < $0.end }) {
                                withAnimation { proxy.scrollTo(active.id, anchor: .center) }
                            }
                        }
                    }

                    Divider()

                    if let audioURL = recording.finalizedAudioURL {
                        TranscriptPlayerBar(
                            audioURL: audioURL,
                            currentTime: $currentTime
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    } else {
                        Text("Audio file not found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                } else {
                    VStack {
                        Spacer()
                        ProgressView("Loading transcript…")
                        Spacer()
                    }
                }
            }
            .navigationTitle(recording.generatedTitle ?? recording.meetingTitleDraft)
            .frame(minWidth: 700, minHeight: 500)
            .task(id: recordingId) {
                await loadTranscript(for: recording)
            }
        } else {
            Text("No recording selected")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func isSegmentActive(_ segment: RichSegment) -> Bool {
        currentTime >= segment.start && currentTime < segment.end
    }

    private func seek(to time: TimeInterval, in recording: Recording) {
        guard let audioURL = recording.finalizedAudioURL else { return }
        if audioPlayer.currentFileURL != audioURL { audioPlayer.play(url: audioURL) }
        audioPlayer.seek(to: time)
    }

    private func toggleStar(segment: RichSegment, in recording: Recording) {
        guard var transcript = richTranscript,
              let idx = transcript.segments.firstIndex(where: { $0.id == segment.id }) else { return }
        transcript.segments[idx].isStarred.toggle()
        richTranscript = transcript
        saveTranscript(transcript, for: recording)
    }

    private func editSegment(_ segment: RichSegment, newText: String, in recording: Recording) {
        guard var transcript = richTranscript,
              let idx = transcript.segments.firstIndex(where: { $0.id == segment.id }) else { return }
        transcript.segments[idx].text = newText
        transcript.segments[idx].isEdited = true
        transcript.segments[idx].tokens = []
        richTranscript = transcript
        saveTranscript(transcript, for: recording)
    }

    private func saveTranscript(_ transcript: RichTranscript, for recording: Recording) {
        let store = context.transcriptStore
        Task {
            do {
                try await store.save(transcript, for: recording)
            } catch {
                Logger.recording.error("TranscriptWindowView: failed to save transcript: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func loadTranscript(for recording: Recording) async {
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
