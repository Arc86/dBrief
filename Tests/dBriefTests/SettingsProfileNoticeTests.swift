import Testing
@testable import dBrief

@MainActor
struct SettingsProfileNoticeTests {
    @Test func inheritedFieldsProduceNoNotice() {
        let settings = AppSettings()
        let profile = MeetingProfile(name: "Plain")
        let scope = SettingsProfileScope(settings: settings, profile: profile, fields: SettingsPage.ai.profileFields)
        #expect(SettingsProfileScopeView.visibleOverrides(scope.summaries).isEmpty)
    }

    @Test func overriddenFieldsAreListed() {
        let settings = AppSettings()
        var profile = MeetingProfile(name: "Team")
        profile.overrides.aiProcessingEnabled = !settings.aiProcessingEnabled
        let scope = SettingsProfileScope(settings: settings, profile: profile, fields: SettingsPage.ai.profileFields)
        #expect(SettingsProfileScopeView.visibleOverrides(scope.summaries).map(\.id) == [.aiEnabled])
    }
}
