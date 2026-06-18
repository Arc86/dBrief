import SwiftUI

/// Confirm-first review: one card per diarized speaker, shown while the pipeline is
/// paused. The user accepts/corrects names (with a playable voice snippet and library
/// suggestion chips) before the AI analysis and exports commit. Hosted by
/// `SpeakerReviewWindowController`, which owns the window lifecycle; this view reports
/// the outcome through `onConfirm` / `onCancel`.
struct SpeakerReviewView: View {
    let onConfirm: ([String: ConfirmedSpeaker]) -> Void
    let onCancel: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(\.colorScheme) private var scheme

    /// Edited name + resolved personId per speaker id, seeded from the session.
    @State private var edits: [String: ConfirmedSpeaker] = [:]
    @State private var library = VoiceLibrary()

    private var items: [SpeakerReviewItem] { appState.pendingSpeakerReview?.items ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)

            ScrollView {
                VStack(spacing: Theme.cardGap) {
                    ForEach(items) { item in
                        card(item)
                    }
                }
                .padding(Theme.contentPadding)
            }

            Divider().opacity(0.4)
            footer
        }
        .background(TranscriptDesignTokens.windowBackground(scheme: scheme).ignoresSafeArea())
        .task {
            if edits.isEmpty {
                for item in items {
                    edits[item.id] = ConfirmedSpeaker(name: item.proposedName, personId: item.personId)
                }
            }
            library = await recordingManager.loadVoiceLibrary()
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.wave.2.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Who's speaking?")
                    .font(.title3).bold()
                Text("Confirm the speakers before the summary and exports are created.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(Theme.contentPadding)
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) { onCancel() }
                .controlSize(.large)
            Spacer()
            Text("\(items.count) speaker\(items.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                onConfirm(edits)
            } label: {
                Label("Confirm", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.contentPadding)
    }

    // MARK: Speaker card

    private func card(_ item: SpeakerReviewItem) -> some View {
        let currentName = edits[item.id]?.name ?? item.proposedName
        let nameBinding = Binding(
            get: { edits[item.id]?.name ?? item.proposedName },
            set: { edits[item.id] = ConfirmedSpeaker(name: $0, personId: edits[item.id]?.personId) }
        )
        let candidates = SpeakerReviewCandidates.topMatches(
            clusterEmbedding: item.clusterEmbedding, library: library)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SpeakerAvatar(speakerId: item.id, name: currentName, size: 34)
                TextField("Speaker name", text: nameBinding)
                    .textFieldStyle(.plain)
                    .font(.title3)
                snippetButton(item)
            }

            reasonBadge(item)

            if !candidates.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Suggestions")
                        .font(.caption2).foregroundStyle(.tertiary)
                    HStack(spacing: 6) {
                        ForEach(candidates, id: \.personId) { c in
                            chip(c, for: item.id)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TranscriptDesignTokens.cardFill(scheme: scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(TranscriptDesignTokens.cardBorder(scheme: scheme), lineWidth: 1)
        )
        .shadow(color: TranscriptDesignTokens.cardShadowColor(scheme: scheme),
                radius: TranscriptDesignTokens.cardShadowRadius(scheme: scheme), y: 2)
    }

    @ViewBuilder
    private func snippetButton(_ item: SpeakerReviewItem) -> some View {
        if let snippet = item.snippet, let url = appState.pendingSpeakerReview?.masterAudioURL {
            Button {
                audioPlayer.playRange(url: url, from: snippet.start, to: snippet.end)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .help("Play a sample of this voice")
        }
    }

    private func chip(_ c: SpeakerReviewCandidates.Candidate, for speakerId: String) -> some View {
        Button {
            edits[speakerId] = ConfirmedSpeaker(name: c.name, personId: c.personId)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.fill").font(.caption2)
                Text(c.name).font(.caption)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(Theme.speakerColor(for: c.personId))
    }

    private func reasonBadge(_ item: SpeakerReviewItem) -> some View {
        let (text, color): (String, Color) = {
            switch item.reason {
            case .matched: return ("Recognized · \(Int(item.confidence * 100))%", .green)
            case .belowThreshold: return ("No confident match", .secondary)
            case .lowMargin: return ("Ambiguous match", .orange)
            case .offRoster: return ("Off the expected roster", .orange)
            case .lostContention: return ("Claimed by another speaker", .orange)
            case .noEmbedding: return ("No voice sample", .secondary)
            case .emptyLibrary: return ("New voice", .secondary)
            }
        }()
        return Label(text, systemImage: item.reason == .matched ? "checkmark.seal.fill" : "questionmark.circle")
            .font(.caption)
            .foregroundStyle(color)
    }
}
