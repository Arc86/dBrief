import AppKit
import Testing
@testable import dBrief

@Suite @MainActor struct NativeControlTypographyTests {
    private final class ActionTarget: NSObject {
        var calls = 0
        @objc func invoke(_ sender: Any?) { calls += 1 }
    }

    @Test func buttonTitleUsesSelectedFontAndPreservesNativeBehavior() throws {
        let root = NSView()
        let target = ActionTarget()
        let button = NSButton(title: "Continue", target: target, action: #selector(ActionTarget.invoke(_:)))
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .bold)
        button.attributedTitle = NSAttributedString(string: "Continue", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.systemBlue
        ])
        root.addSubview(button)
        let preferences = AppTypographyPreferences(readingFont: .georgia, fontSize: 16)
        NativeControlTypographyApplicator().apply(to: root, preferences: preferences)
        let expected = AppFontStyle.system(size: 11, weight: .bold).nsFont(using: preferences)
        #expect(button.font == expected)
        #expect(button.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == expected)
        #expect(button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemBlue)
        #expect(button.controlSize == .small)
        #expect(button.target === target)
        #expect(button.action == #selector(ActionTarget.invoke(_:)))
        button.performClick(nil)
        #expect(target.calls == 1)
    }

    @Test func fieldsPreserveRichRunsAndStyleAttributedAndPlainPlaceholders() throws {
        let root = NSView()
        let field = NSTextField()
        field.font = .systemFont(ofSize: 12)
        field.attributedStringValue = NSAttributedString(string: "Name", attributes: [.font: NSFont.systemFont(ofSize: 10)])
        field.placeholderAttributedString = NSAttributedString(string: "Search", attributes: [
            .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor
        ])
        let plain = NSTextField()
        plain.font = .systemFont(ofSize: 12)
        plain.placeholderString = "Type here"
        root.addSubview(field)
        root.addSubview(plain)
        let preferences = AppTypographyPreferences(readingFont: .georgia, fontSize: 18)
        NativeControlTypographyApplicator().apply(to: root, preferences: preferences)
        #expect(field.font == AppFontStyle.system(size: 12).nsFont(using: AppTypographyPreferences(readingFont: preferences.readingFont)))
        #expect(field.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                == AppFontStyle.system(size: 10).nsFont(using: AppTypographyPreferences(readingFont: preferences.readingFont)))
        let placeholder = try #require(field.placeholderAttributedString)
        #expect(placeholder.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                == AppFontStyle.system(size: 9).nsFont(using: AppTypographyPreferences(readingFont: preferences.readingFont)))
        #expect(placeholder.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
        #expect(plain.placeholderAttributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                == AppFontStyle.system(size: 12).nsFont(using: AppTypographyPreferences(readingFont: preferences.readingFont)))
        #expect(field.isEditable)
        #expect(field.isSelectable)
    }

    @Test func popupMenusAndSubmenusKeepSelectionAndActions() throws {
        let root = NSView()
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.font = .systemFont(ofSize: 11)
        popup.addItems(withTitles: ["Alice", "Bob"])
        popup.selectItem(at: 1)
        let menu = try #require(popup.menu)
        let selectedTitle = NSAttributedString(string: "Bob", attributes: [.font: NSFont.menuFont(ofSize: 11)])
        popup.selectedItem?.attributedTitle = selectedTitle
        menu.font = .menuFont(ofSize: 12)
        let submenu = NSMenu(title: "People")
        submenu.font = .menuFont(ofSize: 10)
        submenu.addItem(withTitle: "Carol", action: nil, keyEquivalent: "")
        menu.items[0].submenu = submenu
        root.addSubview(popup)
        let preferences = AppTypographyPreferences(readingFont: .georgia, fontSize: 16)
        let applicator = NativeControlTypographyApplicator()
        applicator.apply(to: root, preferences: preferences)
        applicator.apply(to: root, preferences: preferences)
        #expect(popup.indexOfSelectedItem == 1)
        #expect(popup.titleOfSelectedItem == "Bob")
        #expect(popup.font == AppFontStyle.system(size: 11).nsFont(using: preferences))
        #expect(menu.font == AppFontStyle.system(size: 12).nsFont(using: preferences))
        #expect(menu.items[1].attributedTitle === selectedTitle)
        #expect(submenu.font == AppFontStyle.system(size: 10).nsFont(using: preferences))
        #expect(submenu.items[0].attributedTitle == nil)
    }

    @Test func liveChangesNeverMultiplyScaleAndNewControlsAreDiscovered() throws {
        let root = NSView()
        let button = NSButton(title: "Save", target: nil, action: nil)
        button.font = .systemFont(ofSize: 11)
        root.addSubview(button)
        let applicator = NativeControlTypographyApplicator()
        for preferences in [AppTypographyPreferences(readingFont: .georgia, fontSize: 18),
                            AppTypographyPreferences(readingFont: .sanFrancisco, fontSize: 16),
                            AppTypographyPreferences(readingFont: .georgia, fontSize: 18),
                            AppTypographyPreferences()] {
            for _ in 0..<3 { applicator.apply(to: root, preferences: preferences) }
            let expected = AppFontStyle.system(size: 11).nsFont(using: preferences)
            #expect(button.font == expected)
            #expect(button.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == expected)
        }
        let newField = NSTextField(labelWithString: "Later")
        newField.font = .systemFont(ofSize: 9)
        root.addSubview(newField)
        let preferences = AppTypographyPreferences(readingFont: .georgia, fontSize: 16)
        applicator.apply(to: root, preferences: preferences)
        #expect(newField.font == AppFontStyle.system(size: 9).nsFont(using: AppTypographyPreferences(readingFont: preferences.readingFont)))
    }

    @Test func dynamicallyCreatedMenuHierarchyUsesOriginalSizesAcrossUpdates() throws {
        let target = ActionTarget()
        let menu = NSMenu(title: "Speakers")
        menu.font = .menuFont(ofSize: 12)
        let speaker = menu.addItem(withTitle: "Alice", action: #selector(ActionTarget.invoke(_:)), keyEquivalent: "a")
        speaker.target = target
        let submenu = NSMenu(title: "Others")
        submenu.font = .menuFont(ofSize: 10)
        submenu.addItem(withTitle: "Bob", action: nil, keyEquivalent: "")
        speaker.submenu = submenu
        let applicator = NativeControlTypographyApplicator()
        for preferences in [AppTypographyPreferences(readingFont: .georgia, fontSize: 18),
                            AppTypographyPreferences(readingFont: .sanFrancisco, fontSize: 16),
                            AppTypographyPreferences()] {
            for _ in 0..<3 { applicator.apply(to: menu, preferences: preferences) }
            #expect(menu.font == AppFontStyle.system(size: 12).nsFont(using: preferences))
            #expect(speaker.attributedTitle == nil)
            #expect(submenu.font == AppFontStyle.system(size: 10).nsFont(using: preferences))
        }
        let later = menu.addItem(withTitle: "Carol", action: nil, keyEquivalent: "")
        let preferences = AppTypographyPreferences(readingFont: .georgia, fontSize: 16)
        applicator.apply(to: menu, preferences: preferences)
        #expect(later.attributedTitle == nil)
        #expect(speaker.target === target)
        #expect(speaker.action == #selector(ActionTarget.invoke(_:)))
        #expect(speaker.keyEquivalent == "a")
    }


    @Test func menuTypographyPreservesNativeAndHostedTitles() {
        let menu = NSMenu(title: "Themes")
        let native = menu.addItem(withTitle: "Light", action: nil, keyEquivalent: "")
        let styled = menu.addItem(withTitle: "Dark", action: nil, keyEquivalent: "")
        let original = NSAttributedString(string: "Dark", attributes: [
            .font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.labelColor
        ])
        styled.attributedTitle = original
        // SwiftUI can own an item's title/view instead of supplying an AppKit string.
        let hosted = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        let titleView = NSTextField(labelWithString: "Follow System")
        hosted.view = titleView
        let applicator = NativeControlTypographyApplicator()
        for font in [ViewerReadingFont.georgia, .sanFrancisco] {
            applicator.apply(to: menu, preferences: AppTypographyPreferences(readingFont: font, fontSize: 16))
            #expect(native.title == "Light")
            #expect(native.attributedTitle == nil, "Do not replace native menu drawing with an attributed title")
            #expect(styled.attributedTitle === original, "The menu renderer owns attributed title metadata")
            #expect(hosted.attributedTitle == nil, "An empty title would hide a SwiftUI-owned menu label")
            #expect(hosted.view === titleView)
            #expect(titleView.stringValue == "Follow System")
        }
    }

    @Test func menuTrackingContextRequiresTheAttachedActiveWindow() {
        let host = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        let other = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        #expect(NativeControlTypographyHost.ownsTrackingContext(
            hostWindow: host, eventWindow: host, keyWindow: nil, mainWindow: nil))
        #expect(NativeControlTypographyHost.ownsTrackingContext(
            hostWindow: host, eventWindow: nil, keyWindow: host, mainWindow: nil))
        #expect(NativeControlTypographyHost.ownsTrackingContext(
            hostWindow: host, eventWindow: nil, keyWindow: nil, mainWindow: host))
        #expect(!NativeControlTypographyHost.ownsTrackingContext(
            hostWindow: host, eventWindow: other, keyWindow: host, mainWindow: host))
        #expect(!NativeControlTypographyHost.ownsTrackingContext(
            hostWindow: host, eventWindow: nil, keyWindow: other, mainWindow: host))
        #expect(!NativeControlTypographyHost.ownsTrackingContext(
            hostWindow: nil, eventWindow: host, keyWindow: host, mainWindow: host))
    }

    @Test func documentAndCustomTextViewsKeepTheirOwnTypography() {
        let root = NSView()
        let document = NSTextView()
        document.isEditable = false
        document.string = "Transcript"
        document.font = .systemFont(ofSize: 21)
        let editor = NSTextView()
        editor.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        root.addSubview(document)
        root.addSubview(editor)
        NativeControlTypographyApplicator().apply(to: root,
            preferences: AppTypographyPreferences(readingFont: .georgia, fontSize: 18))
        #expect(document.font == NSFont.systemFont(ofSize: 21))
        #expect(editor.font == NSFont.monospacedSystemFont(ofSize: 15, weight: .regular))
    }
}
