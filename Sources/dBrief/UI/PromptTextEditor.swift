import AppKit
import SwiftUI

/// Immediate, in-memory editing. No preference writes or debounced teardown commits.
struct PromptTextEditor: NSViewRepresentable {
    @Bindable var session: PromptEditorSession
    var fontSize: Double

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let text = PromptNativeTextView()
        text.promptUndoManager = session.undoManager ?? UndoManager()
        text.isRichText = false
        // Model undo restores inheritance metadata together with the text.
        text.allowsUndo = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 22, height: 18)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        text.defaultParagraphStyle = paragraph
        text.font = .systemFont(ofSize: fontSize)
        text.string = session.draft.text
        text.delegate = context.coordinator
        text.setAccessibilityLabel("\(session.identity.kind.title) prompt instructions")
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.session = session
        text.font = .systemFont(ofSize: fontSize)
        if text.string != session.draft.text {
            let selection = text.selectedRange()
            text.undoManager?.disableUndoRegistration()
            text.string = session.draft.text
            text.undoManager?.enableUndoRegistration()
            let count = (text.string as NSString).length
            text.setSelectedRange(NSRange(location: min(selection.location, count), length: min(selection.length, max(0, count - min(selection.location, count)))))
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var session: PromptEditorSession
        init(session: PromptEditorSession) { self.session = session }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            session.edit(view.string)
        }
    }
}

final class PromptNativeTextView: NSTextView {
    var promptUndoManager = UndoManager()
    override var undoManager: UndoManager? { promptUndoManager }
    @objc func undo(_ sender: Any?) { promptUndoManager.undo() }
    @objc func redo(_ sender: Any?) { promptUndoManager.redo() }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return promptUndoManager.canUndo }
        if item.action == #selector(redo(_:)) { return promptUndoManager.canRedo }
        return super.validateUserInterfaceItem(item)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.charactersIgnoringModifiers == "z", modifiers == .command || modifiers == [.command, .shift] {
            if modifiers.contains(.shift) { redo(nil) } else { undo(nil) }
            return true
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "f" {
            let item = NSMenuItem()
            item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            performFindPanelAction(item)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
