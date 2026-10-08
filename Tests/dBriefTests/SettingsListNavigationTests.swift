import Testing
@testable import dBrief

@Suite("Settings list arrow-key navigation")
struct SettingsListNavigationTests {
    @Test("Steps from the current row and stops at both ends")
    func steps() {
        let ids = [1, 2, 3]
        #expect(SettingsListNavigation.step(1, in: ids, from: 2) == 3)
        #expect(SettingsListNavigation.step(-1, in: ids, from: 2) == 1)
        #expect(SettingsListNavigation.step(1, in: ids, from: 3) == 3)
        #expect(SettingsListNavigation.step(-1, in: ids, from: 1) == 1)
    }

    @Test("Starts at the first row when nothing (or a vanished row) is selected")
    func noCurrent() {
        #expect(SettingsListNavigation.step(1, in: [1, 2], from: nil) == 1)
        #expect(SettingsListNavigation.step(1, in: [1, 2], from: 9) == 1)
        #expect(SettingsListNavigation.step(1, in: [Int](), from: nil) == nil)
    }
}
