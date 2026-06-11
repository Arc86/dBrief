import AppKit
import SwiftUI

/// Presents the floating "Update available" notification in a borderless,
/// non-activating panel at the top-right of the main screen — mirroring
/// `CallDetectedOverlayController`. Driven directly by `AppContext` after the
/// silent launch update check; auto-dismisses after a short delay if untouched.
@MainActor
final class UpdateAvailableOverlayController {
    static let shared = UpdateAvailableOverlayController()

    private weak var updateService: UpdateService?

    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    private init() {}

    func configure(updateService: UpdateService) {
        self.updateService = updateService
    }

    func show() {
        guard panel == nil else { return }
        guard let updateService else { return }

        let hosting = NSHostingController(
            rootView: UpdateAvailablePopup(onDismiss: { [weak self] in self?.hide() })
                .environment(updateService)
        )

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 118),
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
            let size = NSSize(width: 360, height: 118)
            let origin = NSPoint(
                x: frame.maxX - size.width - 12,
                y: frame.maxY - size.height - 12
            )
            newPanel.setFrame(NSRect(origin: origin, size: size), display: true)
        }

        newPanel.orderFrontRegardless()

        // Auto-dismiss after 30s so the notification doesn't linger forever.
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    func hide() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
