// Sources/dBrief/UI/SpeakerTurnCard.swift
import SwiftUI

struct SpeakerTurnCard: View {
    let turn: SpeakerTurn
    let speakerLabels: [SpeakerLabel]
    let isActive: Bool
    let showSpeakerNames: Bool
    let fontSize: Int
    let onSeek: (Double) -> Void
    let onRenameSpeaker: (String, String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var showingSpeakerRename = false
    @State private var speakerRenameText = ""

    private var displayName: String {
        guard let id = turn.speakerId else { return "Speaker" }
        return speakerLabels.first(where: { $0.id == id })?.displayName ?? id
    }

    private var timeRangeLabel: String {
        "\(formatTime(turn.startTime)) – \(formatTime(turn.endTime))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            bodyText
        }
        .padding(TranscriptDesignTokens.cardPadding)
        .background(cardBackground)
        .overlay(cardBorderOverlay)
        .shadow(
            color: TranscriptDesignTokens.cardShadowColor(scheme: colorScheme),
            radius: TranscriptDesignTokens.cardShadowRadius(scheme: colorScheme),
            x: 0,
            y: 1
        )
    }

    // MARK: - Subviews

    private var headerRow: some View {
        HStack(spacing: 6) {
            if showSpeakerNames {
                SpeakerPillView(speakerId: turn.speakerId, displayName: displayName) {
                    speakerRenameText = displayName
                    showingSpeakerRename = true
                }
                .popover(isPresented: $showingSpeakerRename, arrowEdge: .bottom) {
                    speakerRenamePopover
                }
            }
            Text(timeRangeLabel)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(TranscriptDesignTokens.timestampText(scheme: colorScheme))
        }
    }

    private var bodyText: some View {
        Text(turn.text)
            .font(.system(size: CGFloat(fontSize)))
            .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: colorScheme))
            .lineSpacing(CGFloat(fontSize) * 0.65)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onSeek(turn.startTime) }
    }

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: TranscriptDesignTokens.cardCornerRadius)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: TranscriptDesignTokens.cardCornerRadius)
                .fill(TranscriptDesignTokens.cardFill(scheme: colorScheme))
        }
    }

    private var cardBorderOverlay: some View {
        RoundedRectangle(cornerRadius: TranscriptDesignTokens.cardCornerRadius)
            .stroke(
                isActive
                    ? Color.accentColor.opacity(0.55)
                    : TranscriptDesignTokens.cardBorder(scheme: colorScheme),
                lineWidth: 1
            )
    }

    // MARK: - Speaker rename popover

    private var speakerRenamePopover: some View {
        VStack(spacing: 8) {
            Text("Rename Speaker")
                .font(.caption.bold())
            TextField("Name", text: $speakerRenameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .onSubmit { commitRename() }
            HStack {
                Button("Cancel") { showingSpeakerRename = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Save") { commitRename() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(speakerRenameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
    }

    private func commitRename() {
        let name = speakerRenameText.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, let id = turn.speakerId {
            onRenameSpeaker(id, name)
        }
        showingSpeakerRename = false
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
