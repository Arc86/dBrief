import Foundation
import Testing
@testable import dBrief

@MainActor
@Suite(.serialized)
struct SettingsProfileScopeTests {
    private func withSettings(_ body: (AppSettings) throws -> Void) throws {
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        try #require(!domain.hasPrefix("com.dbrief.app"))
        let defaults = UserDefaults.standard
        let saved = defaults.persistentDomain(forName: domain)
        defer {
            if let saved { defaults.setPersistentDomain(saved, forName: domain) }
            else { defaults.removePersistentDomain(forName: domain) }
        }
        try body(AppSettings())
    }

    @Test func scopeShowsAutomaticProfileWithoutChangingSavedSelection() throws {
        try withSettings { settings in
            let saved = MeetingProfile(name: "Saved")
            let automatic = MeetingProfile(name: "Automatic", overrides: .init(aiProcessingEnabled: false))
            settings.profiles = [saved, automatic]
            settings.setActiveProfile(saved.id)
            let recordingID = UUID()
            settings.routeAutomatically(to: automatic.id, for: recordingID)
            settings.aiProcessingEnabled = true
            let scope = SettingsProfileScope(settings: settings)
            #expect(scope.profile.id == automatic.id)
            #expect(scope.savedProfile?.id == saved.id)
            #expect(scope.isAutomatic)
            #expect(scope.summary(for: .aiEnabled).profileValue == "Off")
            #expect(scope.summary(for: .aiEnabled).defaultValue == "On")
            let editor = SettingsProfileScope(settings: settings, profile: saved)
            #expect(editor.profile.id == saved.id)
            #expect(!editor.isAutomatic)
            #expect(settings.activeProfileId == saved.id)
            #expect(settings.automaticProfileId == automatic.id)
            #expect(settings.automaticProfileRecordingID == recordingID)
        }
    }

    @Test func missingProviderShowsActualFallbackAndKeepsOverride() throws {
        try withSettings { settings in
            let endpoint = Endpoint(name: "Working service", baseURL: "http://localhost:8080", modelName: "test")
            settings.transcriptionEndpoints = [endpoint]
            settings.defaultTranscriptionEndpointId = endpoint.id
            let missingID = UUID()
            let profile = MeetingProfile(name: "Missing service", overrides: .init(transcriptionEndpointId: missingID))
            settings.profiles = [profile]
            settings.setActiveProfile(profile.id)
            let row = SettingsProfileScope(settings: settings).summary(for: .transcriptionService)
            #expect(row.profileValue == settings.effectiveDefaultTranscriptionEndpoint?.name)
            #expect(row.isOverridden)
            #expect(row.note != nil)
            #expect(settings.activeProfile.overrides.transcriptionEndpointId == missingID)
        }
    }

    @Test func unavailableRecordingDestinationIsRetainedButVaultFallsBack() throws {
        try withSettings { settings in
            let missing = NSTemporaryDirectory() + UUID().uuidString
            settings.obsidianVaultURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let profile = MeetingProfile(name: "Offline", overrides: .init(recordingFolderPath: missing, obsidianVaultPath: missing))
            settings.profiles = [profile]
            settings.setActiveProfile(profile.id)
            let scope = SettingsProfileScope(settings: settings)
            #expect(scope.summary(for: .recordingFolder).profileValue == settings.effectiveRecordingFolderURL.path)
            #expect(scope.summary(for: .recordingFolder).note != nil)
            #expect(scope.summary(for: .obsidianVault).profileValue == settings.effectiveObsidianVaultURL?.path)
            #expect(scope.summary(for: .obsidianVault).note != nil)
        }
    }

    @Test func automaticLanguageLabelUsesEachScopesEngine() throws {
        try withSettings { settings in
            settings.transcriptionEngine = .appleSpeech
            settings.transcriptionLanguage = ""
            let profile = MeetingProfile(name: "Whisper", overrides: .init(transcriptionEngine: .localWhisper))
            let row = SettingsProfileScope(settings: settings, profile: profile, fields: [.language]).summary(for: .language)
            #expect(row.defaultValue == "System language")
            #expect(row.profileValue == "Auto-detect")
            #expect(!row.isOverridden)
        }
    }

    @Test func inheritedValuesAreConcreteAndReflectChangedDefaults() throws {
        try withSettings { settings in
            let profile = MeetingProfile(name: "Inherited")
            settings.profiles = [profile]
            settings.setActiveProfile(profile.id)
            settings.autoSummary = false
            let before = SettingsProfileScope(settings: settings).summary(for: .summaryTask)
            #expect(!before.isOverridden)
            #expect(before.defaultValue == "Off")
            settings.autoSummary = true
            let after = SettingsProfileScope(settings: settings).summary(for: .summaryTask)
            #expect(after.defaultValue == "On")
            #expect(after.profileValue == after.defaultValue)
            #expect(settings.activeProfile.overrides.autoSummary == nil)
        }
    }
}
