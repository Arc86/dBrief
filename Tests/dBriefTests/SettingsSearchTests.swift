import Testing
@testable import dBrief

struct SettingsSearchTests {
    @Test func oldNamesAndHelpTermsReachMovedSettings() {
        #expect(SettingsSearch.results(for: "watched folders").first?.destination.page == .watchedFolders)
        #expect(SettingsSearch.results(for: "voice library").first?.destination.page == .speakers)
        #expect(SettingsSearch.results(for: "identify speakers").first?.destination.section == .speakerIdentification)
        #expect(SettingsSearch.results(for: "AI & Models").contains { $0.destination.page == .ai })
        #expect(SettingsSearch.results(for: "post-recording defaults").first?.destination.page == .afterRecording)
        #expect(SettingsSearch.results(for: "hotkey").first?.destination.section == .recordingShortcut)
        #expect(SettingsSearch.results(for: "retention").first?.destination.page == .storage)
        #expect(SettingsSearch.results(for: "calendar outlook").first?.destination.section == .calendar)
        #expect(SettingsSearch.results(for: "zoom").first?.destination.page == .meetings)
        #expect(SettingsSearch.results(for: "benchmark").first?.destination.page == .benchmark)
        #expect(SettingsSearch.results(for: "output language").first?.destination.section == .aiResultsLanguage)
        #expect(SettingsSearch.results(for: "dark mode").first?.destination.page == .appearance)
        #expect(SettingsSearch.results(for: "non neon").first?.destination.section == .accentColor)
        #expect(SettingsSearch.results(for: "font size").first?.destination.section == .typography)
        #expect(SettingsSearch.results(for: "dock icon").first?.destination.section == .appBehavior)
    }

    @Test func advancedEntriesLiveInAdvancedSections() {
        #expect(SettingsSearch.results(for: "audio quality").first?.requiresAdvanced == true)
        let chunking = SettingsSearch.results(for: "large file").first
        #expect(chunking?.destination.section == .transcriptionChunking)
        #expect(chunking?.requiresAdvanced == true)
        #expect(SettingsSearch.results(for: "summary prompt").contains { $0.destination.section == .spokenPrompt && $0.requiresAdvanced })
        #expect(SettingsSearch.results(for: "benchmark").first?.requiresAdvanced == false)
        #expect(SettingsSearch.results(for: "claude launcher").first?.destination.section == .calendarCLIAdvanced)
        #expect(SettingsSearch.results(for: "show advanced settings").isEmpty)
    }

    @Test func queriesAreNormalizedAndRequireAllTerms() {
        #expect(SettingsSearch.results(for: "  CáLeNdAr  ") == SettingsSearch.results(for: "calendar"))
        #expect(SettingsSearch.results(for: "calendar nonsenseword").isEmpty)
        #expect(SettingsSearch.results(for: " \n ").isEmpty)
        #expect(SettingsSearch.results(for: "unrecognizable-credential-value").isEmpty)
    }

    @Test func catalogueHasUniqueIDsAndConsistentDestinations() {
        #expect(Set(SettingsSearch.entries.map(\.id)).count == SettingsSearch.entries.count)
        for entry in SettingsSearch.entries {
            #expect(entry.destination.section?.page == entry.destination.page)
        }
        for page in SettingsPage.allCases {
            #expect(SettingsSearch.entries.contains { $0.destination.page == page })
        }
    }
}
