import AppKit
import SwiftUI

extension ViewerRGB {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

private struct ViewerPaletteKey: EnvironmentKey {
    static let defaultValue = ViewerThemeResolver.resolve(mode: .light, sourceHex: "#1268F5", nonNeon: false)
}
private struct ViewerReadingKey: EnvironmentKey {
    static let defaultValue = ViewerAppearancePreferences(mode: nil, sourceAccentHex: "#1268F5", readingFont: .systemDefault, density: .comfortable, fontSize: 16, showSpeakerNames: true)
}
private struct ViewerModeKey: EnvironmentKey {
    static let defaultValue = ViewerAppearanceMode.light
}
private struct ViewerNonNeonKey: EnvironmentKey {
    static let defaultValue = false
}
private struct MenuPanelPaletteKey: EnvironmentKey {
    static let defaultValue = MenuPanelPalette.resolve(mode: .light, base: ViewerPaletteKey.defaultValue)
}

extension EnvironmentValues {
    var viewerPalette: ViewerPalette {
        get { self[ViewerPaletteKey.self] }
        set { self[ViewerPaletteKey.self] = newValue }
    }
    var viewerReading: ViewerAppearancePreferences {
        get { self[ViewerReadingKey.self] }
        set { self[ViewerReadingKey.self] = newValue }
    }
    var viewerMode: ViewerAppearanceMode {
        get { self[ViewerModeKey.self] }
        set { self[ViewerModeKey.self] = newValue }
    }
    var viewerNonNeon: Bool {
        get { self[ViewerNonNeonKey.self] }
        set { self[ViewerNonNeonKey.self] = newValue }
    }
    var menuPanelPalette: MenuPanelPalette {
        get { self[MenuPanelPaletteKey.self] }
        set { self[MenuPanelPaletteKey.self] = newValue }
    }
}

extension AppThemeMode {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }
}

/// Supplies the selected light or dark palette to the recording viewer family.
struct ViewerAppearanceScope: ViewModifier {
    let settings: AppSettings
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        let reading = settings.viewerAppearance
        let mode = reading.effectiveMode(systemIsDark: systemScheme == .dark)
        let palette = ViewerThemeResolver.resolve(mode: mode, sourceHex: reading.sourceAccentHex, nonNeon: settings.reduceNeon)
        content
            .environment(\.viewerPalette, palette)
            .environment(\.viewerReading, reading)
            .environment(\.viewerMode, mode)
            .environment(\.viewerNonNeon, settings.reduceNeon)
            .tint(palette.primary.color)
            .preferredColorScheme(reading.themeMode.preferredColorScheme)
    }
}

struct ViewerCard: ViewModifier {
    @Environment(\.viewerPalette) private var palette
    func body(content: Content) -> some View {
        content
            .background(palette.surface.color, in: RoundedRectangle(cornerRadius: palette.readingCardCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: palette.readingCardCornerRadius)
                    .strokeBorder(palette.divider.color, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}
