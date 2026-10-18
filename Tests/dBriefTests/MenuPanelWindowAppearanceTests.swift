import AppKit
import Testing
@testable import dBrief

struct MenuPanelWindowAppearanceTests {
    @Test func panelWindowFollowsTheAppThemeNotTheSystem() {
        #expect(MenuPanelWindowAppearance.appearanceName(for: .dark) == .darkAqua)
        #expect(MenuPanelWindowAppearance.appearanceName(for: .darkPaper) == .darkAqua)
        #expect(MenuPanelWindowAppearance.appearanceName(for: .light) == .aqua)
        #expect(MenuPanelWindowAppearance.appearanceName(for: .paper) == .aqua)
    }
}
