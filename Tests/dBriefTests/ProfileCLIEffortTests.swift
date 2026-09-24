import Foundation
import Testing
@testable import dBrief

@MainActor
@Suite(.serialized)
struct ProfileCLIEffortTests {
    @Test("An inherited profile differs from explicit CLI default")
    func profileInheritanceDiffersFromExplicitCLIDefault() throws {
        let inherited = try JSONDecoder().decode(MeetingProfileOverrides.self, from: Data("{}".utf8))
        let explicit = try JSONDecoder().decode(MeetingProfileOverrides.self,
            from: Data(#"{"localCLIReasoningEffort":"cliDefault","calendarCLIReasoningEffort":"low"}"#.utf8))
        let inheritedObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(inherited)) as? [String: Any])
        let explicitObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(explicit)) as? [String: Any])
        #expect(inheritedObject["localCLIReasoningEffort"] == nil)
        #expect(inheritedObject["calendarCLIReasoningEffort"] == nil)
        #expect(explicitObject["localCLIReasoningEffort"] as? String == "cliDefault")
        #expect(explicitObject["calendarCLIReasoningEffort"] as? String == "low")
    }

    @Test("Unknown imported effort leaves unrelated profile fields intact")
    func unknownEffortDoesNotDiscardPrompts() throws {
        let data = Data(#"{"summaryPrompt":"Keep this prompt","localCLIReasoningEffort":"future"}"#.utf8)
        let overrides = try JSONDecoder().decode(MeetingProfileOverrides.self, from: data)
        #expect(overrides.summaryPrompt == "Keep this prompt")
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(overrides)) as? [String: Any])
        #expect(object["localCLIReasoningEffort"] == nil)
    }
}

extension ProfileCLIEffortTests {
    @Test("Profile effort resolves independently and explicit CLI default overrides global")
    func profileEffortResolution() {
        let settings = AppSettings()
        let originalLocal = settings.localCLIConfig
        let originalCalendar = settings.calendarCLIConfig
        let originalProfiles = settings.profiles
        let originalActive = settings.activeProfileId
        defer {
            settings.localCLIConfig = originalLocal
            settings.calendarCLIConfig = originalCalendar
            settings.profiles = originalProfiles
            settings.activeProfileId = originalActive
        }
        settings.localCLIConfig = .init(command: "claude -p", timeoutSeconds: 180,
                                        effort: .medium, effortProvider: .claude)
        settings.calendarCLIConfig = .default.updating(effort: .low)
        let inherited = MeetingProfile(name: "Inherited")
        let overridden = MeetingProfile(name: "Override", overrides: .init(
            localCLIReasoningEffort: .high, calendarCLIReasoningEffort: .cliDefault))
        settings.profiles = [inherited, overridden]
        settings.setActiveProfile(inherited.id)
        #expect(settings.effectiveLocalCLIConfig.effort == .medium)
        #expect(settings.effectiveCalendarCLIConfig.effort == .low)
        #expect(settings.resolvedLocalCLIConfig(for: nil).effort == .medium)
        #expect(settings.resolvedLocalCLIConfig(for: overridden).effort == .high)
        #expect(settings.resolvedCalendarCLIConfig(for: overridden).effort == .cliDefault)
        settings.localCLIConfig.effort = .low
        #expect(settings.resolvedLocalCLIConfig(for: overridden).effort == .high)
        settings.setActiveProfile(overridden.id)
        #expect(settings.effectiveLocalCLIConfig.effort == .high)
        #expect(settings.effectiveCalendarCLIConfig.effort == .cliDefault)
    }

    @Test("Automatic profile routing uses the matching profile effort")
    func automaticRouteResolvesEffort() {
        let settings = AppSettings()
        let originalProfiles = settings.profiles
        let originalActive = settings.activeProfileId
        let originalLocal = settings.localCLIConfig
        let recordingID = UUID()
        defer {
            settings.finishAutomaticRouting(for: recordingID)
            settings.profiles = originalProfiles
            settings.activeProfileId = originalActive
            settings.localCLIConfig = originalLocal
        }
        let saved = MeetingProfile(name: "Saved")
        let automatic = MeetingProfile(name: "Automatic", overrides: .init(localCLIReasoningEffort: .xhigh))
        settings.profiles = [saved, automatic]
        settings.setActiveProfile(saved.id)
        settings.localCLIConfig.effort = .low
        settings.routeAutomatically(to: automatic.id, for: recordingID)
        #expect(settings.effectiveLocalCLIConfig.effort == .xhigh)
        #expect(settings.activeProfileId == saved.id)
    }
}

