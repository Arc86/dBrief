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
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.gradient)
                    .frame(width: 44, height: 44)
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 5, y: 2)
                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Who's speaking?")
                    .font(.title2).bold()
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
        // Drop a suggestion that just repeats the current name — no value, less clutter.
        let candidates = SpeakerReviewCandidates.topMatches(
            clusterEmbedding: item.clusterEmbedding, library: library)
            .filter { $0.name.caseInsensitiveCompare(currentName.trimmingCharacters(in: .whitespaces)) != .orderedSame }
        let railColor = Theme.speakerColor(for: item.id)

        return HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(railColor)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    SpeakerAvatar(speakerId: item.id, name: currentName, size: 40)
                        .shadow(color: railColor.opacity(0.4), radius: 3, y: 1)
                    TextField("Speaker name", text: nameBinding)
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.semibold))
                    snippetButton(item)
                }

                reasonBadge(item)

                if !candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("SUGGESTIONS")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                            .kerning(0.5)
                        HStack(spacing: 6) {
                            ForEach(candidates, id: \.personId) { c in
                                chip(c, for: item.id)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(TranscriptDesignTokens.cardFill(scheme: scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(TranscriptDesignTokens.cardBorder(scheme: scheme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: TranscriptDesignTokens.cardShadowColor(scheme: scheme),
                radius: TranscriptDesignTokens.cardShadowRadius(scheme: scheme), y: 2)
    }

    @ViewBuilder
    private func snippetButton(_ item: SpeakerReviewItem) -> some View {
        if let snippet = item.snippet, let url = appState.pendingSpeakerReview?.masterAudioURL {
            let isPlayingThis = audioPlayer.playingTag == item.id && audioPlayer.isPlaying
            Button {
                if isPlayingThis {
                    audioPlayer.stop()
                } else {
                    audioPlayer.playRange(url: url, from: snippet.start, to: snippet.end, tag: item.id)
                }
            } label: {
                Image(systemName: isPlayingThis ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(isPlayingThis ? Color.red : Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(isPlayingThis ? "Stop" : "Play a sample of this voice")
        }
    }

    private func chip(_ c: SpeakerReviewCandidates.Candidate, for speakerId: String) -> some View {
        Button {
            edits[speakerId] = ConfirmedSpeaker(name: c.name, personId: c.personId)
        } label: {
            HStack(spacing: 4) {
                SpeakerAvatar(speakerId: c.personId, name: c.name, size: 15)
                Text(c.name).font(.caption.weight(.medium))
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 5)
        }
        .buttonStyle(.plain)
        .background(
            Capsule().fill(TranscriptDesignTokens.chipFill(scheme: scheme))
        )
        .overlay(
            Capsule().strokeBorder(TranscriptDesignTokens.chipBorder(scheme: scheme), lineWidth: 1)
        )
    }

    private func reasonBadge(_ item: SpeakerReviewItem) -> some View {
        let (text, color, icon): (String, Color, String) = {
            switch item.reason {
            case .matched: return ("Recognized · \(Int(item.confidence * 100))%", .green, "checkmark.seal.fill")
            case .belowThreshold: return ("No confident match", .secondary, "questionmark.circle.fill")
            case .lowMargin: return ("Ambiguous match", .orange, "questionmark.circle.fill")
            case .offRoster: return ("Off the expected roster", .orange, "questionmark.circle.fill")
            case .lostContention: return ("Claimed by another speaker", .orange, "questionmark.circle.fill")
            case .noEmbedding: return ("No voice sample", .secondary, "waveform.slash")
            case .emptyLibrary: return ("New voice", .blue, "sparkles")
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}
