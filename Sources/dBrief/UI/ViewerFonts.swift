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

    /// PostScript name of the fonts dBrief names exactly; the others resolve by
    /// family (nil: a system font, or a family lookup).
    private static func postScriptName(for font: ViewerReadingFont) -> String? {
        switch font {
        case .arial: "ArialMT"
        case .calibri: "Calibri"
        case .ebGaramond: "EBGaramond-Regular"
        case .georgia: "Georgia"
        case .helvetica: "Helvetica"
        case .inter: "Inter-Regular"
        case .lato: "Lato-Regular"
        case .lexend: "Lexend-Regular"
        case .openSans: "OpenSans-Regular"
        case .roboto: "Roboto-Regular"
        case .timesNewRoman: "TimesNewRomanPSMT"
        case .verdana: "Verdana"
        case .openDyslexic: "OpenDyslexic-Regular"
        default: nil
        }
    }

    /// The regular face of a named or installed font, or nil when it isn't
    /// installed (or is a system-font choice).
    private static func regularFont(for font: ViewerReadingFont, size: CGFloat) -> NSFont? {
        registerBundledFontsIfNeeded()
        if let name = postScriptName(for: font) { return NSFont(name: name, size: size) }
        guard let family = font.familyName else { return nil }
        return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
    }

    /// Whether the font can be shown: bundled and macOS fonts always; Calibri,
    /// Dyslexie and installed families only while the user has them.
    static func isAvailable(_ font: ViewerReadingFont) -> Bool {
        font.familyName == nil || regularFont(for: font, size: 12) != nil
    }

    /// Fonts to offer in a picker: the available ones, plus `current` so a saved
    /// choice never disappears from the menu. Reading menus also lead with
    /// "Same as Interface Text".
    static func choices(keeping current: ViewerReadingFont?,
                        includingSameAsInterface: Bool = false) -> [ViewerReadingFont] {
        var fonts = ViewerReadingFont.allCases.filter { isAvailable($0) || $0 == current }
        if let current, !fonts.contains(current), current != .sameAsInterface { fonts.append(current) }
        if includingSameAsInterface { fonts.insert(.sameAsInterface, at: 0) }
        return fonts
    }

    /// Installed font families for "Other Font…", without hidden system families.
    static func installedFamilies() -> [String] {
        registerBundledFontsIfNeeded()
        return NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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

    /// The reading font at `scale` × the reading size, optionally bold: titles
    /// and headings in the same family as the text they introduce.
    static func nsFont(
        for preferences: ViewerAppearancePreferences,
        scale: CGFloat,
        bold: Bool,
        effectiveMode: ViewerAppearanceMode
    ) -> NSFont {
        let font = nsFont(for: preferences.readingFont, size: CGFloat(preferences.effectiveFontSize) * scale,
                          effectiveMode: effectiveMode)
        return bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
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
        case .sanFrancisco, .sameAsInterface:
            return NSFont.systemFont(ofSize: size)
        case .monospace:
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        default:
            return regularFont(for: readingFont, size: size) ?? NSFont.systemFont(ofSize: size)
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
