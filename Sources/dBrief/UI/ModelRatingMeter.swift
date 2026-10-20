import SwiftUI

enum ModelRatingKind: CaseIterable {
    case speed, accuracy

    /// Every word either meter can show, so its column fits the longest one.
    static var allWords: [String] {
        allCases.flatMap { kind in (1...5).map(kind.word) } + [String(localized: "Not rated")]
    }

    var label: String { self == .speed ? String(localized: "Speed") : String(localized: "Accuracy") }

    /// Word for a 1...5 estimate (out-of-range values clamp).
    func word(_ value: Int) -> String {
        let index = min(max(value, 1), 5) - 1
        switch self {
        case .speed: return [String(localized: "Very slow"), String(localized: "Slow"), String(localized: "Moderate"),
                              String(localized: "Fast"), String(localized: "Very fast")][index]
        case .accuracy: return [String(localized: "Basic"), String(localized: "Fair"), String(localized: "Good"),
                                 String(localized: "Very good"), String(localized: "Excellent")][index]
        }
    }
}

/// Five segments plus a word: shared by the Quick pick tiles and the inspector.
struct ModelRatingMeter: View {
    let kind: ModelRatingKind
    let value: Int?
    /// Narrow places (Quick pick tiles) put the label above the bar, so a long
    /// translated label never squeezes the bar or breaks mid-word.
    var stacked = false
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 3) {
                    label
                    HStack(spacing: 8) { bars; word }
                }
            } else {
                // Both columns reserve the widest label or word of either meter, so the bars
                // of stacked meters line up and longer translations never break mid-word.
                HStack(spacing: 8) {
                    WidestText(options: ModelRatingKind.allCases.map(\.label), shown: kind.label, alignment: .leading)
                        .foregroundStyle(palette.secondary.color)
                    bars
                    word
                }
            }
        }
        .uiFont(.system(size: 11))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.label)
        .accessibilityValue(value.map { String(localized: "\(kind.word($0)), \($0) out of 5, estimated") }
                            ?? String(localized: "Not rated"))
    }

    private var label: some View {
        Text(kind.label).foregroundStyle(palette.secondary.color).lineLimit(1)
    }

    private var bars: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index <= (value ?? 0) ? fill : palette.divider.color)
                    .frame(minWidth: 10, minHeight: 5, maxHeight: 5)
            }
        }
    }

    private var word: some View {
        WidestText(options: ModelRatingKind.allWords, shown: value.map(kind.word) ?? String(localized: "Not rated"),
                   alignment: .trailing)
            .foregroundStyle(palette.text.color)
    }

    private var fill: Color { kind == .speed ? status.success.color : palette.accentText.color }
}

/// Shows `shown` in a frame as wide as the widest of `options`: hidden copies reserve
/// the space without a fixed point width.
private struct WidestText: View {
    let options: [String]
    let shown: String
    let alignment: Alignment

    var body: some View {
        ZStack(alignment: alignment) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Text(option).hidden()
            }
            Text(shown)
        }
        .lineLimit(1)
        .fixedSize()
    }
}
