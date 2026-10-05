import SwiftUI

// Building blocks for the "Signature" menu bar panel. Colours come only from the
// viewer palette (shared with the transcript viewer) and the panel's status
// palette, so Light, Dark, Paper, Dark Paper, the accent and Reduce neon all
// follow the user's appearance settings.

struct MenuPanelButtonStyle: ButtonStyle {
    enum Kind { case hero, secondary, row, danger, dangerFilled, accentOutline, tile, dangerTile, quiet }
    var kind: Kind
    var height: CGFloat = 33
    var fontSize: CGFloat? = nil
    /// Secondary actions stretch to share a row; set false for a button sized to its label.
    var fillsWidth = true
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: kind == .hero ? 11 : 8, style: .continuous)
        configuration.label
            .uiFont(.system(size: fontSize ?? defaultFontSize, weight: kind == .hero ? .semibold : .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, kind == .quiet ? 0 : 11)
            .frame(maxWidth: kind == .quiet || !fillsWidth ? nil : .infinity, minHeight: height)
            .background(background, in: shape)
            .overlay {
                if let border {
                    shape.strokeBorder(border, lineWidth: kind == .accentOutline ? 1.5 : 1).allowsHitTesting(false)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
            .contentShape(shape)
    }

    private var defaultFontSize: CGFloat {
        switch kind {
        case .hero: 18
        case .tile, .dangerTile, .quiet: 12
        default: 13
        }
    }

    private var foreground: Color {
        switch kind {
        case .hero: palette.onPrimary.color
        case .danger, .dangerTile: status.danger.color
        case .dangerFilled: status.onDanger.color
        case .accentOutline: palette.heading.color
        case .quiet: palette.secondary.color
        default: palette.text.color
        }
    }

    private var background: Color {
        switch kind {
        case .hero: palette.primary.color
        case .row: palette.canvas.color
        case .danger, .dangerTile: status.dangerFill.color
        case .dangerFilled: status.danger.color
        case .quiet: .clear
        default: palette.surface.color
        }
    }

    private var border: Color? {
        switch kind {
        case .hero, .quiet, .dangerFilled: nil
        case .danger, .dangerTile: status.dangerBorder.color
        case .accentOutline: palette.primary.color
        default: palette.divider.color
        }
    }
}

/// A flat strip of the panel, split from the next by a full-bleed hairline.
struct MenuPanelSection<Content: View>: View {
    var showsDivider = true
    var spacing: CGFloat = 10
    var verticalPadding: CGFloat = 14
    @ViewBuilder var content: Content
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                if showsDivider { MenuPanelHairline() }
            }
    }
}

struct MenuPanelHairline: View {
    @Environment(\.viewerPalette) private var palette
    var body: some View {
        Rectangle().fill(palette.divider.color).frame(height: 1).accessibilityHidden(true)
    }
}

/// Label chrome for the panel's dropdowns (profile, microphone, meeting).
struct MenuPanelSelectorLabel: View {
    let text: String
    var tint: Color? = nil
    var height: CGFloat = 28
    var filled = true
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .uiFont(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(tint ?? palette.heading.color)
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(filled ? palette.canvas.color : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            if filled {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(palette.divider.color, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The dBrief mark: five rounded bars in the brand stops (flat accent when Reduce neon is on).
struct BrandBarsMark: View {
    @Environment(\.viewerPalette) private var palette
    var height: CGFloat = 24
    private let ratios: [CGFloat] = [9, 18, 24, 15, 7].map { $0 / 24 }

    var body: some View {
        HStack(alignment: .center, spacing: max(1, height / 12)) {
            ForEach(Array(ratios.enumerated()), id: \.offset) { index, ratio in
                RoundedRectangle(cornerRadius: 2)
                    .fill(palette.brandStops[min(index + 1, palette.brandStops.count - 1)].color)
                    .frame(width: max(2, height / 8), height: height * ratio)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

extension MenuPanelStatus.Tone {
    func color(palette: ViewerPalette, status: MenuPanelPalette) -> Color {
        switch self {
        case .success: status.success.color
        case .danger: status.danger.color
        case .warning: status.warning.color
        case .accent: palette.primary.color
        }
    }
}

struct MenuPanelStatusDot: View {
    let tone: MenuPanelStatus.Tone
    var pulse = false
    var size: CGFloat = 7
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(tone.color(palette: palette, status: status))
            .frame(width: size, height: size)
            .opacity(Self.opacity(pulse: pulse && !reduceMotion, dimmed: dimmed))
            .onAppear { startPulse() }
            .onChange(of: pulse) { _, _ in startPulse() }
            .accessibilityHidden(true)
    }

    /// Dimming only shows while pulsing, so a stopped or re-appearing dot is never stuck pale.
    static func opacity(pulse: Bool, dimmed: Bool) -> Double {
        pulse && dimmed ? 0.35 : 1
    }

    private func startPulse() {
        dimmed = false
        guard pulse, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dimmed = true }
    }
}

/// Live input level as a row of thin accent bars.
struct MenuPanelLevelBars: View {
    let level: Float
    var active = true
    var height: CGFloat = 37
    @Environment(\.menuPanelPalette) private var status

    private static let barWidth: CGFloat = 3
    private static let gap: CGFloat = 3

    var body: some View {
        let colour = status.accentMark.color
        let shown = CGFloat(AudioLevelMeter.displayLevel(level))
        Canvas { context, size in
            let count = max(1, Int((size.width + Self.gap) / (Self.barWidth + Self.gap)))
            let used = CGFloat(count) * Self.barWidth + CGFloat(count - 1) * Self.gap
            var x = (size.width - used) / 2
            for index in 0..<count {
                let h = max(4, (0.15 + 0.85 * Self.profile(index) * shown) * size.height)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: Self.barWidth, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(colour))
                x += Self.barWidth + Self.gap
            }
        }
        .frame(height: height)
        .opacity(active ? 1 : 0.4)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(shown * 100)) percent")
    }

    /// Stable pseudo-random shape so the strip reads as a waveform at any level.
    private static func profile(_ index: Int) -> CGFloat {
        let value = sin(Double(index) * 12.9898) * 43_758.5453
        return CGFloat(0.25 + 0.75 * (value - value.rounded(.down)))
    }
}

extension View {
    /// The 360 pt panel card: surface fill, hairline border, radius 18.
    func menuPanelCard(palette: ViewerPalette) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return self
            .background(palette.surface.color, in: shape)
            .clipShape(shape)
            .overlay { shape.strokeBorder(palette.divider.color, lineWidth: 1).allowsHitTesting(false) }
    }
}
