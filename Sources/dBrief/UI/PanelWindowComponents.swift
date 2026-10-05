import SwiftUI

// The menu panel's design language for the small windows it opens (reprocess,
// calendar link, speaker review): canvas background, cards on the surface colour,
// palette text, and the panel's button styles — instead of stock grouped forms.

/// Title block at the top of a panel window.
struct PanelWindowHeader: View {
    let title: String
    var subtitle: String? = nil
    var detail: String? = nil
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .uiFont(.system(size: 18, weight: .semibold))
                .foregroundStyle(palette.heading.color)
            if let subtitle {
                Text(subtitle)
                    .uiFont(.system(size: 12))
                    .foregroundStyle(palette.text.color)
                    .lineLimit(2)
            }
            if let detail {
                Text(detail)
                    .uiFont(.system(size: 11))
                    .foregroundStyle(palette.secondary.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A titled group of settings on the surface colour, split by hairlines.
struct PanelCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .uiFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.secondary.color)
                    .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.surface.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.divider.color, lineWidth: 1)
                        .allowsHitTesting(false)
                }
        }
    }
}

/// A label on the left, its control or value on the right.
struct PanelRow<Trailing: View>: View {
    let label: String
    @ViewBuilder var trailing: Trailing
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .uiFont(.system(size: 12))
                .foregroundStyle(palette.heading.color)
            Spacer(minLength: 8)
            trailing
                .uiFont(.system(size: 12))
                .foregroundStyle(palette.text.color)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Secondary explanation inside a card or below it.
struct PanelNote: View {
    let text: String
    var tone: MenuPanelStatus.Tone? = nil
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status

    init(_ text: String, tone: MenuPanelStatus.Tone? = nil) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .uiFont(.system(size: 11))
            .foregroundStyle(tone?.color(palette: palette, status: status) ?? palette.secondary.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small inline spinner with its label beside it.
struct PanelProgressLabel: View {
    let text: String
    @Environment(\.viewerPalette) private var palette

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .uiFont(.system(size: 12))
                .foregroundStyle(palette.secondary.color)
        }
    }
}

extension View {
    /// Panel-style text field: canvas fill, hairline border, 30 pt tall.
    func panelTextField(height: CGFloat = 30) -> some View {
        modifier(PanelTextFieldModifier(height: height))
    }

    /// Window chrome for panel windows: canvas background, accent tint, switch toggles.
    func panelWindowChrome() -> some View {
        modifier(PanelWindowChrome())
    }
}

private struct PanelTextFieldModifier: ViewModifier {
    let height: CGFloat
    @Environment(\.viewerPalette) private var palette

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .uiFont(.system(size: 12))
            .foregroundStyle(palette.heading.color)
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(palette.canvas.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(palette.divider.color, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

private struct PanelWindowChrome: ViewModifier {
    @Environment(\.viewerPalette) private var palette

    func body(content: Content) -> some View {
        content
            .toggleStyle(.switch)
            .tint(palette.primary.color)
            .background(palette.canvas.color)
    }
}
