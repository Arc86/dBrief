import AppKit
import SwiftUI

/// What the menu bar icon's right-click menu offers, kept free of AppKit so it can be tested.
enum StatusItemMenuEntry: Equatable {
    case startRecording(enabled: Bool)
    case pauseRecording
    case resumeRecording
    case stopRecording
    case openLibrary
    case importFile(enabled: Bool)
    case settings
    case quit
    case separator

    static func entries(isRecording: Bool, isPaused: Bool, isIdle: Bool, canImport: Bool) -> [StatusItemMenuEntry] {
        var capture: [StatusItemMenuEntry]
        if isRecording {
            capture = [.pauseRecording, .stopRecording]
        } else if isPaused {
            capture = [.resumeRecording, .stopRecording]
        } else {
            capture = [.startRecording(enabled: isIdle)]
        }
        return capture + [.separator, .openLibrary, .importFile(enabled: canImport), .separator, .settings, .quit]
    }
}

/// Extras on the menu bar icon that MenuBarExtra has no API for: a right-click
/// (or Control-click) menu, and dropping an audio file on the icon to transcribe it.
@MainActor
final class StatusItemControls {
    static let shared = StatusItemControls()

    private var monitor: Any?
    private var openWindow: OpenWindowAction?
    private weak var dropView: StatusItemDropView?

    /// Called whenever a SwiftUI view with an `openWindow` action appears; installs once.
    func install(openWindow: OpenWindowAction) {
        self.openWindow = openWindow
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
                // Local monitors run on the main thread.
                nonisolated(unsafe) let event = event
                let consumed = MainActor.assumeIsolated { StatusItemControls.shared.handle(event) }
                return consumed ? nil : event
            }
        }
        installDropTarget(attempt: 0)
    }

    /// True when the click opened the context menu and must not reach the icon.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, MenuBarPanel.isStatusItemWindow(window) else { return false }
        let contextClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard contextClick, let view = window.contentView else { return false }
        MenuBarPanel.close()
        NSMenu.popUpContextMenu(makeMenu(), with: event, for: view)
        return true
    }

    // MARK: - Menu

    private func makeMenu() -> NSMenu {
        let context = AppContext.shared
        let state = context.appState
        let manager = context.recordingManager
        let menu = NSMenu()
        menu.autoenablesItems = false
        let entries = StatusItemMenuEntry.entries(
            isRecording: state.isRecording, isPaused: state.isPaused, isIdle: state.isIdle,
            canImport: state.isIdle && !state.showPostRecordingSheet)
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .startRecording(let enabled):
                menu.addItem(ActionMenuItem("Record meeting", enabled: enabled) {
                    state.lastError = nil
                    Task {
                        do { try await manager.startRecording() } catch { state.lastError = error.localizedDescription }
                    }
                })
            case .pauseRecording:
                menu.addItem(ActionMenuItem("Pause recording") { manager.pauseRecording() })
            case .resumeRecording:
                menu.addItem(ActionMenuItem("Resume recording") { try? manager.resumeRecording() })
            case .stopRecording:
                menu.addItem(ActionMenuItem("Stop recording") { Task { await manager.stopRecording() } })
            case .openLibrary:
                menu.addItem(ActionMenuItem("Recording library") { [weak self] in self?.open("transcript") })
            case .importFile(let enabled):
                menu.addItem(ActionMenuItem("Transcribe audio file…", enabled: enabled) { manager.pickFileForTranscription() })
            case .settings:
                menu.addItem(ActionMenuItem("Settings…", key: ",") { [weak self] in self?.open("settings") })
            case .quit:
                menu.addItem(ActionMenuItem("Quit dBrief", key: "q") { NSApplication.shared.terminate(nil) })
            }
        }
        return menu
    }

    private func open(_ id: String) {
        guard let openWindow else { return }
        MenuBarPanel.open(id, with: openWindow)
    }

    // MARK: - Drop target

    /// The status item's window can appear a moment after the label; retry briefly.
    private func installDropTarget(attempt: Int) {
        guard dropView?.window == nil else { return }
        guard let content = NSApp.windows.first(where: MenuBarPanel.isStatusItemWindow)?.contentView else {
            if attempt < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.installDropTarget(attempt: attempt + 1)
                }
            }
            return
        }
        let view = StatusItemDropView(frame: content.bounds)
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        dropView = view
    }
}

/// Transparent overlay on the status item that accepts dropped audio files.
/// It never takes clicks, so the icon still opens the panel as before.
final class StatusItemDropView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func audioURL(from info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.count == 1 ? urls.first.flatMap { RecordingManager.isImportableAudio($0) ? $0 : nil } : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard audioURL(from: sender) != nil, AppContext.shared.appState.isIdle else { return [] }
        MenuBarPanel.statusButton()?.highlight(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MenuBarPanel.statusButton()?.highlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        MenuBarPanel.statusButton()?.highlight(false)
        guard let url = audioURL(from: sender) else { return false }
        let accepted = AppContext.shared.recordingManager.importFile(url)
        if !accepted { NSSound.beep() }
        return accepted
    }
}

private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

/// Hands the scene's `openWindow` action to `StatusItemControls` once the view appears.
struct StatusItemControlsInstaller: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { StatusItemControls.shared.install(openWindow: openWindow) }
    }
}
