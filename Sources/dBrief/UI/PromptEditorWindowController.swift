import AppKit
import SwiftUI

@MainActor
final class PromptEditorWindowController: NSObject, NSWindowDelegate {
    private struct Entry { let window: NSWindow; let session: PromptEditorSession; let toolbar: PromptEditorToolbar }
    private var entries: [PromptIdentity: Entry] = [:]
    private var asking = Set<PromptIdentity>()
    private weak var context: AppContext?

    init(context: AppContext) { self.context = context }

    func show(_ identity: PromptIdentity) {
        if let entry = entries[identity] { entry.window.makeKeyAndOrderFront(nil); return }
        guard let context else { return }
        do {
            let completion = PromptAIService(aiService: context.recordingManager.aiService,
                                            localCLIService: context.recordingManager.localCLIService,
                                            localPlugin: context.recordingManager.localPlugin)
            let session = try PromptEditorSession(identity: identity,
                store: PromptPreferencesStore(settings: context.appSettings),
                improver: PromptImprovementService(completion: completion))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            let view = PromptEditorView(session: session, close: { [weak self, weak window] in
                guard let window else { return }; self?.requestClose(window)
            }).environment(context)
            let hosting = NSHostingController(rootView: view)
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.contentMinSize = NSSize(width: 680, height: 500)
            window.title = "\(identity.kind.title) Prompt"
            let toolbar = PromptEditorToolbar(session: session)
            toolbar.install(on: window)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("dBrief.PromptEditor")
            entries[identity] = Entry(window: window, session: session, toolbar: toolbar)
            window.makeKeyAndOrderFront(nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Cannot open prompt"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let (identity, entry) = entries.first(where: { $0.value.window === sender }) else { return true }
        if !entry.session.draft.hasChanges { return true }
        guard !asking.contains(identity) else { return false }
        asking.insert(identity)
        Task { [weak self] in
            guard let self else { return }
            if await self.resolveChanges(entry) { sender.close() }
            self.asking.remove(identity)
        }
        return false
    }
    func requestClose(_ window: NSWindow) { window.performClose(nil) }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let (identity, entry) = entries.first(where: { $0.value.window === window }) else { return }
        entry.session.cancelWork()
        entries.removeValue(forKey: identity)
        asking.remove(identity)
    }
    func prepareToQuit() async -> Bool {
        guard asking.isEmpty else { return false }
        for entry in Array(entries.values) where entry.session.draft.hasChanges {
            guard await resolveChanges(entry) else { return false }
        }
        for entry in entries.values { entry.session.cancelWork() }
        return true
    }
    private func resolveChanges(_ entry: Entry) async -> Bool {
        entry.window.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = "Save changes to \(entry.session.identity.kind.title)?"
        alert.informativeText = "Your changes to \(entry.session.draft.baseline.scopeName) have not been saved."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")
        alert.buttons[0].isEnabled = entry.session.draft.canSave
        switch await alert.beginSheetModal(for: entry.window) {
        case .alertFirstButtonReturn:
            do { try entry.session.save(); return true } catch { return false }
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
}
