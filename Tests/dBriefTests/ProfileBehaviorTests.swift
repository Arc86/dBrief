import Foundation
import Testing
@testable import dBrief

@MainActor
struct ProfileBehaviorTests {
    @Test("Calendar participant default inherits, overrides, and resets")
    func calendarParticipantInheritance() throws {
        let previous = UserDefaults.standard.object(forKey: "autoLoadCalendarParticipants")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "autoLoadCalendarParticipants") }
            else { UserDefaults.standard.removeObject(forKey: "autoLoadCalendarParticipants") }
        }
        try withCleanProfileDefaults {
            let settings = AppSettings()
            settings.autoLoadCalendarParticipants = false
            let created = settings.createProfile(name: "Calendar participants")
            let index = try #require(settings.profiles.firstIndex(where: { $0.id == created.id }))
            #expect(!settings.resolvedAutoLoadCalendarParticipants(for: settings.profiles[index]))
            settings.profiles[index].overrides.autoLoadCalendarParticipants = true
            #expect(settings.resolvedAutoLoadCalendarParticipants(for: settings.profiles[index]))
            let decoded = try JSONDecoder().decode(MeetingProfile.self,
                from: JSONEncoder().encode(settings.profiles[index]))
            #expect(decoded.overrides.autoLoadCalendarParticipants == true)
            settings.profiles[index].overrides.autoLoadCalendarParticipants = nil
            #expect(!settings.resolvedAutoLoadCalendarParticipants(for: settings.profiles[index]))
        }
    }

    @Test("Editing a profile does not change accepted participant intent")
    func acceptedParticipantIntentIsFrozen() throws {
        try withCleanProfileDefaults {
            let settings = AppSettings()
            let created = settings.createProfile(name: "Frozen calendar")
            let index = try #require(settings.profiles.firstIndex(where: { $0.id == created.id }))
            settings.profiles[index].overrides.autoLoadCalendarParticipants = true
            settings.profiles[index].overrides.calendarCLIReasoningEffort = .low
            let accepted = AutomaticPostRecordingRequest(recordingID: UUID(),
                profile: settings.profiles[index], transcribe: false, summary: false,
                actionItems: false, tags: false, loadCalendarParticipants: true)
            settings.profiles[index].overrides.autoLoadCalendarParticipants = false
            settings.profiles[index].overrides.calendarCLIReasoningEffort = .high
            #expect(accepted.loadCalendarParticipants)
            #expect(accepted.profile.overrides.autoLoadCalendarParticipants == true)
            #expect(accepted.profile.overrides.calendarCLIReasoningEffort == .low)
        }
    }
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

            settings.profiles[index].overrides.customVocabulary = ["custom", "words"]
            settings.profiles[index].overrides.autoTags = true

            let exportedData = try settings.exportProfiles(ids: [created.id])
            let exported = try JSONDecoder().decode(ProfilesExportEnvelope.self, from: exportedData)
            #expect(exported.version == 1)
            #expect(exported.profiles.count == 1)
            #expect(exported.profiles[0].name == "Roundtrip")
            #expect(exported.profiles[0].overrides.customVocabulary == ["custom", "words"])
            #expect(exported.profiles[0].overrides.autoTags == true)
        }
    }
}
