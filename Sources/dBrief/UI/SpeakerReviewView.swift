import SwiftUI

/// Confirm-first review: one card per diarized speaker, shown while the pipeline is
/// paused. The user accepts/corrects names (with a playable voice snippet and library
/// suggestion chips) before the AI analysis and exports commit.
struct SpeakerReviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(\.dismiss) private var dismiss

    /// Edited name + resolved personId per speaker id, seeded from the session.
    @State private var edits: [String: ConfirmedSpeaker] = [:]
    @State private var library = VoiceLibrary()

    var body: some View {
        Group {
            if let session = appState.pendingSpeakerReview {
                content(session)
            } else {
                // Nothing to review (already confirmed/cancelled) — close.
                Color.clear.onAppear { dismiss() }
            }
        }
        .frame(minWidth: 460, minHeight: 360)
    }

    private func content(_ session: SpeakerReviewSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Confirm speakers")
                .font(.title2).bold()
                .padding([.horizontal, .top])
            Text("Check who's who before the summary and exports are generated.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(session.items) { item in
                        card(item, session: session)
                    }
                }
                .padding()
            }

            Divider()
            HStack {
                Button("Cancel") {
                    Task { await recordingManager.cancelReview() }
                    dismiss()
                }
                Spacer()
                Button("Confirm") {
                    Task { await recordingManager.finishReview(confirmed: edits) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .task {
            if edits.isEmpty {
                for item in session.items {
                    edits[item.id] = ConfirmedSpeaker(name: item.proposedName, personId: item.personId)
                }
            }
            library = await recordingManager.loadVoiceLibrary()
        }
    }

    private func card(_ item: SpeakerReviewItem, session: SpeakerReviewSession) -> some View {
        let nameBinding = Binding(
            get: { edits[item.id]?.name ?? item.proposedName },
            set: { edits[item.id] = ConfirmedSpeaker(name: $0, personId: edits[item.id]?.personId) }
        )
        let candidates = SpeakerReviewCandidates.topMatches(
            clusterEmbedding: item.clusterEmbedding, library: library)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Speaker name", text: nameBinding)
                    .textFieldStyle(.roundedBorder)
                if let snippet = item.snippet, let url = session.masterAudioURL {
                    Button {
                        audioPlayer.playRange(url: url, from: snippet.start, to: snippet.end)
                    } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.borderless)
                    .help("Play a sample of this voice")
                }
            }
            Text(reasonBadge(item))
                .font(.caption).foregroundStyle(.secondary)
            if !candidates.isEmpty {
                HStack {
                    ForEach(candidates, id: \.personId) { c in
                        Button(c.name) {
                            edits[item.id] = ConfirmedSpeaker(name: c.name, personId: c.personId)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func reasonBadge(_ item: SpeakerReviewItem) -> String {
        switch item.reason {
        case .matched: return "Matched · \(String(format: "%.2f", item.confidence))"
        case .belowThreshold: return "No confident match"
        case .lowMargin: return "Ambiguous match"
        case .offRoster: return "Off the expected roster"
        case .lostContention: return "Claimed by another speaker"
        case .noEmbedding: return "No voice sample"
        case .emptyLibrary: return "No known voices yet"
        }
    }
}
