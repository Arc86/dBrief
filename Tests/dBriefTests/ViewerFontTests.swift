import AppKit
import CoreText
import Testing
@testable import dBrief

@Suite struct ViewerFontTests {
    @Test @MainActor
    func explicitSanFranciscoUsesSystemFontInEveryTheme() throws {
        let choice = try #require(ViewerReadingFont(rawValue: "sanFrancisco"))
        for mode in ViewerAppearanceMode.allCases {
            let preferences = ViewerAppearancePreferences(readingFont: choice, fontSize: 18)
            let font = ViewerFonts.nsFont(for: preferences, effectiveMode: mode)
            #expect(font == NSFont.systemFont(ofSize: 18))
        }
    }

    @Test @MainActor
    func bundledInterResolvesWithEmphasisInEveryTheme() throws {
        let choice = try #require(ViewerReadingFont(rawValue: "inter"))
        // SwiftPM excludes app resources; register the same assets copied by make app.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("Sources/dBrief/Resources/Fonts")
        for name in ["Inter-Regular", "Inter-Bold", "Inter-Italic", "Inter-BoldItalic"] {
            let url = directory.appendingPathComponent("\(name).otf")
            #expect(FileManager.default.fileExists(atPath: url.path))
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        for mode in ViewerAppearanceMode.allCases {
            let preferences = ViewerAppearancePreferences(readingFont: choice, fontSize: 18)
            let font = ViewerFonts.nsFont(for: preferences, effectiveMode: mode)
            #expect(font.familyName == "Inter")
            #expect(font.fontName == "Inter-Regular")
            #expect(font.pointSize == 18)
            for traits: NSFontTraitMask in [.boldFontMask, .italicFontMask, [.boldFontMask, .italicFontMask]] {
                let emphasis = NSFontManager.shared.convert(font, toHaveTrait: traits)
                #expect(emphasis.familyName == "Inter")
                #expect(NSFontManager.shared.traits(of: emphasis).contains(traits))
            }
        }
    }
}
