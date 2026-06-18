import AppKit
import SwiftUI

/// Pops the confirm-first speaker-review window to the front in a menu-bar app.
///
/// A plain SwiftUI `Window` scene can't be opened from app logic when no view is
/// on screen, and — like the Settings window — its text fields wouldn't receive
/// keyboard input while the app is an `.accessory` (LSUIElement). This AppKit
/// controller, mirroring `CallDetectedOverlayController`, reliably foregrounds the
/// window, flips the activation policy so typing works, and reverts on close.
@MainActor
final class SpeakerReviewWindowController: NSObject, NSWindowDelegate {
    static let shared = SpeakerReviewWindowController()

    private weak var appState: AppState?
    private weak var appSettings: AppSettings?
    private weak var recordingManager: RecordingManager?
    private weak var audioPlayer: AudioPlayer?

    private var window: NSWindow?
    /// Set once the user resolves the review, so the close handler doesn't also
    /// fire a (second) cancel.
    private var isCompleting = false

    private override init() {}

    func configure(appState: AppState, appSettings: AppSettings,
                   recordingManager: RecordingManager, audioPlayer: AudioPlayer) {
        self.appState = appState
        self.appSettings = appSettings
        self.recordingManager = recordingManager
        self.audioPlayer = audioPlayer
    }

    /// Show (or re-show) the review window for the current `pendingSpeakerReview`.
    func show() {
        guard let appState, let appSettings, let recordingManager, let audioPlayer,
              appState.pendingSpeakerReview != nil else { return }

        if let window {
            bringToFront(window)
            return
        }
        isCompleting = false

        let root = SpeakerReviewView(
            onConfirm: { [weak self] edits in self?.complete { await recordingManager.finishReview(confirmed: edits) } },
            onCancel: { [weak self] in self?.complete { await recordingManager.cancelReview() } }
        )
        .environment(appState)
        .environment(appSettings)
        .environment(recordingManager)
        .environment(audioPlayer)

        let hosting = NSHostingController(rootView: root)
        // Let the SwiftUI content drive the window size — no fixed height, so no
        // wasted whitespace or premature scrollbar.
        hosting.sizingOptions = [.preferredContentSize]

        let win = NSWindow(contentViewController: hosting)
        win.title = "Confirm Speakers"
        win.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        // Seamless glass: the material background fills the whole window (incl. under
        // the titlebar), matching the rest of the app's translucent windows.
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isOpaque = false
        win.backgroundColor = .clear
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        self.window = win

        if !appSettings.showDockIcon { NSApp.setActivationPolicy(.regular) }
        bringToFront(win)
    }

    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Resolve the review (confirm or cancel): run the resume work, then tear down.
    private func complete(_ work: @escaping () async -> Void) {
        guard !isCompleting else { return }
        isCompleting = true
        Task { await work() }
        teardown()
    }

    private func teardown() {
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
        if let appSettings, !appSettings.showDockIcon {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // The user closed the window with the red button (no Confirm/Cancel pressed):
    // treat as Cancel so the held pipeline resumes and nothing is stranded.
    func windowWillClose(_ notification: Notification) {
        guard !isCompleting else { return }
        isCompleting = true
        if let recordingManager { Task { await recordingManager.cancelReview() } }
        window = nil
        if let appSettings, !appSettings.showDockIcon {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
