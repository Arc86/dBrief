import AppKit

/// Native toolbar items inherit the current macOS toolbar material and grouping.
@MainActor
final class PromptEditorToolbar: NSObject, NSToolbarDelegate {
    let session: PromptEditorSession
    private let improveID = NSToolbarItem.Identifier("prompt.improve")
    private let previewID = NSToolbarItem.Identifier("prompt.preview")
    private let moreID = NSToolbarItem.Identifier("prompt.more")
    private weak var toolbar: NSToolbar?

    init(session: PromptEditorSession) { self.session = session }

    func install(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "dBrief.PromptEditor.Toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.subtitle = session.draft.baseline.scopeName
        window.toolbar = toolbar
        self.toolbar = toolbar
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, improveID, previewID, moreID]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == moreID {
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Prompt options"
            item.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: item.label)
            let menu = NSMenu()
            let restore = NSMenuItem(title: session.identity.scope == .appDefaults ? "Restore Default" : "Use App Default", action: #selector(restoreDefault), keyEquivalent: "")
            restore.target = self
            menu.addItem(restore)
            let undo = NSMenuItem(title: "Undo AI Edit", action: #selector(undoAI), keyEquivalent: "")
            undo.target = self
            menu.addItem(undo)
            item.menu = menu
            return item
        }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = id == improveID ? "Improve with AI" : "Try Prompt"
        item.toolTip = item.label
        item.image = NSImage(systemSymbolName: id == improveID ? "sparkles" : "play.rectangle", accessibilityDescription: item.label)
        item.target = self
        item.action = id == improveID ? #selector(toggleImprove) : #selector(togglePreview)
        item.isBordered = true
        return item
    }
    @objc private func toggleImprove() { session.panel = session.panel == .improve ? .none : .improve }
    @objc private func togglePreview() { session.panel = session.panel == .preview ? .none : .preview }
    @objc private func restoreDefault() { session.restoreDefault() }
    @objc private func undoAI() { session.undoAIEdit() }
}

extension PromptEditorToolbar: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(undoAI) || session.canUndoAI
    }
}
