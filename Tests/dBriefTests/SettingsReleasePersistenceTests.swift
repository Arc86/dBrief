import Foundation
import Testing
@testable import dBrief

@MainActor
@Suite(.serialized)
struct SettingsReleasePersistenceTests {
    /// Stay in the test executable's preference domain. Synchronous MainActor
    /// fixtures cannot interleave with other MainActor settings tests.
    private func withIsolatedDefaults(_ body: (URL) throws -> Void) throws {
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        try #require(!domain.hasPrefix("com.dbrief.app"))
        let defaults = UserDefaults.standard
        let saved = defaults.persistentDomain(forName: domain)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsReleasePersistence-\(UUID().uuidString)", isDirectory: true)
        defer {
            if let saved { defaults.setPersistentDomain(saved, forName: domain) }
            else { defaults.removePersistentDomain(forName: domain) }
            try? FileManager.default.removeItem(at: root)
        }
        defaults.removePersistentDomain(forName: domain)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try body(root)
    }

    @Test func exportedProfileImportsAndReloadsWithoutChangingExistingFolderBookmarks() throws {
        try withIsolatedDefaults { root in
            let defaults = UserDefaults.standard
            let globalFolders = ["recordingFolderBookmark", "transcriptionFolderBookmark", "obsidianVaultBookmark"]
            var bookmarks: [String: Data] = [:]
            var folders: [String: URL] = [:]
            for key in globalFolders {
                let folder = root.appendingPathComponent(key, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                // Seed existing bookmarks, as granted by a prior folder choice.
                // Testing NSOpenPanel authorization itself requires native QA.
                let bookmark = try folder.bookmarkData(options: .withSecurityScope,
                    includingResourceValuesForKeys: nil, relativeTo: nil)
                defaults.set(bookmark, forKey: key)
                bookmarks[key] = bookmark
                folders[key] = folder
            }
            let profileFolder = root.appendingPathComponent("Profile exports", isDirectory: true)
            try FileManager.default.createDirectory(at: profileFolder, withIntermediateDirectories: true)
            let transcriptionID = UUID()
            let aiID = UUID()
            var source = MeetingProfile(name: "Release roundtrip", overrides: .init(
                transcriptionLanguage: "nl", customVocabulary: ["dBrief", "ServiceNow"],
                transcriptionEngine: .parakeetLocal, transcriptionEndpointId: transcriptionID,
                aiProcessingEnabled: false, aiEndpointId: aiID, summaryPrompt: "Retain this prompt",
                autoTranscribe: true, autoSummary: false, autoActionItems: true, autoTags: false,
                recordingFolderPath: profileFolder.path, transcriptionFolderPath: profileFolder.path,
                obsidianVaultPath: profileFolder.path, obsidianDefaultFolderRelativePath: "Meetings"))
            source.postRecordingPolicy = .queue
            source.automaticMatchingEnabled = true
            source.matchPriority = 7
            source.matchingRules = [.init(field: .title, value: "Planning")]
            let settings = AppSettings()
            settings.profiles = [source]
            settings.setActiveProfile(source.id)
            let exported = try settings.exportProfiles(ids: [source.id])
            #expect(try JSONDecoder().decode(ProfilesExportEnvelope.self, from: exported).version == 1)

            let result = try settings.importProfiles(from: exported)
            #expect(result.importedCount == 1)
            #expect(result.renamedCount == 1)
            #expect(result.warnings.isEmpty)
            let imported = try #require(settings.profiles.first { $0.id != source.id })
            #expect(imported.name == "Release roundtrip (Imported)")
            #expect(settings.activeProfileId == source.id)
            var expected = source
            expected.id = imported.id
            expected.name = imported.name
            #expect(imported == expected)

            let reloaded = AppSettings()
            defer {
                for settings in [settings, reloaded] {
                    settings.recordingFolderURL.stopAccessingSecurityScopedResource()
                    settings.transcriptionFolderURL.stopAccessingSecurityScopedResource()
                    settings.obsidianVaultURL?.stopAccessingSecurityScopedResource()
                }
            }
            #expect(reloaded.profiles.first { $0.id == imported.id } == expected)
            #expect(reloaded.profiles.first { $0.id == source.id } == source)
            #expect(reloaded.activeProfileId == source.id)
            #expect(reloaded.recordingFolderURL.resolvingSymlinksInPath() == folders["recordingFolderBookmark"]?.resolvingSymlinksInPath())
            #expect(reloaded.transcriptionFolderURL.resolvingSymlinksInPath() == folders["transcriptionFolderBookmark"]?.resolvingSymlinksInPath())
            #expect(reloaded.obsidianVaultURL?.resolvingSymlinksInPath() == folders["obsidianVaultBookmark"]?.resolvingSymlinksInPath())
            for key in globalFolders { #expect(defaults.data(forKey: key) == bookmarks[key]) }
            reloaded.setActiveProfile(imported.id)
            #expect(reloaded.activeProfile.overrides.transcriptionEndpointId == transcriptionID)
            #expect(reloaded.activeProfile.overrides.aiEndpointId == aiID)
            #expect(reloaded.effectiveRecordingFolderURL.resolvingSymlinksInPath() == profileFolder.resolvingSymlinksInPath())
            #expect(reloaded.effectiveTranscriptionFolderURL.resolvingSymlinksInPath() == profileFolder.resolvingSymlinksInPath())
            #expect(reloaded.effectiveObsidianVaultURL?.resolvingSymlinksInPath() == profileFolder.resolvingSymlinksInPath())
        }
    }

    @Test func inactiveLanguageVoiceInstructionAndTaskChoicesSurviveReloadAndReactivation() throws {
        try withIsolatedDefaults { _ in
            let settings = AppSettings()
            settings.transcriptionLanguage = "nl"
            settings.transcriptionEngine = .parakeetLocal
            settings.ttsDeliveryInstruction = "Speak calmly and leave pauses."
            settings.ttsModelSize = .small
            settings.aiProcessingEnabled = false
            settings.autoTranscribe = true
            settings.autoSummary = false
            settings.autoActionItems = true
            settings.autoTags = false

            let reloaded = AppSettings()
            #expect(reloaded.transcriptionEngine == .parakeetLocal)
            #expect(reloaded.transcriptionLanguage == "nl")
            #expect(!reloaded.ttsModelSize.supportsVoiceInstruction)
            #expect(reloaded.ttsDeliveryInstruction == "Speak calmly and leave pauses.")
            #expect(!reloaded.aiProcessingEnabled)
            #expect(reloaded.autoTranscribe && !reloaded.autoSummary && reloaded.autoActionItems && !reloaded.autoTags)
            reloaded.transcriptionEngine = .localWhisper
            reloaded.ttsModelSize = .large
            reloaded.aiProcessingEnabled = true
            let reactivated = AppSettings()
            #expect(reactivated.transcriptionEngine == .localWhisper)
            #expect(reactivated.transcriptionLanguage == "nl")
            #expect(reactivated.ttsModelSize.supportsVoiceInstruction)
            #expect(reactivated.ttsDeliveryInstruction == "Speak calmly and leave pauses.")
            #expect(reactivated.aiProcessingEnabled)
            #expect(reactivated.autoTranscribe && !reactivated.autoSummary && reactivated.autoActionItems && !reactivated.autoTags)
        }
    }
}
