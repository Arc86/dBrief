import AppKit
import SwiftUI

extension Notification.Name {
    static let callDetectedPopupChanged = Notification.Name("callDetectedPopupChanged")
}

@MainActor
final class CallDetectedOverlayController {
    static let shared = CallDetectedOverlayController()

    private weak var appState: AppState?
    private weak var appSettings: AppSettings?
    private weak var recordingManager: RecordingManager?

    private var panel: NSPanel?
    private var observer: NSObjectProtocol?
    private var autoDismissTask: Task<Void, Never>?

    private init() {}

    func configure(appState: AppState, appSettings: AppSettings, recordingManager: RecordingManager) {
        self.appState = appState
        self.appSettings = appSettings
        self.recordingManager = recordingManager

        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .callDetectedPopupChanged,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                guard let shouldShow = notification.object as? Bool else { return }
                Task { @MainActor in
                    if shouldShow {
                        self.show()
                    } else {
                        self.hide()
                    }
                }
            }
        }
    }

    func show() {
        guard panel == nil else { return }
        guard let appState, let appSettings, let recordingManager else { return }

        let hosting = NSHostingController(
            rootView: CallDetectedPopup()
                .environment(appState)
                .environment(appSettings)
                .environment(recordingManager)
                .environment(\.calmAppearance, appSettings.reduceNeon)
        )

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 132),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.isMovableByWindowBackground = false
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.isReleasedWhenClosed = false
        newPanel.contentViewController = hosting
        self.panel = newPanel

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let size = NSSize(width: 380, height: 132)
            let origin = NSPoint(
                x: frame.maxX - size.width - 12,
                y: frame.maxY - size.height - 12
            )
            newPanel.setFrame(NSRect(origin: origin, size: size), display: true)
        }

        newPanel.orderFrontRegardless()

        // Auto-dismiss after the configured delay (0 = never). Any user interaction
        // sets showCallDetectedPopup = false → hide(), which cancels this task.
        autoDismissTask?.cancel()
        let seconds = appSettings.autoDismissCallPromptSeconds
        if seconds > 0 {
            autoDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.appState?.showCallDetectedPopup = false
            }
        }
    }

    func hide() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
