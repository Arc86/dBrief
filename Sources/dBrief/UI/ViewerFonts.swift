import AppKit
import CoreText
import SwiftUI

/// Resolves viewer fonts and lazily registers the bundled reading families.
@MainActor
enum ViewerFonts {
    private static let registration: Void = {
        for ext in ["otf", "ttf"] {
            for url in Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Fonts") ?? [] {
                _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()

    /// PostScript name of each named reading font (nil: a system font).
    private static func postScriptName(for font: ViewerReadingFont) -> String? {
        switch font {
        case .systemDefault, .sanFrancisco, .monospace: nil
        case .arial: "ArialMT"
        case .calibri: "Calibri"
        case .ebGaramond: "EBGaramond-Regular"
        case .georgia: "Georgia"
        case .helvetica: "Helvetica"
        case .inter: "Inter-Regular"
        case .lato: "Lato-Regular"
        case .openSans: "OpenSans-Regular"
        case .roboto: "Roboto-Regular"
        case .timesNewRoman: "TimesNewRomanPSMT"
        case .verdana: "Verdana"
        case .openDyslexic: "OpenDyslexic-Regular"
        }
    }

    /// Whether the font can be shown: bundled and macOS fonts always; Calibri
    /// only when the user has it installed.
    static func isAvailable(_ font: ViewerReadingFont) -> Bool {
        guard let name = postScriptName(for: font) else { return true }
        registerBundledFontsIfNeeded()
        return NSFont(name: name, size: 12) != nil
    }

    /// Fonts to offer in a picker: the available ones, plus `current` so a saved
    /// choice never disappears from the menu.
    static func choices(keeping current: ViewerReadingFont?) -> [ViewerReadingFont] {
        ViewerReadingFont.allCases.filter { isAvailable($0) || $0 == current }
    }

    static func registerBundledFontsIfNeeded() {
        _ = registration
    }

    static func font(
        for preferences: ViewerAppearancePreferences,
        effectiveMode: ViewerAppearanceMode
    ) -> Font {
        Font(nsFont(for: preferences, effectiveMode: effectiveMode))
    }

    static func nsFont(
        for preferences: ViewerAppearancePreferences,
        effectiveMode: ViewerAppearanceMode
    ) -> NSFont {
        nsFont(for: preferences.readingFont, size: CGFloat(preferences.effectiveFontSize), effectiveMode: effectiveMode)
    }

    static func nsFont(
        for readingFont: ViewerReadingFont,
        size: CGFloat,
        effectiveMode: ViewerAppearanceMode
    ) -> NSFont {
        switch readingFont {
        case .systemDefault:
            if effectiveMode.isPaper {
                return NSFont(name: "Georgia", size: size) ?? NSFont.systemFont(ofSize: size)
            }
            return NSFont.systemFont(ofSize: size)
        case .sanFrancisco:
            return NSFont.systemFont(ofSize: size)
        case .monospace:
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        default:
            registerBundledFontsIfNeeded()
            return postScriptName(for: readingFont).flatMap { NSFont(name: $0, size: size) }
                ?? NSFont.systemFont(ofSize: size)
        }
    }

    /// Returns the additional paragraph line spacing needed to meet the selected
    /// density's target after accounting for the chosen font's actual metrics.
    static func additionalLineSpacing(
        for preferences: ViewerAppearancePreferences,
        effectiveMode: ViewerAppearanceMode
    ) -> CGFloat {
        let font = nsFont(for: preferences, effectiveMode: effectiveMode)
        let naturalLineHeight = max(0, font.ascender - font.descender + font.leading)
        let targetLineHeight = CGFloat(preferences.effectiveFontSize)
            * CGFloat(preferences.displayLineHeightOverride ?? preferences.density.lineHeightTarget)
        return max(0, targetLineHeight - naturalLineHeight)
    }
}
