import Foundation
import Testing
@testable import dBrief

@MainActor
@Suite(.serialized)
struct SettingsResetTests {
    /// AppSettings uses standard defaults. Restore the test executable's domain
    /// after each synchronous fixture, and never run this fixture inside the app.
    private func withRestoredDefaults(_ body: (AppSettings) throws -> Void) throws {
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        try #require(!domain.hasPrefix("com.dbrief.app"))
        let defaults = UserDefaults.standard
        let saved = defaults.persistentDomain(forName: domain)
        defer {
            if let saved {
                defaults.setPersistentDomain(saved, forName: domain)
            } else {
                defaults.removePersistentDomain(forName: domain)
            }
        }
        try body(AppSettings())
    }

    @Test func sharedResetRestoresAdvertisedFieldsAndPreservesOtherPreferences() throws {
        try withRestoredDefaults { settings in
            var defaultProfile = MeetingProfile(name: "Renamed default", preset: .default,
                overrides: .init(transcriptionLanguage: "nl", autoSummary: false))
            defaultProfile.iconSystemName = "star"
            defaultProfile.iconBackgroundColorKey = "red"
            defaultProfile.automaticMatchingEnabled = true
            defaultProfile.matchPriority = 10
            defaultProfile.matchingRules = [.init(field: .title, value: "Planning")]
            defaultProfile.postRecordingPolicy = .queue
            let custom = MeetingProfile(name: "Keep this profile", overrides: .init(summaryPrompt: "Keep me"))
            settings.profiles = [defaultProfile, custom]
            settings.setActiveProfile(custom.id)
            settings.transcriptionLanguage = "nl"
            settings.customVocabulary = ["dBrief"]
            settings.summaryPrompt = "Custom summary"
            settings.actionItemsPrompt = "Custom actions"
            settings.tagsPrompt = "Custom tags"
            settings.autoTranscribe = false
            settings.autoSummary = false
            settings.autoActionItems = false
            settings.autoTags = false
            let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            settings.recordingFolderURL = folder
            settings.transcriptionFolderURL = folder
            settings.obsidianVaultURL = folder
            settings.obsidianDefaultFolderRelativePath = "Meetings"
            settings.aiProcessingEnabled = false
            let dockIconBefore = settings.showDockIcon
            settings.autoDeleteRecordingsEnabled = true
            let unrelatedBefore = [settings.transcriptionEngine.rawValue, settings.aiEngine.rawValue,
                                   settings.spokenSummaryPrompt]

            settings.resetDefaultProfileToBuiltInDefaults()

            let reset = try #require(settings.profiles.first { $0.id == defaultProfile.id })
            #expect(reset == MeetingProfile(id: defaultProfile.id, name: "Default", preset: .default))
            #expect(settings.profiles.first { $0.id == custom.id } == custom)
            #expect(settings.activeProfileId == custom.id)
            #expect(settings.transcriptionLanguage.isEmpty)
            #expect(settings.customVocabulary.isEmpty)
            #expect(settings.summaryPrompt == AppSettings.defaultSummaryPrompt)
            #expect(settings.actionItemsPrompt == AppSettings.defaultActionItemsPrompt)
            #expect(settings.tagsPrompt == AppSettings.defaultTagsPrompt)
            #expect(settings.autoTranscribe && settings.autoSummary && settings.autoActionItems && settings.autoTags)
            #expect(settings.recordingFolderURL == AppSettings.defaultRecordingFolder())
            #expect(settings.transcriptionFolderURL == AppSettings.defaultTranscriptionFolder())
            #expect(settings.obsidianVaultURL == nil)
            #expect(settings.obsidianDefaultFolderRelativePath.isEmpty)
            #expect(!settings.aiProcessingEnabled)
            #expect(settings.showDockIcon == dockIconBefore)
            #expect(settings.autoDeleteRecordingsEnabled)
            #expect([settings.transcriptionEngine.rawValue, settings.aiEngine.rawValue,
                     settings.spokenSummaryPrompt] == unrelatedBefore)
            let reloaded = AppSettings()
            #expect(reloaded.customVocabulary.isEmpty)
            #expect(reloaded.summaryPrompt == AppSettings.defaultSummaryPrompt)
            #expect(reloaded.profiles == settings.profiles)
        }
    }

    @Test func missingDefaultProfileDoesNotResetSharedValues() throws {
        try withRestoredDefaults { settings in
            let custom = MeetingProfile(name: "Only custom")
            settings.profiles = [custom]
            settings.transcriptionLanguage = "nl"
            settings.customVocabulary = ["Keep me"]
            settings.autoSummary = false
            settings.resetDefaultProfileToBuiltInDefaults()
            #expect(settings.profiles == [custom])
            #expect(settings.transcriptionLanguage == "nl")
            #expect(settings.customVocabulary == ["Keep me"])
            #expect(!settings.autoSummary)
        }
    }
}
