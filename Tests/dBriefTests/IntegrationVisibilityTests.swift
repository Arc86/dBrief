import Testing
@testable import dBrief

struct IntegrationVisibilityTests {
    @Test("available lists exactly the four trusted destinations")
    func testAvailableTrustedOnly() {
        #expect(IntegrationDestination.available == [.obsidian, .appleNotes, .appleReminders, .webhook])
    }

    @Test("available excludes untested destinations")
    func testAvailableExcludesUntested() {
        #expect(!IntegrationDestination.available.contains(.notion))
        #expect(!IntegrationDestination.available.contains(.evernote))
        #expect(!IntegrationDestination.available.contains(.googleKeep))
        #expect(!IntegrationDestination.available.contains(.oneNote))
    }

    @Test("isConfigured is false for placeholder and empty client IDs")
    @MainActor
    func testIsConfiguredFalseForPlaceholder() {
        #expect(MicrosoftAuthService.isConfigured(clientID: "YOUR-AZURE-CLIENT-ID") == false)
        #expect(MicrosoftAuthService.isConfigured(clientID: "") == false)
    }

    @Test("isConfigured is true for a real client ID")
    @MainActor
    func testIsConfiguredTrueForRealID() {
        #expect(MicrosoftAuthService.isConfigured(clientID: "11111111-2222-3333-4444-555555555555") == true)
    }

    @Test("resolveCalendarSource coerces outlook to disabled when unconfigured")
    @MainActor
    func testResolveOutlookUnconfigured() {
        #expect(AppSettings.resolveCalendarSource(.outlook, outlookConfigured: false) == .disabled)
    }

    @Test("resolveCalendarSource keeps outlook when configured")
    @MainActor
    func testResolveOutlookConfigured() {
        #expect(AppSettings.resolveCalendarSource(.outlook, outlookConfigured: true) == .outlook)
    }

    @Test("resolveCalendarSource passes iCal and disabled through unchanged")
    @MainActor
    func testResolvePassThrough() {
        #expect(AppSettings.resolveCalendarSource(.iCal, outlookConfigured: false) == .iCal)
        #expect(AppSettings.resolveCalendarSource(.iCal, outlookConfigured: true) == .iCal)
        #expect(AppSettings.resolveCalendarSource(.disabled, outlookConfigured: true) == .disabled)
    }
}
