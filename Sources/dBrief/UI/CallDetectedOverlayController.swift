import AppKit
import SwiftUI

extension Notification.Name {
    static let callDetectedPopupChanged = Notification.Name("callDetectedPopupChanged")
    static let callEndedPopupChanged = Notification.Name("callEndedPopupChanged")
}

@MainActor
final class CallDetectedOverlayController {
    static let shared = CallDetectedOverlayController()

    private weak var appState: AppState?
    private weak var appSettings: AppSettings?
    private weak var recordingManager: RecordingManager?

    // "Call detected — record?" prompt.
    private var panel: NSPanel?
    private var observer: NSObjectProtocol?
    private var autoDismissTask: Task<Void, Never>?

    // "Call ended — stop recording?" prompt.
    private var endedPanel: NSPanel?
    private var endedObserver: NSObjectProtocol?
    private var endedAutoDismissTask: Task<Void, Never>?

    private static let panelSize = NSSize(width: 380, height: 132)

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
                    if shouldShow { self.show() } else { self.hide() }
                }
            }
        }

        if endedObserver == nil {
            endedObserver = NotificationCenter.default.addObserver(
                forName: .callEndedPopupChanged,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                guard let shouldShow = notification.object as? Bool else { return }
                Task { @MainActor in
                    if shouldShow { self.showCallEnded() } else { self.hideCallEnded() }
                }
            }
        }
    }

    // MARK: - Call detected

    func show() {
        guard panel == nil else { return }
        guard let appState, let appSettings, let recordingManager else { return }

        panel = makePanel(content: CallDetectedPopup()
            .environment(appState)
            .environment(appSettings)
            .environment(recordingManager)
            .environment(\.calmAppearance, appSettings.reduceNeon))

        // Auto-dismiss after the configured delay (0 = never). Any user interaction
        // sets showCallDetectedPopup = false → hide(), which cancels this task.
        autoDismissTask = makeAutoDismissTask(seconds: appSettings.autoDismissCallPromptSeconds) { [weak self] in
            self?.appState?.showCallDetectedPopup = false
        }
    }

    func hide() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Call ended

    func showCallEnded() {
        guard endedPanel == nil else { return }
        guard let appState, let appSettings, let recordingManager else { return }

        endedPanel = makePanel(content: CallEndedPopup()
            .environment(appState)
            .environment(appSettings)
            .environment(recordingManager)
            .environment(\.calmAppearance, appSettings.reduceNeon))

        // Auto-dismiss is default-safe here: timing out just keeps recording (sets the flag
        // false → hideCallEnded(), takes no stop action).
        endedAutoDismissTask = makeAutoDismissTask(seconds: appSettings.autoDismissCallPromptSeconds) { [weak self] in
            self?.appState?.showCallEndedPopup = false
        }
    }

    func hideCallEnded() {
        endedAutoDismissTask?.cancel()
        endedAutoDismissTask = nil
        endedPanel?.orderOut(nil)
        endedPanel = nil
    }

    // MARK: - Shared panel machinery

    private func makePanel<Content: View>(content: Content) -> NSPanel {
        let hosting = NSHostingController(rootView: content)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentViewController = hosting

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let origin = NSPoint(
                x: frame.maxX - Self.panelSize.width - 12,
                y: frame.maxY - Self.panelSize.height - 12
            )
            panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: true)
        }

        panel.orderFrontRegardless()
        return panel
    }

    private func makeAutoDismissTask(seconds: Int, dismiss: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        guard seconds > 0 else { return nil }
        return Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }
}
