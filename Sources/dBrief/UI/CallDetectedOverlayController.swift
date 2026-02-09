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

        if panel == nil {
            let hosting = NSHostingController(
                rootView: CallDetectedPopup()
                    .environment(appState)
                    .environment(appSettings)
                    .environment(recordingManager)
                    .frame(width: 520, height: 220)
            )

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 220),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: true
            )
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.contentViewController = hosting
            self.panel = panel
        }

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let size = NSSize(width: 520, height: 220)
            let origin = NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.midY - size.height / 2
            )
            panel?.setFrame(NSRect(origin: origin, size: size), display: true)
        }

        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}
