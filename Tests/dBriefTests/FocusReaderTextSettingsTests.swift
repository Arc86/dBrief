import Testing
@testable import dBrief

@Suite("Focus Reader text settings")
struct FocusReaderTextSettingsTests {
    @Test func startsLargerThanTheViewerAndStepsInTwos() {
        var settings = FocusReaderTextSettings()
        #expect(settings.size == 22)
        settings.enlarge()
        #expect(settings.size == 24)
        settings.shrink()
        settings.shrink()
        #expect(settings.size == 20)
    }

    @Test func pinchScalesFromTheSizeWhenThePinchBegan() {
        let start = FocusReaderTextSettings(size: 20)
        #expect(start.pinched(by: 1.5).size == 30)
        #expect(start.pinched(by: 0.1).size == FocusReaderTextSettings.sizeRange.lowerBound)
        #expect(start.pinched(by: 10).size == FocusReaderTextSettings.sizeRange.upperBound)
    }

    @Test func sizeStaysWithinItsRange() {
        var settings = FocusReaderTextSettings(size: 39)
        settings.enlarge()
        settings.enlarge()
        #expect(settings.size == FocusReaderTextSettings.sizeRange.upperBound)
        #expect(FocusReaderTextSettings(size: 3).size == FocusReaderTextSettings.sizeRange.lowerBound)
    }

    @Test @MainActor func appliesSizeAndFontWithoutTouchingTheViewersOtherChoices() {
        var viewer = ViewerAppearancePreferences()
        viewer.readingFont = .georgia
        viewer.density = .spacious
        let followed = FocusReaderTextSettings(size: 36).applied(to: viewer)
        #expect(followed.effectiveFontSize == 36)
        #expect(followed.fontSize == viewer.fontSize) // the viewer's own size is untouched
        #expect(followed.readingFont == .georgia)
        #expect(followed.density == .spacious)
        let chosen = FocusReaderTextSettings(size: 30, font: .openDyslexic).applied(to: viewer)
        #expect(chosen.readingFont == .openDyslexic)
        #expect(chosen.effectiveFontSize == 30)
        #expect(ViewerFonts.nsFont(for: chosen, effectiveMode: .light).pointSize == 30)
    }
}

@Suite("Focus Reader width")
struct FocusReaderWidthTests {
    @Test func defaultsToWideAndFullWidthHasNoCap() {
        #expect(FocusReaderWidth.default == .wide)
        #expect(FocusReaderWidth.narrow.maxWidth == 680)
        #expect(FocusReaderWidth.medium.maxWidth! < FocusReaderWidth.wide.maxWidth!)
        #expect(FocusReaderWidth.full.maxWidth == nil)
        #expect(FocusReaderWidth(rawValue: "unknown") == nil)
        #expect(Set(FocusReaderWidth.allCases.map(\.title)).count == FocusReaderWidth.allCases.count)
    }
}

@Suite("Focus Reader line spacing")
struct FocusReaderLineSpacingTests {
    @Test func lineHeightIsClampedAndApplied() {
        #expect(FocusReaderTextSettings().lineHeight == FocusReaderTextSettings.defaultLineHeight)
        #expect(FocusReaderTextSettings(lineHeight: 9).lineHeight == FocusReaderTextSettings.lineHeightRange.upperBound)
        #expect(FocusReaderTextSettings(lineHeight: 0.5).lineHeight == FocusReaderTextSettings.lineHeightRange.lowerBound)
        let viewer = ViewerAppearancePreferences()
        let applied = FocusReaderTextSettings(lineHeight: 2.2).applied(to: viewer)
        #expect(applied.displayLineHeightOverride == 2.2)
        #expect(applied.density == viewer.density)
        #expect(FocusReaderTextSettings(size: 30, lineHeight: 2.2).pinched(by: 1.2).lineHeight == 2.2)
    }

    @Test @MainActor func moreLineHeightMeansMoreSpacing() {
        let viewer = ViewerAppearancePreferences()
        let tight = ViewerFonts.additionalLineSpacing(for: FocusReaderTextSettings(lineHeight: 1.4).applied(to: viewer),
                                                      effectiveMode: .light)
        let loose = ViewerFonts.additionalLineSpacing(for: FocusReaderTextSettings(lineHeight: 2.4).applied(to: viewer),
                                                      effectiveMode: .light)
        #expect(loose > tight)
    }
}
