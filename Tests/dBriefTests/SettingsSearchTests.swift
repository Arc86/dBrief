import Testing
@testable import dBrief

struct SettingsSearchTests {
    @Test func oldNamesAndHelpTermsReachMovedSettings() {
        #expect(SettingsSearch.results(for: "watched folders").first?.destination.page == .watchedFolders)
        #expect(SettingsSearch.results(for: "voice library").first?.destination.page == .voiceLibrary)
        #expect(SettingsSearch.results(for: "AI & Models").contains { $0.destination.page == .ai })
        #expect(SettingsSearch.results(for: "post-recording defaults").first?.destination.page == .afterRecording)
        #expect(SettingsSearch.results(for: "hotkey").first?.destination.section == .recordingShortcut)
        #expect(SettingsSearch.results(for: "retention").first?.destination.page == .storage)
        #expect(SettingsSearch.results(for: "calendar outlook").first?.destination.section == .calendar)
    }

    @Test func queriesAreNormalizedAndRequireAllTerms() {
        #expect(SettingsSearch.results(for: "  CáLeNdAr  ") == SettingsSearch.results(for: "calendar"))
        #expect(SettingsSearch.results(for: "calendar nonsenseword").isEmpty)
        #expect(SettingsSearch.results(for: " \n ").isEmpty)
        #expect(SettingsSearch.results(for: "unrecognizable-credential-value").isEmpty)
    }

    @Test func resultsIncludeAdvancedDestinationsWithoutFilteringByPreferences() {
        #expect(SettingsSearch.results(for: "audio quality").first?.requiresAdvanced == true)
        let results = SettingsSearch.results(for: "large file")
        #expect(results.first?.requiresAdvanced == true)
        #expect(results.first?.destination.section == .transcriptionChunking)
        #expect(SettingsSearch.results(for: "benchmark").contains { $0.destination.page == .benchmark && $0.requiresAdvanced })
        #expect(SettingsSearch.results(for: "summary prompt").contains { $0.destination.section == .spokenPrompt && $0.requiresAdvanced })
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
