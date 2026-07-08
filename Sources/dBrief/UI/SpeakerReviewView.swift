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
            Divider().opacity(0.35)
            cardsArea
            Divider().opacity(0.35)
            footer
        }
        .frame(width: 392)
        // Translucent glass, matching the app's other floating surfaces (mini player,
        // call popup). Full-bleed under the transparent titlebar.
        .background { Rectangle().fill(.thickMaterial).ignoresSafeArea() }
        // Take over the titlebar inset ourselves so the header sits just below the
        // traffic lights instead of leaving SwiftUI's safe-area gap on top of ours.
        .ignoresSafeArea(.container, edges: .top)
        .task {
            if edits.isEmpty {
                for item in items {
                    edits[item.id] = ConfirmedSpeaker(name: item.proposedName, personId: item.personId)
                }
            }
            library = await recordingManager.loadVoiceLibrary()
        }
    }

    /// The card list scrolls inside whatever height the window assigns it
    /// (`SpeakerReviewWindowController` sizes the window explicitly). Always a
    /// ScrollView so a slightly-off height estimate scrolls rather than clips;
    /// `.basedOnSize` suppresses the bounce when the content is shorter than the
    /// frame, so a couple of speakers still look tight.
    private var cardsArea: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(items) { card($0) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.gradient)
                    .frame(width: 34, height: 34)
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 4, y: 1)
                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Who's speaking?")
                    .font(.headline)
                Text("Confirm the speakers before analysis runs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        // Just enough top inset to clear the floating traffic-light controls.
        .padding(.top, 26)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Cancel", role: .cancel) { onCancel() }
            Spacer()
            Text("\(items.count) speaker\(items.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                onConfirm(edits)
            } label: {
                Label("Confirm", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
            RoundedRectangle(cornerRadius: 1.5)
                .fill(railColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    SpeakerAvatar(speakerId: item.id, name: currentName, size: 30)
                    TextField("Speaker name", text: nameBinding)
                        .textFieldStyle(.plain)
                        .font(.body.weight(.semibold))
                    snippetButton(item)
                }

                HStack(spacing: 6) {
                    reasonBadge(item)
                    ForEach(Array(candidates.prefix(2)), id: \.personId) { c in
                        chip(c, for: item.id)
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(TranscriptDesignTokens.cardBorder(scheme: scheme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
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
        // Recognized matches get a solid, high-contrast pill (white on color); the
        // uncertain states stay quieter with a tinted background.
        let solid = item.reason == .matched
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(solid ? Color.white : color)
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(Capsule().fill(solid ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.15))))
    }
}
