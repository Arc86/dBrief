import AppKit
import CoreText
import Foundation
import Testing
@testable import dBrief

@MainActor
@Suite("Reading font choices")
struct ReadingFontChoiceTests {
    static let legacyRawValues = [
        "systemDefault", "sanFrancisco", "arial", "calibri", "ebGaramond", "georgia", "helvetica",
        "inter", "lato", "openSans", "roboto", "timesNewRoman", "verdana", "openDyslexic", "monospace",
    ]

    @Test func savedFontsKeepTheirStoredValue() throws {
        for raw in Self.legacyRawValues {
            let font = try #require(ViewerReadingFont(rawValue: raw))
            #expect(font.rawValue == raw)
        }
    }

    @Test func installedFontsRoundTripByFamilyName() throws {
        let font = try #require(ViewerReadingFont(rawValue: "installed:Avenir Next"))
        #expect(font == .installed("Avenir Next"))
        #expect(font.rawValue == "installed:Avenir Next")
        #expect(font.displayName == "Avenir Next")
        #expect(ViewerReadingFont(rawValue: "installed:") == nil)
        #expect(ViewerReadingFont(rawValue: "nonsense") == nil)
    }

    @Test func codableUsesTheStoredValue() throws {
        let fonts: [ViewerReadingFont] = [.arial, .installed("Avenir Next"), .sameAsInterface]
        let data = try JSONEncoder().encode(fonts)
        #expect(String(decoding: data, as: UTF8.self) == #"["arial","installed:Avenir Next","sameAsInterface"]"#)
        #expect(try JSONDecoder().decode([ViewerReadingFont].self, from: data) == fonts)
    }

    @Test func aFamilyOnTheListMapsToItsNamedChoice() {
        #expect(ViewerReadingFont.forFamily("Arial") == .arial)
        #expect(ViewerReadingFont.forFamily("Lexend") == .lexend)
        #expect(ViewerReadingFont.forFamily("Trebuchet MS") == .trebuchetMS)
        #expect(ViewerReadingFont.forFamily("Avenir Next") == .installed("Avenir Next"))
    }

    @Test func anInstalledFamilyResolvesWithEmphasis() {
        let font = ViewerFonts.nsFont(for: .installed("Avenir Next"), size: 18, effectiveMode: .light)
        #expect(font.familyName == "Avenir Next")
        #expect(font.pointSize == 18)
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        #expect(bold.familyName == "Avenir Next")
        #expect(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        #expect(ViewerFonts.isAvailable(.installed("Avenir Next")))
    }

    @Test func aRemovedFontFallsBackToTheSystemFontButStaysInTheMenu() {
        let missing = ViewerReadingFont.installed("No Such Font dBrief")
        #expect(!ViewerFonts.isAvailable(missing))
        #expect(ViewerFonts.nsFont(for: missing, size: 15, effectiveMode: .light) == NSFont.systemFont(ofSize: 15))
        #expect(ViewerFonts.choices(keeping: missing).contains(missing))
        #expect(!ViewerFonts.choices(keeping: .arial).contains(missing))
    }

    @Test(arguments: [(ViewerReadingFont.tahoma, "Tahoma"), (.trebuchetMS, "Trebuchet MS")])
    func macOSFontsResolveToTheirFamily(font: ViewerReadingFont, family: String) {
        #expect(ViewerFonts.isAvailable(font))
        #expect(ViewerFonts.nsFont(for: font, size: 16, effectiveMode: .light).familyName == family)
    }

    @Test func dyslexieIsOfferedOnlyWhenInstalled() {
        let installed = NSFontManager.shared.availableFontFamilies.contains("Dyslexie")
        #expect(ViewerFonts.isAvailable(.dyslexie) == installed)
        #expect(ViewerFonts.choices(keeping: nil).contains(.dyslexie) == installed)
    }

    @Test func bundledLexendResolvesWithBold() throws {
        // SwiftPM excludes app resources; register the same file copied by make app.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/dBrief/Resources/Fonts/Lexend-Variable.ttf")
        #expect(FileManager.default.fileExists(atPath: url.path))
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        let font = ViewerFonts.nsFont(for: .lexend, size: 18, effectiveMode: .light)
        #expect(font.familyName == "Lexend")
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        #expect(bold.familyName == "Lexend")
        #expect(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
    }

    @Test func sameAsInterfaceIsOfferedOnlyForReading() {
        #expect(!ViewerReadingFont.allCases.contains(.sameAsInterface))
        #expect(!ViewerFonts.choices(keeping: nil).contains(.sameAsInterface))
        let reading = ViewerFonts.choices(keeping: nil, includingSameAsInterface: true)
        #expect(reading.first == .sameAsInterface)
        #expect(reading.dropFirst().first == .systemDefault)
    }

    @Test func sameAsInterfaceFollowsTheInterfaceFont() {
        let preferences = ViewerAppearancePreferences(readingFont: .sameAsInterface)
        #expect(preferences.resolvingInterfaceFont(.verdana).readingFont == .verdana)
        #expect(preferences.resolvingInterfaceFont(.installed("Avenir Next")).readingFont == .installed("Avenir Next"))
        // The interface's Default is the system font, never Paper's Georgia.
        #expect(preferences.resolvingInterfaceFont(.systemDefault).readingFont == .sanFrancisco)
        let own = ViewerAppearancePreferences(readingFont: .georgia)
        #expect(own.resolvingInterfaceFont(.verdana).readingFont == .georgia)
    }

    @Test func editorFontFamiliesAreQuotedCSS() {
        #expect(MarkdownEditorTheme.fontFamily(for: .lexend, mode: .light).hasPrefix("\"dBrief Lexend\""))
        #expect(MarkdownEditorTheme.fontFamily(for: .trebuchetMS, mode: .light).hasPrefix("\"Trebuchet MS\""))
        #expect(MarkdownEditorTheme.fontFamily(for: .installed("Avenir Next"), mode: .light)
            == "\"Avenir Next\", -apple-system, sans-serif")
        #expect(MarkdownEditorTheme.fontFamily(for: .installed("Odd \"Name\\"), mode: .light)
            == #""Odd \"Name\\", -apple-system, sans-serif"#)
    }
}
