import AppKit
import Testing
@testable import dBrief

@MainActor
@Suite("Reading fonts")
struct ReadingFontTests {
    @Test(arguments: [
        (ViewerReadingFont.arial, "Arial"), (.helvetica, "Helvetica"),
        (.timesNewRoman, "Times New Roman"), (.verdana, "Verdana"), (.georgia, "Georgia"),
    ])
    func builtInFontsResolveToTheirFamily(font: ViewerReadingFont, family: String) {
        #expect(ViewerFonts.nsFont(for: font, size: 20, effectiveMode: .light).familyName == family)
        #expect(ViewerFonts.isAvailable(font))
    }

    @Test func calibriIsOfferedOnlyWhenInstalled() {
        #expect(ViewerFonts.isAvailable(.calibri) == (NSFont(name: "Calibri", size: 12) != nil))
    }

    @Test func choicesAreUniqueAndKeepTheCurrentFontEvenIfUnavailable() {
        let names = ViewerReadingFont.allCases.map(\.displayName)
        #expect(Set(names).count == names.count)
        let choices = ViewerFonts.choices(keeping: .calibri)
        #expect(choices.contains(.calibri))
        #expect(choices.first == .systemDefault)
        #expect(ViewerFonts.choices(keeping: .inter).allSatisfy { ViewerFonts.isAvailable($0) || $0 == .inter })
    }

    @Test func savedFontsFromBeforeTheNewOptionsStillDecode() throws {
        for raw in ["systemDefault", "sanFrancisco", "inter", "georgia", "openDyslexic", "monospace"] {
            #expect(ViewerReadingFont(rawValue: raw) != nil)
        }
    }
}

@MainActor
@Suite("Reading font headings")
struct ReadingFontHeadingTests {
    @Test(arguments: [ViewerReadingFont.georgia, .verdana, .timesNewRoman, .sanFrancisco])
    func headingsUseTheReadingFamilyScaledAndBold(font: ViewerReadingFont) {
        var preferences = ViewerAppearancePreferences()
        preferences.readingFont = font
        preferences.displaySizeOverride = 20
        let body = ViewerFonts.nsFont(for: preferences, effectiveMode: .light)
        let heading = ViewerFonts.nsFont(for: preferences, scale: 2, bold: true, effectiveMode: .light)
        #expect(heading.familyName == body.familyName)
        #expect(heading.pointSize == 40)
        #expect(NSFontManager.shared.traits(of: heading).contains(.boldFontMask))
        #expect(ViewerFonts.nsFont(for: preferences, scale: 0.85, bold: false, effectiveMode: .light).pointSize == 17)
    }
}
