import Foundation
import Testing
@testable import dBrief

@Suite struct ViewerPreferenceTests {
@Test func legacyAppearanceMigratesToGlobalModeAndMatchingTheme() {
    let suiteName = "theme-migration-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    for legacyMode in ViewerAppearanceMode.allCases {
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(legacyMode.rawValue, forKey: "viewerAppearanceMode")
        let preferences = ViewerAppearancePreferences.load(from: defaults)

        #expect(preferences.themeMode == (legacyMode.isDark ? .dark : .light))
        #expect(preferences.mode == legacyMode)
        #expect(preferences.effectiveMode(systemIsDark: false) == legacyMode)
        #expect(preferences.effectiveMode(systemIsDark: true) == legacyMode)
        #expect(legacyMode.isDark ? preferences.lightTheme == .light : preferences.darkTheme == .dark)
        preferences.save(to: defaults)
        #expect(ViewerAppearancePreferences.load(from: defaults) == preferences)
    }
}

@Test func followSystemResolvesBothStoredThemesWithoutChangingPreferences() {
    let suiteName = "theme-system-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var preferences = ViewerAppearancePreferences(themeMode: .system, lightTheme: .paper, darkTheme: .darkPaper)
    preferences.save(to: defaults)
    #expect(preferences.mode == nil)
    #expect(preferences.effectiveMode(systemIsDark: false) == .paper)
    #expect(preferences.effectiveMode(systemIsDark: true) == .darkPaper)
    #expect(defaults.object(forKey: "viewerAppearanceMode") == nil)
    #expect(ViewerAppearancePreferences.load(from: defaults) == preferences)

    preferences.themeMode = .light
    #expect(preferences.effectiveMode(systemIsDark: true) == .paper)
    preferences.themeMode = .dark
    #expect(preferences.effectiveMode(systemIsDark: false) == .darkPaper)
}

@Test func viewerQuickThemeControlsPreserveTheOtherSchemeChoice() {
    var preferences = ViewerAppearancePreferences(themeMode: .system, lightTheme: .paper, darkTheme: .darkPaper)
    preferences.mode = .light
    #expect(preferences.themeMode == .light)
    #expect(preferences.lightTheme == .light)
    #expect(preferences.darkTheme == .darkPaper)
    preferences.mode = .dark
    #expect(preferences.themeMode == .dark)
    #expect(preferences.lightTheme == .light)
    #expect(preferences.darkTheme == .dark)
    preferences.mode = nil
    #expect(preferences.themeMode == .system)
    #expect(preferences.mode == nil)
}

@Test func storedGlobalModeTakesPrecedenceAndRejectsInvalidSchemeThemes() {
    let suiteName = "theme-invalid-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set("darkPaper", forKey: "viewerAppearanceMode")
    defaults.set("system", forKey: "appThemeMode")
    defaults.set("darkPaper", forKey: "appLightTheme")
    defaults.set("paper", forKey: "appDarkTheme")
    var preferences = ViewerAppearancePreferences.load(from: defaults)
    #expect(preferences.themeMode == .system)
    #expect(preferences.lightTheme == .light)
    #expect(preferences.darkTheme == .dark)

    preferences.lightTheme = .dark
    preferences.darkTheme = .light
    #expect(preferences.lightTheme == .light)
    #expect(preferences.darkTheme == .dark)
    defaults.set("unknown", forKey: "appThemeMode")
    #expect(ViewerAppearancePreferences.load(from: defaults).themeMode == .system)
}

@Test func migratesExistingTranscriptReadingPreferences() {
    let suiteName = "viewer-preferences-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(16, forKey: "transcriptFontSize")
    defaults.set(false, forKey: "showSpeakerNames")

    let preferences = ViewerAppearancePreferences.load(from: defaults)

    #expect(preferences.fontSize == 16)
    #expect(preferences.chatFontSize == ViewerAppearancePreferences.defaultChatFontSize)
    #expect(preferences.showSpeakerNames == false)
    #expect(preferences.mode == nil)
    #expect(preferences.effectiveMode(systemIsDark: true) == .dark)
    #expect(preferences.effectiveMode(systemIsDark: false) == .light)

    preferences.save(to: defaults)
    #expect(ViewerAppearancePreferences.load(from: defaults) == preferences)
    #expect(defaults.object(forKey: "viewerAppearanceMode") == nil)
}

@Test func roundTripsEveryAppearanceReadingAndDensityChoice() {
    let suiteName = "viewer-roundtrip-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    for mode in ViewerAppearanceMode.allCases {
        for font in ViewerReadingFont.allCases {
            for density in ViewerDensity.allCases {
                var preferences = ViewerAppearancePreferences.load(from: defaults)
                preferences.mode = mode
                preferences.sourceAccentHex = "#7054D9"
                preferences.readingFont = font
                preferences.density = density
                preferences.fontSize = 12 + ViewerReadingFont.allCases.firstIndex(of: font)!
                preferences.chatFontSize = 18
                preferences.showSpeakerNames = false
                preferences.save(to: defaults)

                #expect(ViewerAppearancePreferences.load(from: defaults) == preferences)
                #expect(defaults.string(forKey: "viewerAppearanceMode") == mode.rawValue)
                #expect(defaults.string(forKey: "viewerAccentHex") == "#7054D9")
                #expect(defaults.string(forKey: "viewerReadingFont") == font.rawValue)
                #expect(defaults.string(forKey: "viewerTranscriptDensity") == density.rawValue)
                #expect(defaults.integer(forKey: "transcriptChatFontSize") == 18)
            }
        }
    }
}

