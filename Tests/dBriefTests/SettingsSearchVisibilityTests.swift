import Testing
@testable import dBrief

struct SettingsSearchVisibilityTests {
    @Test func sidebarArrowKeysStayOutOfTheSearchField() {
        #expect(SettingsSidebarKeys.handlesArrows(isSearching: false, searchFocused: false))
        #expect(!SettingsSidebarKeys.handlesArrows(isSearching: true, searchFocused: false))
        #expect(!SettingsSidebarKeys.handlesArrows(isSearching: false, searchFocused: true))
    }

    @Test func calendarSearchTargetsRenderWhateverTheSource() {
        #expect(!SettingsCalendarVisibility.showsMatching(source: .disabled, request: nil))
        #expect(SettingsCalendarVisibility.showsMatching(source: .disabled, request: SettingsSearchRequest(section: .meetingMatching)))
        #expect(SettingsCalendarVisibility.showsMatching(source: .iCal, request: nil))
        #expect(!SettingsCalendarVisibility.showsClaudeCLI(source: .iCal, request: nil))
        #expect(SettingsCalendarVisibility.showsClaudeCLI(source: .iCal, request: SettingsSearchRequest(section: .calendarCLIAdvanced)))
        #expect(SettingsCalendarVisibility.showsClaudeCLI(source: .claudeCLI, request: nil))
    }
}
