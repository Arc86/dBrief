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

        panel = makePanel(text: .detected(app: appState.detectedCallApp), content: CallDetectedPopup()
            .environment(appState)
            .environment(appSettings)
            .environment(recordingManager)
            .environment(\.calmAppearance, appSettings.reduceNeon)
            .modifier(AppAppearanceScope(settings: appSettings)))

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

        endedPanel = makePanel(text: .ended(app: appState.callEndedApp), content: CallEndedPopup()
            .environment(appState)
            .environment(appSettings)
            .environment(recordingManager)
            .environment(\.calmAppearance, appSettings.reduceNeon)
            .modifier(AppAppearanceScope(settings: appSettings)))

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

    private func makePanel<Content: View>(text: CallPromptText, content: Content) -> NSPanel {
        let hosting = NSHostingController(rootView: content)
        // Sized once from the content: self-sizing hosting windows re-enter layout on macOS 26.
        hosting.sizingOptions = []
        let size = NSSize(width: CallPromptText.cardWidth, height: hosting.view.fittingSize.height)

        let panel = KeyablePanel(size: size, title: text.title)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentViewController = hosting
        panel.setAccessibilitySubrole(.dialog)

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let origin = NSPoint(x: frame.maxX - size.width - 12, y: frame.maxY - size.height - 12)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }

        panel.orderFrontRegardless()
        // Keyboard and VoiceOver users get the prompt focused, so Return and Esc work
        // and VoiceOver lands on it; everyone else keeps typing in the app in front.
        if KeyablePanel.assistiveFocusPreferred { panel.makeKey() }
        appState?.announcer.announce(text.announcement, priority: .high)
        return panel
    }

    private func makeAutoDismissTask(seconds: Int, dismiss: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        // VoiceOver users may not reach the prompt before it times out.
        guard seconds > 0, !NSWorkspace.shared.isVoiceOverEnabled else { return nil }
        return Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }
}
