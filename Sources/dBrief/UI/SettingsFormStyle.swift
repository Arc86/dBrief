import AppKit
import SwiftUI

/// A page background: the paper palette's canvas under a paper theme, otherwise
/// `system`, or the white / near-black canvas of System Settings when nil.
struct SettingsCanvasStyle: ShapeStyle {
    var system: NSColor?

    func resolve(in environment: EnvironmentValues) -> Color {
        if environment.viewerMode.isPaper { return environment.viewerPalette.canvas.color }
        if let system { return Color(nsColor: system) }
        return environment.colorScheme == .dark ? Color(white: 28.0 / 255.0) : .white
    }
}

/// Opaque fill for cards, lists, and text fields inside Settings and its
/// editors. System backgrounds are neutral white/black, which clashes with the
/// warm paper themes, so paper themes use the palette's surface instead.
struct SettingsSurfaceStyle: ShapeStyle {
    /// The fill outside the paper themes.
    var system: NSColor = .controlBackgroundColor

    func resolve(in environment: EnvironmentValues) -> Color {
        environment.viewerMode.isPaper ? environment.viewerPalette.surface.color : Color(nsColor: system)
    }
}

extension ShapeStyle where Self == SettingsCanvasStyle {
    static var settingsCanvas: SettingsCanvasStyle { .init() }
    /// The paper canvas, or the plain window background outside paper themes.
    static var settingsWindowCanvas: SettingsCanvasStyle { .init(system: .windowBackgroundColor) }
}

extension ShapeStyle where Self == SettingsSurfaceStyle {
    static var settingsSurface: SettingsSurfaceStyle { .init() }
    /// A text-editing surface: white/black outside the paper themes.
    static var settingsTextSurface: SettingsSurfaceStyle { .init(system: .textBackgroundColor) }
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

extension View {
    /// Use instead of `.textFieldStyle(.roundedBorder)` for fields in Settings.
    func settingsTextField() -> some View {
        modifier(SettingsTextFieldModifier())
    }

    /// Padding, surface fill, and hairline of a paper-theme text field.
    func settingsFieldChrome() -> some View {
        padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.settingsSurface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
            }
    }
}
