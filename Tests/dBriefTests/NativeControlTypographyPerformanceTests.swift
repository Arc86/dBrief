import AppKit
import Testing
@testable import dBrief

@Suite @MainActor struct NativeControlTypographyPerformanceTests {
    @Test func plainPlaceholderKeepsAPlaceholderColour() {
        // A plain placeholder converted to an attributed string without a colour
        // draws in default black — unreadable on the dark themes.
        let root = NSView()
        let field = NSTextField()
        field.placeholderString = "Search recordings…"
        root.addSubview(field)
        NativeControlTypographyApplicator().apply(to: root, preferences: AppTypographyPreferences())
        let styled = field.placeholderAttributedString
        #expect(styled != nil)
        #expect(styled?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .placeholderTextColor)
    }

    @Test func attributedPlaceholderColourIsNotOverridden() {
        let root = NSView()
        let field = NSTextField()
        field.placeholderAttributedString = NSAttributedString(string: "Search", attributes: [
            .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.systemPink
        ])
        root.addSubview(field)
        NativeControlTypographyApplicator().apply(to: root, preferences: AppTypographyPreferences())
        #expect(field.placeholderAttributedString?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemPink)
    }

    @Test func windowUpdatesDoNotWalkTheWindowWhileTypographyIsDefault() {
        let standard = AppTypographyPreferences()
        // Nothing custom is applied and nothing custom was applied before.
        #expect(!NativeControlTypographyHost.shouldRefresh(
            preferences: standard, lastApplied: standard, trigger: .windowUpdate))
        #expect(!NativeControlTypographyHost.shouldRefresh(
            preferences: standard, lastApplied: nil, trigger: .windowUpdate))
    }

    @Test func customTypographyStillRefreshesOnWindowUpdates() {
        let custom = AppTypographyPreferences(readingFont: .georgia, fontSize: 16)
        #expect(NativeControlTypographyHost.shouldRefresh(
            preferences: custom, lastApplied: custom, trigger: .windowUpdate))
    }

    @Test func returningToDefaultRestoresControlsOnce() {
        let standard = AppTypographyPreferences()
        let custom = AppTypographyPreferences(readingFont: .georgia, fontSize: 16)
        #expect(NativeControlTypographyHost.shouldRefresh(
            preferences: standard, lastApplied: custom, trigger: .windowUpdate))
    }

    @Test func explicitUpdatesAlwaysRefresh() {
        let standard = AppTypographyPreferences()
        #expect(NativeControlTypographyHost.shouldRefresh(
            preferences: standard, lastApplied: standard, trigger: .swiftUIUpdate))
    }

    @Test func windowUpdateRefreshesAreThrottled() {
        #expect(NativeControlTypographyHost.isThrottled(sinceLastRefresh: 0.02))
        #expect(!NativeControlTypographyHost.isThrottled(sinceLastRefresh: 0.5))
    }
}
