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
