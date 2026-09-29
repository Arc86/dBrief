import AppKit
import CoreText
import SwiftUI

/// Resolves viewer fonts and lazily registers the bundled reading families.
@MainActor
enum ViewerFonts {
    private static let registration: Void = {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: "Fonts") else { return }
        for url in urls {
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

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
        nsFont(for: preferences.readingFont, size: CGFloat(preferences.fontSize), effectiveMode: effectiveMode)
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
        case .inter:
            registerBundledFontsIfNeeded()
            return NSFont(name: "Inter-Regular", size: size) ?? NSFont.systemFont(ofSize: size)
        case .georgia:
            return NSFont(name: "Georgia", size: size) ?? NSFont.systemFont(ofSize: size)
        case .openDyslexic:
            registerBundledFontsIfNeeded()
            return NSFont(name: "OpenDyslexic-Regular", size: size) ?? NSFont.systemFont(ofSize: size)
        case .monospace:
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
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
        let targetLineHeight = CGFloat(preferences.fontSize) * CGFloat(preferences.density.lineHeightTarget)
        return max(0, targetLineHeight - naturalLineHeight)
    }
}
