import Foundation
import Testing
@testable import dBrief

@MainActor
struct ProfileBehaviorTests {
    private func withCleanProfileDefaults(_ body: () throws -> Void) throws {
        UserDefaults.standard.removeObject(forKey: "profiles")
        UserDefaults.standard.removeObject(forKey: "activeProfileId")
        defer {
            UserDefaults.standard.removeObject(forKey: "profiles")
            UserDefaults.standard.removeObject(forKey: "activeProfileId")
        }
        try body()
    }

    @Test
    func effectiveSettingsUseOverrideAndFallback() throws {
        try withCleanProfileDefaults {
            let settings = AppSettings()
            settings.transcriptionLanguage = "en"
            settings.summaryPrompt = "global-summary"

            let created = settings.createProfile(name: "Custom")
            guard let index = settings.profiles.firstIndex(where: { $0.id == created.id }) else {
                Issue.record("Expected profile to exist")
                return
            }
            settings.profiles[index].overrides.summaryPrompt = "profile-summary"
            settings.setActiveProfile(created.id)

            #expect(settings.effectiveSummaryPrompt == "profile-summary")
            #expect(settings.effectiveTranscriptionLanguage == "en")

            settings.profiles[index].overrides.summaryPrompt = nil
            #expect(settings.effectiveSummaryPrompt == "global-summary")
        }
    }

    @Test
    func importRenamesConflictingNames() throws {
        try withCleanProfileDefaults {
            let settings = AppSettings()
            let existing = settings.createProfile(name: "Team Custom")

            let incoming = MeetingProfile(
                id: UUID(),
                name: existing.name,
                preset: .custom,
                overrides: .empty
            )
            let envelope = ProfilesExportEnvelope(
                version: 1,
                exportedAtISO8601: ISO8601DateFormatter().string(from: Date()),
                profiles: [incoming]
            )

            let result = try settings.importProfiles(from: try JSONEncoder().encode(envelope))
            #expect(result.importedCount == 1)
            #expect(result.renamedCount == 1)
            #expect(settings.profiles.contains(where: { $0.name.contains("Imported") }))
        }
    }

    @Test
    func defaultProfileCannotBeDeleted() throws {
        try withCleanProfileDefaults {
            let settings = AppSettings()
            guard let defaultProfile = settings.profiles.first(where: { $0.preset == .default }) else {
                Issue.record("Default profile missing")
                return
            }
            let countBefore = settings.profiles.count
            settings.deleteProfile(id: defaultProfile.id)
            #expect(settings.profiles.count == countBefore)
            #expect(settings.profiles.contains(where: { $0.id == defaultProfile.id }))
        }
    }

    @Test
    func missingEndpointOverrideFallsBackToDefaultEndpoint() throws {
        try withCleanProfileDefaults {
            let settings = AppSettings()
            let endpoint = Endpoint(name: "Default", baseURL: "http://localhost:8080", modelName: "whisper-1")
            settings.transcriptionEndpoints = [endpoint]
            settings.defaultTranscriptionEndpointId = endpoint.id

            let created = settings.createProfile(name: "Missing Endpoint")
            guard let index = settings.profiles.firstIndex(where: { $0.id == created.id }) else {
                Issue.record("Expected profile to exist")
                return
            }

            settings.profiles[index].overrides.transcriptionEndpointId = UUID()
            settings.setActiveProfile(created.id)

            #expect(settings.effectiveDefaultTranscriptionEndpoint?.id == endpoint.id)
        }
    }

    @Test
    func exportImportEnvelopeForCustomProfile() throws {
        try withCleanProfileDefaults {
            let settings = AppSettings()
            let created = settings.createProfile(name: "Roundtrip")
            guard let index = settings.profiles.firstIndex(where: { $0.id == created.id }) else {
                Issue.record("Expected profile to exist")
                return
            }

            settings.profiles[index].overrides.whisperPrompt = "custom words"
            settings.profiles[index].overrides.autoTags = true

            let exportedData = try settings.exportProfiles(ids: [created.id])
            let exported = try JSONDecoder().decode(ProfilesExportEnvelope.self, from: exportedData)
            #expect(exported.version == 1)
            #expect(exported.profiles.count == 1)
            #expect(exported.profiles[0].name == "Roundtrip")
            #expect(exported.profiles[0].overrides.whisperPrompt == "custom words")
            #expect(exported.profiles[0].overrides.autoTags == true)
        }
    }
}