extension ProfileCLIEffortTests {
    @Test("Inactive profile preview uses the edited profile effort")
    func inactiveProfilePreviewUsesEditedEffort() throws {
        let settings = AppSettings()
        let originalProfiles = settings.profiles
        let originalActive = settings.activeProfileId
        let originalAI = settings.aiEngine
        let originalCLI = settings.localCLIConfig
        defer {
            settings.profiles = originalProfiles
            settings.activeProfileId = originalActive
            settings.aiEngine = originalAI
            settings.localCLIConfig = originalCLI
        }
        settings.aiEngine = .localCLI
        settings.localCLIConfig = .init(command: "claude -p", timeoutSeconds: 180,
                                        effort: .medium, effortProvider: .claude)
        let active = MeetingProfile(name: "Active", overrides: .init(localCLIReasoningEffort: .low))
        let edited = MeetingProfile(name: "Edited", overrides: .init(localCLIReasoningEffort: .high))
        settings.profiles = [active, edited]
        settings.setActiveProfile(active.id)
        let editedIdentity = PromptIdentity(kind: .summary, scope: .profile(edited.id))
        let appIdentity = PromptIdentity(kind: .summary, scope: .appDefaults)
        guard case .localCLI(let editedConfig) = try PromptConfigurationResolver.resolve(identity: editedIdentity, settings: settings),
              case .localCLI(let appConfig) = try PromptConfigurationResolver.resolve(identity: appIdentity, settings: settings) else {
            Issue.record("Expected Local CLI routes")
            return
        }
        #expect(editedConfig.effort == .high)
        #expect(appConfig.effort == .medium)
        let session = try PromptEditorSession(identity: editedIdentity, store: PromptPreferencesStore(settings: settings))
        session.engineSelection = .localCLI
        guard case .localCLI(let explicitConfig) = try session.resolveConfiguration() else {
            Issue.record("Expected explicit Local CLI route")
            return
        }
        #expect(explicitConfig.effort == .high)
        #expect(settings.activeProfileId == active.id)
    }
}

extension ProfileCLIEffortTests {
    @Test("Automatic processing freezes the matched profile effort")
    func automaticConfigurationFreezesProfileEffort() {
        let settings = AppSettings()
        let originalProfiles = settings.profiles
        let originalActive = settings.activeProfileId
        let originalCLI = settings.localCLIConfig
        defer {
            settings.profiles = originalProfiles
            settings.activeProfileId = originalActive
            settings.localCLIConfig = originalCLI
        }
        settings.localCLIConfig = .init(command: "claude -p", timeoutSeconds: 180,
                                        effort: .medium, effortProvider: .claude)
        let profile = MeetingProfile(name: "High", overrides: .init(localCLIReasoningEffort: .high))
        settings.profiles = [profile]
        settings.setActiveProfile(profile.id)
        let frozen = AutomaticPostRecordingConfiguration(settings: settings)
        #expect(frozen.localCLI.effort == .high)
        settings.localCLIConfig.effort = .low
        #expect(frozen.localCLI.effort == .high)
    }

    @Test("Reprocessing uses profile effort and rejects changes to its frozen configuration")
    func reprocessingUsesProfileEffort() throws {
        let settings = AppSettings()
        let originalProfiles = settings.profiles
        let originalActive = settings.activeProfileId
        let originalCLI = settings.localCLIConfig
        defer {
            settings.profiles = originalProfiles
            settings.activeProfileId = originalActive
            settings.localCLIConfig = originalCLI
        }
        settings.localCLIConfig = .init(command: "claude -p", timeoutSeconds: 180,
                                        effort: .medium, effortProvider: .claude)
        let profile = MeetingProfile(name: "High", overrides: .init(localCLIReasoningEffort: .high))
        settings.profiles = [profile]
        settings.setActiveProfile(profile.id)
        var options = ReprocessingOptions(settings: settings, operation: .analysis)
        options.aiEngine = .localCLI
        #expect(try options.analysisConfiguration(settings: settings).localCLIConfig.effort == .high)
        settings.profiles[0].overrides.localCLIReasoningEffort = .low
        #expect(throws: ReprocessingOptions.ConfigurationError.self) {
            try options.analysisConfiguration(settings: settings)
        }
    }
}

extension ProfileCLIEffortTests {
    @Test("Profile export, import, and default reset preserve effort semantics")
    func exportImportAndResetEffort() throws {
        let settings = AppSettings()
        let originalProfiles = settings.profiles
        let originalActive = settings.activeProfileId
        defer {
            settings.profiles = originalProfiles
            settings.activeProfileId = originalActive
        }
        let profile = MeetingProfile(name: "Effort export", overrides: .init(
            localCLIReasoningEffort: .cliDefault, calendarCLIReasoningEffort: .max))
        settings.profiles = [AppSettings.defaultProfile(), profile]
        let export = try settings.exportProfiles(ids: [profile.id])
        let result = try settings.importProfiles(from: export)
        #expect(result.importedCount == 1)
        let imported = try #require(settings.profiles.last)
        #expect(imported.id != profile.id)
        #expect(imported.overrides.localCLIReasoningEffort == .cliDefault)
        #expect(imported.overrides.calendarCLIReasoningEffort == .max)
        settings.profiles[0].overrides.localCLIReasoningEffort = .high
        settings.resetDefaultProfileToBuiltInDefaults()
        #expect(settings.profiles[0].overrides.localCLIReasoningEffort == nil)
        #expect(settings.profiles.last?.overrides.localCLIReasoningEffort == .cliDefault)
    }
}
