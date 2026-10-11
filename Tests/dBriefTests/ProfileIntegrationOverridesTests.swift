import Foundation
import Testing
@testable import dBrief

@MainActor
@Suite(.serialized)
struct ProfileIntegrationOverridesTests {
    private func withSettings(_ body: (AppSettings) throws -> Void) throws {
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        try #require(!domain.hasPrefix("com.dbrief.app"))
        let defaults = UserDefaults.standard
        let saved = defaults.persistentDomain(forName: domain)
        defer {
            if let saved { defaults.setPersistentDomain(saved, forName: domain) }
            else { defaults.removePersistentDomain(forName: domain) }
        }
        let settings = AppSettings()
        var integrations = IntegrationSettings()
        integrations.tickTick = TickTickConfig(enabled: true, projectID: "base-tt", projectName: "Base list")
        integrations.todoist = TodoistConfig(enabled: true, projectID: "base-td", projectName: "Base project")
        settings.integrations = integrations
        try body(settings)
    }

    @Test func profileOverridesListAndProjectIncludingInbox() throws {
        try withSettings { settings in
            let profile = MeetingProfile(name: "Sales", overrides: .init(
                tickTickProjectID: "p-tt", tickTickProjectName: "Work", todoistProjectID: "", todoistProjectName: nil))
            settings.profiles = [MeetingProfile(name: "Default"), profile]
            let resolved = settings.resolvedIntegrations(for: profile.id)
            #expect(resolved.tickTick == TickTickConfig(enabled: true, projectID: "p-tt", projectName: "Work"))
            #expect(resolved.todoist == TodoistConfig(enabled: true, projectID: nil, projectName: nil))
            #expect(resolved.webhook == settings.integrations.webhook)
        }
    }

    @Test func profileOverridesTheNotionDestination() throws {
        try withSettings { settings in
            settings.integrations.notion = {
                var notion = NotionConfig()
                notion.enabled = true
                notion.parentType = .page
                notion.parentID = "base-page"
                notion.parentName = "Base page"
                return notion
            }()
            let profile = MeetingProfile(name: "Sales", overrides: .init(
                notionParentID: "ds-1", notionParentType: NotionParentType.dataSource.rawValue, notionParentName: "Deals"))
            settings.profiles = [profile]
            let notion = settings.resolvedIntegrations(for: profile.id).notion
            #expect(notion.parentID == "ds-1" && notion.parentType == .dataSource && notion.parentName == "Deals")
            #expect(notion.enabled && notion.fields == settings.integrations.notion.fields)
        }
    }

    @Test func notionSettingsSavedBeforeThisChangeStillDecode() throws {
        let legacy = Data(#"""
        {"enabled":true,"tokenKeychainKey":"integration.notion.token","parentType":"page","parentID":"abc",
         "titlePropertyName":"Name","fields":["summary"]}
        """#.utf8)
        let notion = try JSONDecoder().decode(NotionConfig.self, from: legacy)
        #expect(notion.parentID == "abc" && notion.parentName == nil && notion.fields == [.summary])
    }

    @Test func noOverrideUnknownOrMissingProfileUsesDefaults() throws {
        try withSettings { settings in
            let plain = MeetingProfile(name: "Plain")
            settings.profiles = [plain]
            #expect(settings.resolvedIntegrations(for: nil) == settings.integrations)
            #expect(settings.resolvedIntegrations(for: UUID()) == settings.integrations)
            #expect(settings.resolvedIntegrations(for: plain.id) == settings.integrations)
        }
    }

    @Test func resolutionUsesTheGivenProfileNotTheActiveOne() throws {
        try withSettings { settings in
            let recorded = MeetingProfile(name: "Recorded", overrides: .init(todoistProjectID: "rec", todoistProjectName: "Rec"))
            let active = MeetingProfile(name: "Active", overrides: .init(todoistProjectID: "act", todoistProjectName: "Act"))
            settings.profiles = [recorded, active]
            settings.setActiveProfile(active.id)
            #expect(settings.resolvedIntegrations(for: recorded.id).todoist.projectID == "rec")
            let recordedDigest = try IntegrationDeliveryBatch.configurationDigests(settings.resolvedIntegrations(for: recorded.id))
            let activeDigest = try IntegrationDeliveryBatch.configurationDigests(settings.resolvedIntegrations(for: active.id))
            #expect(recordedDigest[.todoist] != activeDigest[.todoist])
        }
    }

    @Test func savedProfilesAndBatchesWithoutTheNewFieldsStillDecode() throws {
        let overrides = try JSONDecoder().decode(MeetingProfileOverrides.self, from: Data(#"{"autoSummary":true}"#.utf8))
        #expect(overrides.autoSummary == true)
        #expect(overrides.tickTickProjectID == nil && overrides.todoistProjectID == nil)
        let batch = IntegrationDeliveryBatch(id: UUID(), recordingID: UUID(), createdAt: Date(),
            bundle: .init(title: "T", createdAt: Date(), durationSeconds: 1, audioFileURL: URL(fileURLWithPath: "/tmp/a.m4a"),
                          transcript: nil, summary: nil, actionItems: [], tags: [], sentiment: nil, markdown: nil,
                          calendarEvent: nil),
            deliveries: [], profileID: UUID())
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as? [String: Any])
        #expect(object["profileID"] != nil)
        object["profileID"] = nil
        let legacy = try JSONDecoder().decode(IntegrationDeliveryBatch.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.profileID == nil)
    }

    @Test func profileNoticeShowsTheOverriddenListAndProject() throws {
        try withSettings { settings in
            let profile = MeetingProfile(name: "Sales", overrides: .init(
                tickTickProjectID: "p-tt", tickTickProjectName: "Work", todoistProjectID: ""))
            settings.profiles = [profile]
            settings.setActiveProfile(profile.id)
            let scope = SettingsProfileScope(settings: settings)
            let tickTick = scope.summary(for: .tickTickList)
            #expect(tickTick.isOverridden && tickTick.profileValue == "Work" && tickTick.defaultValue == "Base list")
            let todoist = scope.summary(for: .todoistProject)
            #expect(todoist.isOverridden && todoist.profileValue == "Inbox" && todoist.defaultValue == "Base project")
        }
    }
}
