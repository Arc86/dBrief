import Foundation
import Testing
@testable import dBrief

@Suite struct ViewerAppearanceTests {
@Test func parsesAndExportsEightBitHexColours() {
    let colour = ViewerRGB(hex: "#1268F5")!
    #expect(colour.red == 18.0 / 255.0)
    #expect(colour.green == 104.0 / 255.0)
    #expect(colour.blue == 245.0 / 255.0)
    #expect(colour.hex == "#1268F5")
    #expect(ViewerRGB(hex: colour.hex) == colour)
    #expect(ViewerRGB(hex: "1268F5") == colour)
    #expect(ViewerRGB(hex: "#12G8F5") == nil)
    #expect(ViewerRGB(hex: "#12345") == nil)
    #expect(ViewerRGB(hex: "+12345") == nil)
    #expect(ViewerRGB(hex: " #1268F5") == nil)
}

@Test func mixesAccentUsingTheAppearanceSpecificTargets() {
    let source = ViewerRGB(hex: "#1268F5")!
    let light = ViewerThemeResolver.resolve(mode: .light, sourceHex: source.hex, nonNeon: false)
    let dark = ViewerThemeResolver.resolve(mode: .dark, sourceHex: source.hex, nonNeon: false)
    let paper = ViewerThemeResolver.resolve(mode: .paper, sourceHex: source.hex, nonNeon: false)
    let darkPaper = ViewerThemeResolver.resolve(mode: .darkPaper, sourceHex: source.hex, nonNeon: false)

    #expect(light.primary.hex == "#1268F5")
    #expect(dark.primary.hex == "#3880F7")
    #expect(paper.primary.hex == "#2E6CD2")
    #expect(darkPaper.primary.hex == "#6090DE")
}

@Test func palettesMatchTheFourSurfaceTables() {
    let expected: [(ViewerAppearanceMode, String, String, String, String, String, String, String, String)] = [
        (.light, "#FBFCFE", "#FFFFFF", "#0B1430", "#31405F", "#65718A", "#E1E7F0", "#FAFBFD", "#F1F5FA"),
        (.dark, "#1B2029", "#242C38", "#F0F3FA", "#D2DAE8", "#A3AFC4", "#3A4658", "#202733", "#191F29"),
        (.paper, "#F5F2EB", "#FFFCF5", "#302D28", "#514B42", "#756D60", "#DBD4C5", "#F0ECE2", "#EAE5D9"),
        (.darkPaper, "#24211D", "#302C26", "#F0E8D8", "#D8CDB9", "#B9AD98", "#50483C", "#2B2721", "#211E19"),
    ]

    for (mode, canvas, surface, heading, text, secondary, divider, sidebarTop, sidebarBottom) in expected {
        let palette = ViewerThemeResolver.resolve(mode: mode, sourceHex: "#1268F5", nonNeon: false)
        #expect(palette.canvas.hex == canvas)
        #expect(palette.surface.hex == surface)
        #expect(palette.heading.hex == heading)
        #expect(palette.text.hex == text)
        #expect(palette.secondary.hex == secondary)
        #expect(palette.divider.hex == divider)
        #expect(palette.sidebarTop.hex == sidebarTop)
        #expect(palette.sidebarBottom.hex == sidebarBottom)
        #expect(palette.readingCardCornerRadius == 20)
    }
}

@Test func accentsStayReadableAcrossAllModesAndSourceColours() {
    let sources = ["#1268F5", "#7054D9", "#19745B", "#FF962C", "#000000", "#FFFFFF"]

    for mode in ViewerAppearanceMode.allCases {
        for source in sources {
            let palette = ViewerThemeResolver.resolve(mode: mode, sourceHex: source, nonNeon: true)
            // WCAG 3:1 for bold UI text on filled buttons, as macOS accent buttons do.
            #expect(ViewerThemeResolver.contrast(palette.primary, palette.onPrimary) >= 3)
            #expect(ViewerThemeResolver.contrast(palette.accentText, palette.surface) >= 4.5)
            #expect(ViewerThemeResolver.contrast(palette.accentText, palette.selected) >= 4.5)
            #expect(palette.brandStops.allSatisfy { $0 == palette.primary })
        }
    }
}

@Test func filledButtonsUseWhiteTextLikeMacOSAccentButtons() {
    // Dark mode lightens the default blue to #3880F7: white is 3.75:1, black 5.6:1.
    for mode in ViewerAppearanceMode.allCases {
        let palette = ViewerThemeResolver.resolve(mode: mode, sourceHex: "#1268F5", nonNeon: false)
        #expect(palette.onPrimary.hex == "#FFFFFF", "\(mode)")
    }
    // A very pale accent still gets dark text.
    #expect(ViewerThemeResolver.resolve(mode: .light, sourceHex: "#FFFFFF", nonNeon: false).onPrimary.hex == "#000000")
}

@Test func paletteUsesFixedBrandStopsUnlessNonNeonIsSelected() {
    let expectedBrand = ["#FFA52C", "#FF4B65", "#FA27BB", "#8B39FA", "#3261FF", "#00C8FF"]
        .map { ViewerRGB(hex: $0)! }

    for mode in ViewerAppearanceMode.allCases {
        let brand = ViewerThemeResolver.resolve(mode: mode, sourceHex: "#19745B", nonNeon: false)
        let nonNeon = ViewerThemeResolver.resolve(mode: mode, sourceHex: "#19745B", nonNeon: true)
        #expect(brand.brandStops == expectedBrand)
        #expect(nonNeon.brandStops == Array(repeating: nonNeon.primary, count: expectedBrand.count))
    }
}

@Test func malformedAccentUsesTheDefaultBlue() {
    let fallback = ViewerThemeResolver.resolve(mode: .light, sourceHex: "#1268F5", nonNeon: false)
    for malformed in ["", "blue", "#12G8F5", "#12345", "#12345678"] {
        #expect(ViewerThemeResolver.resolve(mode: .light, sourceHex: malformed, nonNeon: false) == fallback)
    }
}
}
