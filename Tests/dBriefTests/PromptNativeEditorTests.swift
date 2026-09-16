import AppKit
import SwiftUI
import Testing
@testable import dBrief

@MainActor @Suite("Prompt native editor", .serialized)
struct PromptNativeEditorTests {
    @Test func typingUndoSurvivesPanelAndSizeChanges() async throws {
        _ = NSApplication.shared
        let settings = AppSettings()
        let session = try PromptEditorSession(identity: .init(kind: .summary, scope: .appDefaults),
            store: PromptPreferencesStore(settings: settings))
        let original = session.draft.text
        let saved = settings.summaryPrompt
        let controller = NSHostingController(rootView: PromptEditorView(session: session, close: {}))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 980, height: 700),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        let toolbar = PromptEditorToolbar(session: session)
        toolbar.install(on: window)
        #expect(window.toolbar != nil)
        #expect(window.toolbarStyle == .unified)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        try await settle(window)
        let first = try #require(editor(in: controller.view))
        #expect(first.undoManager === session.undoManager)
        first.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
        session.undoManager?.groupsByEvent = false
        session.undoManager?.beginUndoGrouping()
        first.insertText(" Added detail.", replacementRange: first.selectedRange())
        session.undoManager?.endUndoGrouping()
        #expect(session.draft.text == original + " Added detail.")
        #expect(settings.summaryPrompt == saved)

        session.panel = .improve
        try await settle(window)
        window.setContentSize(NSSize(width: 700, height: 530))
        try await settle(window)
        session.panel = .none
        try await settle(window)
        let recreated = try #require(editor(in: controller.view))
        #expect(recreated.undoManager === session.undoManager)
        #expect(recreated.bounds.width > 300)
        #expect(recreated.validateUserInterfaceItem(NSMenuItem(title: "Undo", action: #selector(PromptNativeTextView.undo(_:)), keyEquivalent: "z")))
        recreated.undo(nil)
        try await settle(window)
        #expect(session.draft.text == original)
        #expect(recreated.string == original)
        #expect(!session.draft.hasChanges)
        #expect(settings.summaryPrompt == saved)
        #expect(window.contentView!.bounds.height <= 531)
        _ = toolbar // Keep the weak NSToolbar delegate alive through the test.
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(30))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }
    private func editor(in view: NSView) -> PromptNativeTextView? {
        if let editor = view as? PromptNativeTextView { return editor }
        for child in view.subviews { if let found = editor(in: child) { return found } }
        return nil
    }
}
