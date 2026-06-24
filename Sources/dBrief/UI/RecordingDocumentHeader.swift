import SwiftUI

/// One borderless metric in the header's right-hand group (e.g. Actions · Tags · Audio).
struct ViewerMetric: Identifiable {
    /// Stable key (e.g. "actions") so SwiftUI keeps view identity across renders
    /// instead of re-creating each metric when the header recomputes.
    let id: String
    let label: LocalizedStringKey
    let value: String

    /// Spoken form for VoiceOver, e.g. "Action items: 3".
    var accessibilityText: Text { Text(label) + Text(": \(value)") }
}

/// A speaker shown in the header avatar stack.
struct HeaderSpeaker: Identifiable {
    let id: String
    let name: String
    let isMe: Bool
}

/// Calm shared document header at the top of the recording viewer's detail pane.
///
/// Two rows: (1) title + optional sentiment pill, (2) avatar stack + date on the
/// left and a borderless, divider-separated metric group on the right. Sentiment
/// and each metric render only when their data exists, so an unanalyzed recording
/// collapses cleanly with no dangling dividers.
struct RecordingDocumentHeader: View {
    let title: String
    let sentiment: String?
    let speakers: [HeaderSpeaker]
    let date: Date
    let metrics: [ViewerMetric]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Row 1 — title + sentiment
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.system(size: 23, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: colorScheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let sentiment, !sentiment.isEmpty {
                    SentimentPill(sentiment: sentiment)
                }
                Spacer(minLength: 0)
            }

            // Row 2 — avatars + date  ·····  metrics
            HStack(alignment: .center, spacing: 12) {
                if !speakers.isEmpty {
                    AvatarStack(speakers: speakers)
                }
                Text(date, format: .dateTime.weekday().day().month().hour().minute())
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                if !metrics.isEmpty {
                    metricGroup
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    private var metricGroup: some View {
        HStack(spacing: 22) {
            ForEach(metrics) { metric in
                VStack(alignment: .center, spacing: 2) {
                    Text(metric.value)
                        .font(.system(size: 17, weight: .bold).monospacedDigit())
                        .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: colorScheme))
                    Text(metric.label)
                        .font(.system(size: 10, weight: .semibold).monospaced())
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(TranscriptDesignTokens.sectionLabel(scheme: colorScheme))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(metric.accessibilityText)
            }
        }
    }
}

/// Overlapping circular avatars for the header. Shows up to four, then a "+N" chip.
private struct AvatarStack: View {
    let speakers: [HeaderSpeaker]

    private let maxShown = 4
    private let size: CGFloat = 26

    var body: some View {
        let shown = Array(speakers.prefix(maxShown))
        let overflow = speakers.count - shown.count
        HStack(spacing: -8) {
            ForEach(shown) { speaker in
                SpeakerAvatar(
                    speakerId: speaker.id,
                    name: speaker.name,
                    size: size,
                    overrideColor: speaker.isMe ? .accentColor : nil
                )
                .overlay(Circle().stroke(.background, lineWidth: 1.5))
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(.quaternary, in: Circle())
                    .overlay(Circle().stroke(.background, lineWidth: 1.5))
                    .accessibilityLabel(Text("\(overflow) more speakers"))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Semantic sentiment pill: green / amber / red by tone, neutral otherwise.
struct SentimentPill: View {
    let sentiment: String

    private var tone: Color {
        switch sentiment.lowercased() {
        case let s where s.contains("pos"): return Color(hex: "30d158")
        case let s where s.contains("neg"): return Color(hex: "ff453a")
        default: return Color(hex: "ff9f0a")
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tone)
                .frame(width: 6, height: 6)
                .shadow(color: tone, radius: 4)
            Text(sentiment.capitalized)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(tone)
        .padding(.vertical, 4)
        .padding(.horizontal, 11)
        .background(tone.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(tone.opacity(0.3), lineWidth: 1))
        .accessibilityLabel(Text("Sentiment: \(sentiment)"))
    }
}
