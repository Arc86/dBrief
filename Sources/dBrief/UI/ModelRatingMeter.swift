import SwiftUI

enum ModelRatingKind {
    case speed, accuracy

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
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status

    var body: some View {
        HStack(spacing: 8) {
            Text(kind.label)
                .foregroundStyle(palette.secondary.color)
                .frame(width: 52, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(index <= (value ?? 0) ? fill : palette.divider.color)
                        .frame(minWidth: 10, minHeight: 5, maxHeight: 5)
                }
            }
            Text(value.map(kind.word) ?? String(localized: "Not rated"))
                .foregroundStyle(palette.text.color)
                .frame(width: 58, alignment: .trailing)
        }
        .uiFont(.system(size: 11))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.label)
        .accessibilityValue(value.map { String(localized: "\(kind.word($0)), \($0) out of 5, estimated") }
                            ?? String(localized: "Not rated"))
    }

    private var fill: Color { kind == .speed ? status.success.color : palette.accentText.color }
}
