import AppKit
import SwiftUI

/// Owns a normal app window independently of the transient menu-bar window.
@MainActor
final class RecordingActionWindowPresenter: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    func show(title: String, contentSize: NSSize, content: AnyView,
              onClose: (() -> Void)? = nil) {
        close()

        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.setContentSize(contentSize)
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        self.onClose = onClose
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let window else { return }
        window.delegate = nil
        window.close()
        self.window = nil
        notifyClosed()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        notifyClosed()
    }

    private func notifyClosed() {
        let callback = onClose
        onClose = nil
        callback?()
    }
}

/// Presents recording actions launched from the menu bar in an owned window so
/// focus changes from pickers and text fields cannot dismiss their transient host.
@MainActor
final class RecordingActionWindowController {
    static let shared = RecordingActionWindowController()

    private weak var appState: AppState?
    private weak var appSettings: AppSettings?
    private weak var recordingManager: RecordingManager?
    private let presenter = RecordingActionWindowPresenter()

    private init() {}

    func configure(appState: AppState, appSettings: AppSettings,
                   recordingManager: RecordingManager) {
        self.appState = appState
        self.appSettings = appSettings
        self.recordingManager = recordingManager
    }

    func showReprocessing(recording: Recording, operation: ReprocessingOperation) {
        guard let appState, let appSettings, let recordingManager else { return }
        presenter.close()
        prepareForPresentation(appSettings: appSettings)
        let root = ReprocessingSheet(
            recording: recording,
            operation: operation,
            dismissAction: { [weak self] in self?.close() }
        )
        .environment(appState)
        .environment(appSettings)
        .environment(recordingManager)
        .environment(\.calmAppearance, appSettings.reduceNeon)
        presenter.show(
            title: operation.title,
            contentSize: NSSize(width: 530, height: 580),
            content: AnyView(root),
            onClose: { [weak self] in self?.restoreActivationPolicy() }
        )
    }

    func showCalendarLink(recording: Recording, hasTranscript: Bool) {
        guard let appState, let appSettings, let recordingManager else { return }
        presenter.close()
        prepareForPresentation(appSettings: appSettings)
        let root = CalendarLinkSheet(
            recording: recording,
            hasTranscript: hasTranscript,
            dismissAction: { [weak self] in self?.close() }
        )
        .environment(appState)
        .environment(appSettings)
        .environment(recordingManager)
        .environment(\.calmAppearance, appSettings.reduceNeon)
        presenter.show(
            title: "Link Calendar Meeting",
            contentSize: NSSize(width: 540, height: 300),
            content: AnyView(root),
            onClose: { [weak self] in self?.restoreActivationPolicy() }
        )
    }

    func close() {
        presenter.close()
    }

    private func prepareForPresentation(appSettings: AppSettings) {
        for window in NSApp.windows where window.level == .statusBar {
            window.orderOut(nil)
        }
        if !appSettings.showDockIcon {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func restoreActivationPolicy() {
        guard let appSettings, !appSettings.showDockIcon else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
