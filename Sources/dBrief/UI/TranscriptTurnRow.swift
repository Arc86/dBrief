import SwiftUI

/// Everything a `TranscriptTurnRow` displays, as values.
struct TranscriptTurnRowModel: Equatable {
    var turn: SpeakerTurn
    var isActive: Bool
    var isLast: Bool
    var isMe: Bool
    var showSpeakerName: Bool
    var displayName: String
    var color: Color
    var matches: [TranscriptSearch.Match]
    /// Global index of the current search match, or -1 when it is not in this turn.
    var currentMatchIndex: Int
    var rowPadding: CGFloat
    var headerGap: CGFloat
    /// Changes whenever the speaker menu's content or state changes, so the
    /// label (built by the parent) is rebuilt only then.
    var menuKey: Int
}

/// One transcript turn: an avatar + connecting lane on the left, a capped-measure
/// content column on the right. The currently-playing turn is "lit" — a ring +
/// pulsing presence dot on the avatar and a tinted card around the text.
///
/// Its own view (not a helper on the 1,900-line detail view) with equality over
/// only the values it displays, so a parent re-render — playback ticks, streaming,
/// search typing — skips every row whose inputs did not change.
struct TranscriptTurnRow<SpeakerLabel: View>: View, Equatable {
    typealias Model = TranscriptTurnRowModel

    let model: Model
    let onSeek: (TimeInterval) -> Void
    @ViewBuilder let speakerLabel: () -> SpeakerLabel

    @Environment(\.viewerPalette) private var palette

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model
    }

    /// Only the turn containing the current match needs its index; other rows get
    /// -1 so moving between matches re-lays out just the rows involved.
    static func rowMatchIndex(matches: [TranscriptSearch.Match], current: Int) -> Int {
        matches.contains { $0.globalIndex == current } ? current : -1
    }

    private var turn: SpeakerTurn { model.turn }
    private var hasSpeaker: Bool { turn.speakerId != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if hasSpeaker {
                avatarLane
                    .frame(width: 34)
            } else {
                // Keep unattributed fragments on the same reading column.
                Color.clear.frame(width: 34, height: 1)
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSeek(turn.startTime) }
    }

    private var avatarLane: some View {
        VStack(spacing: 7) {
            SpeakerAvatar(
                speakerId: turn.speakerId ?? "",
                name: model.displayName,
                size: 34,
                overrideColor: model.color
            )
            .background {
                if model.isActive { Circle().fill(model.color.opacity(0.25)).frame(width: 42, height: 42) }
            }
            .overlay(alignment: .bottomTrailing) {
                // Border matches the panel base so the dot reads as sitting on the avatar.
                if model.isActive { PresenceDot(border: palette.surface.color, color: model.color) }
            }
            if !model.isLast {
                Capsule()
                    .fill(model.color.opacity(model.isActive ? 0.30 : 0.22))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var content: some View {
        // Highlighting must not change wrapping or row height while List scrolls.
        VStack(alignment: .leading, spacing: model.headerGap) {
            HStack(spacing: 10) {
                if model.showSpeakerName, hasSpeaker {
                    speakerLabel()
                }
                timecodeChip
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    if model.isActive {
                        PulsingDot(color: model.color, size: 5)
                    } else {
                        Color.clear.frame(width: 5, height: 5)
                    }
                    Text("PLAYING").uiFont(.system(size: 10).monospaced())
                }
                .foregroundStyle(model.color)
                .opacity(model.isActive ? 1 : 0)
                .accessibilityHidden(!model.isActive)
            }
            ViewerTranscriptText(text: turn.text, paragraphRanges: turn.readingParagraphRanges,
                matches: model.matches, currentMatchIndex: model.currentMatchIndex)
                .equatable()
        }
        .padding(EdgeInsets(top: model.rowPadding, leading: 16, bottom: model.rowPadding, trailing: 16))
        .background {
            if model.isActive {
                RoundedRectangle(cornerRadius: 12)
                    .fill(model.color.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(model.color.opacity(0.16), lineWidth: 1))
            }
        }
    }

    private var timecodeChip: some View {
        let chipColor: Color? = model.isActive ? model.color : nil
        return Button { onSeek(turn.startTime) } label: {
            Text(Self.timecode(turn.startTime))
                .uiFont(.system(size: 11).monospaced())
                .foregroundStyle(chipColor ?? palette.secondary.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background {
                    if let chipColor {
                        RoundedRectangle(cornerRadius: 5).fill(chipColor.opacity(0.14))
                    }
                }
        }
        .buttonStyle(.plain)
        .help("Jump to this point")
    }

    static func timecode(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "—" }
        let total = Int(min(max(0, time), Double(Int.max) / 2))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
