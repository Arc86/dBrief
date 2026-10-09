import SwiftUI

/// A Settings page background: the palette canvas, as `SettingsView` paints it.
struct SettingsCanvasStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.viewerPalette.canvas.color
    }
}

extension ShapeStyle where Self == SettingsCanvasStyle {
    static var settingsCanvas: SettingsCanvasStyle { .init() }
}

/// Native rounded-bezel text fields always fill with the system text background,
/// so under a paper theme draw a plain field on the palette surface instead.
private struct SettingsTextFieldModifier: ViewModifier {
    @Environment(\.viewerMode) private var mode

    func body(content: Content) -> some View {
        if mode.isPaper {
            content
                .textFieldStyle(.plain)
                .settingsFieldChrome()
        } else {
            content.textFieldStyle(.roundedBorder)
        }
    }
}

/// Padding, surface fill, and hairline of a paper-theme text field. The hairline
/// stays stronger than `divider`: the fill matches the card it sits on.
private struct SettingsFieldChromeModifier: ViewModifier {
    @Environment(\.viewerPalette) private var palette

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(palette.surface.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(palette.heading.color.opacity(0.15), lineWidth: 1)
            }
    }
}

extension View {
    /// Use instead of `.textFieldStyle(.roundedBorder)` for fields in Settings.
    func settingsTextField() -> some View {
        modifier(SettingsTextFieldModifier())
    }

    /// Padding, surface fill, and hairline of a paper-theme text field.
    func settingsFieldChrome() -> some View {
        modifier(SettingsFieldChromeModifier())
    }
}
