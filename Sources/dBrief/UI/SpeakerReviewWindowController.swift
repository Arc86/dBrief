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

    /// Fixed content width — must match `SpeakerReviewView`'s `.frame(width:)`.
    private static let windowWidth: CGFloat = 392

    /// Explicit window height so we never depend on `preferredContentSize`
    /// self-sizing (which crashes — see `show()`). Tight for a few speakers,
    /// capped so a long list scrolls inside the card area.
    private static func windowHeight(forSpeakerCount count: Int) -> CGFloat {
        let chrome: CGFloat = 124       // header + footer + dividers
        let cardsPadding: CGFloat = 24  // cards area vertical padding
        let perCard: CGFloat = 80       // one card + inter-card spacing
        let n = max(1, count)
        return min(max(chrome + cardsPadding + CGFloat(n) * perCard, 220), 600)
    }

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
        // Size the window explicitly instead of letting AppKit resolve the hosting
        // controller's `preferredContentSize` during the display cycle. That
        // self-sizing path (safe-area ↔ content-size feedback under a full-size-
        // content transparent titlebar) can reentrantly re-request a constraints
        // pass mid-cycle and crash with an uncaught AppKit exception on macOS 26.
        // The content is a fixed-width column with an internally scrollable card
        // list, so a computed height is safe. Mirrors CallDetectedOverlayController.
        hosting.sizingOptions = []

        let speakerCount = appState.pendingSpeakerReview?.items.count ?? 1
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth,
                                height: Self.windowHeight(forSpeakerCount: speakerCount)),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        win.contentViewController = hosting
        win.title = "Confirm Speakers"
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
