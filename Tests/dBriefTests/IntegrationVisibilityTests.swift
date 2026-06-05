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
}
