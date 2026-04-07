import SwiftUI

struct TranscriptWindowView: View {
    @Binding var recordingId: UUID?

    @Environment(AppState.self) private var appState
    @Environment(AudioPlayer.self) private var audioPlayer

    @State private var richTranscript: RichTranscript?
    @State private var currentTime: TimeInterval = 0
    @State private var transcriptStore = TranscriptStore()

    var body: some View {
        if let id = recordingId,
           let recording = appState.recording(for: id) {
            VStack(spacing: 0) {
                header(recording: recording)

                if let transcript = richTranscript ?? recording.richTranscript {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(transcript.segments) { segment in
                                    TranscriptSegmentRow(
                                        segment: segment,
                                        isActive: isSegmentActive(segment),
                                        onSeek: { time in
                                            seek(to: time, in: recording)
                                        },
                                        onStarToggle: {
                                            toggleStar(for: segment, in: recording)
                                        },
                                        onEdit: { newText in
                                            editSegment(segment, newText: newText, in: recording)
                                        }
                                    )
                                    .id(segment.id)
                                }
                            }
                            .padding(.horizontal, 8)
                        }
                        .onChange(of: currentTime) { _, newTime in
                            let activeSegment = transcript.segments.first {
                                newTime >= $0.start && newTime < $0.end
                            }
                            if let active = activeSegment {
                                proxy.scrollTo(active.id, anchor: .center)
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
                    }
                } else {
                    VStack {
                        Spacer()
                        Text("No transcript available")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .frame(minWidth: 500, minHeight: 400)
            .task {
                await loadTranscript(for: recording)
            }
        } else {
            Text("No recording selected")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func header(recording: Recording) -> some View {
        HStack {
            Text(recording.generatedTitle ?? recording.meetingTitleDraft)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            if let transcript = richTranscript {
                let starredCount = transcript.segments.filter { $0.isStarred }.count
                if starredCount > 0 {
                    Label("\(starredCount) starred", systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func isSegmentActive(_ segment: RichTranscript.Segment) -> Bool {
        currentTime >= segment.start && currentTime < segment.end
    }

    private func seek(to time: TimeInterval, in recording: Recording) {
        guard let audioURL = recording.finalizedAudioURL else { return }
        if audioPlayer.currentFileURL != audioURL {
            audioPlayer.play(url: audioURL)
        }
        audioPlayer.seek(to: time)
        currentTime = time
    }

    private func toggleStar(for segment: RichTranscript.Segment, in recording: Recording) {
        guard var transcript = richTranscript ?? recording.richTranscript else { return }
        if let idx = transcript.segments.firstIndex(where: { $0.id == segment.id }) {
            transcript.segments[idx].isStarred.toggle()
            richTranscript = transcript
            Task {
                await transcriptStore.save(transcript, for: recording)
            }
        }
    }

    private func editSegment(_ segment: RichTranscript.Segment, newText: String, in recording: Recording) {
        guard var transcript = richTranscript ?? recording.richTranscript else { return }
        if let idx = transcript.segments.firstIndex(where: { $0.id == segment.id }) {
            transcript.segments[idx].editedText = newText
            richTranscript = transcript
            Task {
                await transcriptStore.save(transcript, for: recording)
            }
        }
    }

    private func loadTranscript(for recording: Recording) async {
        if let stored = await transcriptStore.load(for: recording) {
            richTranscript = stored
        } else if let existing = recording.richTranscript {
            richTranscript = existing
        }
    }
}
