import AppKit
import CoreText
import Testing
@testable import dBrief

@Suite struct AppTypographyTests {
    @Test func storesUIFontsSeparatelyFromTranscriptPreferences() {
        let suite = "ui-typography-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let reading = ViewerAppearancePreferences(mode: .paper, readingFont: .georgia, fontSize: 19)
        reading.save(to: defaults)
        for font in ViewerReadingFont.allCases {
            let ui = AppTypographyPreferences(readingFont: font, fontSize: 17)
            ui.save(to: defaults)
            #expect(AppTypographyPreferences.load(from: defaults) == ui)
            #expect(ViewerAppearancePreferences.load(from: defaults) == reading)
        }
    }

    @Test func malformedPreferencesAndAssignedSizesStayWithinBounds() {
        let suite = "ui-typography-invalid-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppTypographyPreferences.load(from: defaults) == AppTypographyPreferences())
        defaults.set("unknown", forKey: "uiFont")
        defaults.set(100, forKey: "uiFontSize")
        #expect(AppTypographyPreferences.load(from: defaults) == AppTypographyPreferences(fontSize: 20))
        defaults.set(-1, forKey: "uiFontSize")
        #expect(AppTypographyPreferences.load(from: defaults).fontSize == 10)
        var preferences = AppTypographyPreferences()
        preferences.fontSize = 100
        #expect(preferences.fontSize == 20)
    }

    @Test @MainActor func scalingPreservesHierarchyAndSupportsSmallControls() {
        let defaults = AppTypographyPreferences()
        let larger = AppTypographyPreferences(fontSize: 18)
        for style in [AppFontStyle.body, .caption, .title2, .system(size: 9)] {
            let original = style.pointSize(using: defaults)
            #expect(abs(style.pointSize(using: larger) - original * 18 / 13) < 0.001)
        }
        #expect(AppFontStyle.system(size: 9).nsFont(using: defaults).pointSize == 9)
        #expect(AppFontStyle.title2.pointSize(using: larger) > AppFontStyle.body.pointSize(using: larger))
        #expect(AppFontStyle.body.pointSize(using: larger) > AppFontStyle.caption.pointSize(using: larger))
    }

    @Test @MainActor func customFamilyAndNativeControlsUseTheSameTypography() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fontURL = root.appendingPathComponent("Sources/dBrief/Resources/Fonts/Inter-Regular.otf")
        _ = CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        let inter = AppTypographyPreferences(readingFont: .inter, fontSize: 16)
        let font = AppFontStyle.system(size: 13).nsFont(using: inter)
        #expect(font.familyName == "Inter")
        #expect(font.pointSize == 16)
        let sf = AppTypographyPreferences(readingFont: .sanFrancisco, fontSize: 16)
        #expect(AppFontStyle.system(size: 13).nsFont(using: sf) == NSFont.systemFont(ofSize: 16))
        #expect(AppFontStyle.brandMono(13).nsFont(using: sf) == NSFont.systemFont(ofSize: 16))
        #expect(AppFontStyle.brandMono(13).nsFont(using: AppTypographyPreferences())
                == NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
    }
}
