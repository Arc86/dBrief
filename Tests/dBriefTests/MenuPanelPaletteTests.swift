import Foundation
import Testing
@testable import dBrief

@Suite struct MenuPanelPaletteTests {
    private func palettes(accent: String = "#1268F5") -> [(ViewerAppearanceMode, ViewerPalette, MenuPanelPalette)] {
        ViewerAppearanceMode.allCases.map { mode in
            let base = ViewerThemeResolver.resolve(mode: mode, sourceHex: accent, nonNeon: false)
            return (mode, base, MenuPanelPalette.resolve(mode: mode, base: base))
        }
    }

    @Test func matchesThePenSignatureValues() {
        let light = MenuPanelPalette.resolve(mode: .light, base: ViewerThemeResolver.resolve(mode: .light, sourceHex: "#1268F5", nonNeon: false))
        let dark = MenuPanelPalette.resolve(mode: .dark, base: ViewerThemeResolver.resolve(mode: .dark, sourceHex: "#1268F5", nonNeon: false))
        #expect(light.success.hex == "#23804C")
        #expect(light.danger.hex == "#B93852")
        #expect(light.dangerFill.hex == "#FFF2F5")
        #expect(dark.success.hex == "#7BDCAA")
        #expect(dark.danger.hex == "#FF91A6")
        #expect(dark.dangerFill.hex == "#382935")
    }

    @Test func statusTextIsReadableInEveryMode() {
        for (mode, base, panel) in palettes() {
            #expect(ViewerThemeResolver.contrast(panel.success, base.surface) >= 4.5, "success in \(mode)")
            #expect(ViewerThemeResolver.contrast(panel.danger, base.surface) >= 4.5, "danger in \(mode)")
            #expect(ViewerThemeResolver.contrast(panel.danger, panel.dangerFill) >= 4.5, "danger on fill in \(mode)")
            #expect(ViewerThemeResolver.contrast(panel.success, panel.successFill) >= 4.5, "success on fill in \(mode)")
        }
    }

    @Test func accentBorderFollowsTheConfiguredAccent() {
        let blue = palettes(accent: "#1268F5")
        let orange = palettes(accent: "#E8590C")
        for (b, o) in zip(blue, orange) {
            #expect(b.2.accentBorder != o.2.accentBorder, "accent border ignores accent in \(b.0)")
            // Halfway between primary and surface: visible but quieter than the primary.
            #expect(ViewerThemeResolver.contrast(o.2.accentBorder, o.1.surface) < ViewerThemeResolver.contrast(o.1.primary, o.1.surface))
        }
    }
}