@Test func malformedPreferencesUseSafeDefaultsAndClampFontSize() {
    let suiteName = "viewer-malformed-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set("sepia", forKey: "viewerAppearanceMode")
    defaults.set("comicSans", forKey: "viewerReadingFont")
    defaults.set("extraWide", forKey: "viewerTranscriptDensity")
    defaults.set("not-a-colour", forKey: "viewerAccentHex")
    defaults.set(30, forKey: "transcriptFontSize")
    defaults.set(30, forKey: "transcriptChatFontSize")
    defaults.set("not-a-boolean", forKey: "showSpeakerNames")

    let preferences = ViewerAppearancePreferences.load(from: defaults)

    #expect(preferences.mode == nil)
    #expect(preferences.readingFont == .systemDefault)
    #expect(preferences.density == .comfortable)
    #expect(preferences.sourceAccentHex == "#1268F5")
    #expect(preferences.fontSize == 24)
    #expect(preferences.chatFontSize == 24)
    #expect(preferences.showSpeakerNames)

    defaults.set(-1, forKey: "transcriptFontSize")
    #expect(ViewerAppearancePreferences.load(from: defaults).fontSize == 12)
    defaults.set(-1, forKey: "transcriptChatFontSize")
    #expect(ViewerAppearancePreferences.load(from: defaults).chatFontSize == 12)

    var assigned = ViewerAppearancePreferences()
    assigned.chatFontSize = 30
    #expect(assigned.chatFontSize == 24)
}

@Test func readingResetLeavesAppearanceAndOtherSettingsAlone() {
    let suiteName = "viewer-reset-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let profileID = UUID().uuidString
    defaults.set(ViewerAppearanceMode.darkPaper.rawValue, forKey: "viewerAppearanceMode")
    defaults.set("#19745B", forKey: "viewerAccentHex")
    defaults.set(ViewerReadingFont.monospace.rawValue, forKey: "viewerReadingFont")
    defaults.set(ViewerDensity.spacious.rawValue, forKey: "viewerTranscriptDensity")
    defaults.set(24, forKey: "transcriptFontSize")
    defaults.set(21, forKey: "transcriptChatFontSize")
    defaults.set(false, forKey: "showSpeakerNames")
    defaults.set(true, forKey: "reduceNeon")
    defaults.set(true, forKey: "transcriptAssistantOpen")
    defaults.set(412.0, forKey: "transcriptAssistantPanelWidth")
    defaults.set(profileID, forKey: "activeProfileId")

    var preferences = ViewerAppearancePreferences.load(from: defaults)
    preferences.resetReading()
    preferences.save(to: defaults)

    #expect(preferences.readingFont == .systemDefault)
    #expect(preferences.fontSize == 16)
    #expect(preferences.chatFontSize == 21)
    #expect(preferences.density == .comfortable)
    #expect(preferences.showSpeakerNames)
    #expect(preferences.mode == .darkPaper)
    #expect(preferences.sourceAccentHex == "#19745B")
    #expect(defaults.bool(forKey: "reduceNeon"))
    #expect(defaults.bool(forKey: "transcriptAssistantOpen"))
    #expect(defaults.double(forKey: "transcriptAssistantPanelWidth") == 412)
    #expect(defaults.integer(forKey: "transcriptChatFontSize") == 21)
    #expect(defaults.string(forKey: "activeProfileId") == profileID)
}

@Test func modeTraitsAndDensityMetricsMatchTheReadingControls() {
    #expect(!ViewerAppearanceMode.light.isDark)
    #expect(ViewerAppearanceMode.dark.isDark)
    #expect(ViewerAppearanceMode.paper.isPaper)
    #expect(ViewerAppearanceMode.darkPaper.isPaper)

    #expect(ViewerDensity.compact.rowVerticalPadding == 9)
    #expect(ViewerDensity.compact.speakerHeaderGap == 5)
    #expect(ViewerDensity.compact.lineHeightTarget == 1.55)
    #expect(ViewerDensity.comfortable.rowVerticalPadding == 17)
    #expect(ViewerDensity.comfortable.speakerHeaderGap == 9)
    #expect(ViewerDensity.comfortable.lineHeightTarget == 1.75)
    #expect(ViewerDensity.spacious.rowVerticalPadding == 25)
    #expect(ViewerDensity.spacious.speakerHeaderGap == 13)
    #expect(ViewerDensity.spacious.lineHeightTarget == 1.90)
}

@Test func defaultReadingFontFollowsPaperModeButExplicitChoicesPersist() {
    let preferences = ViewerAppearancePreferences()
    #expect(preferences.effectiveReadingFont(for: .light) == .systemDefault)
    #expect(preferences.effectiveReadingFont(for: .paper) == .georgia)
    #expect(preferences.effectiveReadingFont(for: .darkPaper) == .georgia)

    for font in ViewerReadingFont.allCases where font != .systemDefault {
        var explicitFont = preferences
        explicitFont.readingFont = font
        for mode in ViewerAppearanceMode.allCases {
            #expect(explicitFont.effectiveReadingFont(for: mode) == font)
        }
    }
}

@Test func sourceAccentRemainsUnchangedAcrossThemeResolution() {
    let suiteName = "viewer-source-accent-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var preferences = ViewerAppearancePreferences.load(from: defaults)
    preferences.sourceAccentHex = "#7054D9"
    preferences.save(to: defaults)

    for mode in ViewerAppearanceMode.allCases {
        _ = ViewerThemeResolver.resolve(mode: mode, sourceHex: preferences.sourceAccentHex, nonNeon: false)
        #expect(preferences.sourceAccentHex == "#7054D9")
        #expect(ViewerAppearancePreferences.load(from: defaults).sourceAccentHex == "#7054D9")
    }
}
}
