import Testing
@testable import dBrief

@Suite("Overlay scrollers")
struct OverlayScrollerPolicyTests {
    @Test func alwaysShowScrollBarsWins() {
        #expect(!OverlayScrollerPolicy.forcesOverlay(showScrollBars: "Always"))
    }

    @Test func automaticAndWhenScrollingGetOverlays() {
        #expect(OverlayScrollerPolicy.forcesOverlay(showScrollBars: "Automatic"))
        #expect(OverlayScrollerPolicy.forcesOverlay(showScrollBars: "WhenScrolling"))
        #expect(OverlayScrollerPolicy.forcesOverlay(showScrollBars: nil))
    }
}
