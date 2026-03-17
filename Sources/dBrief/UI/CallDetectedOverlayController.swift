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
        guard let appState, let appSettings, let recordingManager else { return }

        let hosting = NSHostingController(
            rootView: CallDetectedPopup()
                .environment(appState)
                .environment(appSettings)
                .environment(recordingManager)
        )

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 90),
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
        newPanel.contentViewController = hosting
        self.panel = newPanel

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let size = NSSize(width: 320, height: 90)
            let origin = NSPoint(
                x: frame.maxX - size.width - 12,
                y: frame.maxY - size.height - 12
            )
            newPanel.setFrame(NSRect(origin: origin, size: size), display: true)
        }

        newPanel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
