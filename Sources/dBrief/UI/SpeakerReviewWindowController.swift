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

    private final class PresentationTarget {
        weak var parent: NSWindow?
        init(parent: NSWindow) { self.parent = parent }
    }

    /// Retain the launch context across asynchronous/queued speaker detection.
    /// Windows are weak so a closed viewer naturally falls back to a standalone window.
    private var presentationTargets: [URL: PresentationTarget] = [:]
    private weak var presentationParent: NSWindow?
    private var parentCloseObserver: NSObjectProtocol?

    func preparePresentation(for audioURL: URL, parent: NSWindow?) {
        let key = audioURL.standardizedFileURL.resolvingSymlinksInPath()
        presentationTargets[key] = parent.map { PresentationTarget(parent: $0) }
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

        let session = appState.pendingSpeakerReview!
        let audioURL = session.recording.finalizedAudioURL ?? session.recording.fileURL
        let target = presentationTargets.removeValue(forKey: audioURL.standardizedFileURL.resolvingSymlinksInPath())
        let parent = session.origin != .pipeline && target?.parent?.isVisible == true ? target?.parent : nil

        let content = SpeakerReviewView(
            onConfirm: { [weak self] id, edits in self?.complete(sessionID: id) { await recordingManager.finishReview(sessionID: id, confirmed: edits) } },
            onCancel: { [weak self] id in self?.complete(sessionID: id) { await recordingManager.cancelReview(sessionID: id) } }
        )
        .environment(appState)
        .environment(appSettings)
        .environment(recordingManager)
        .environment(audioPlayer)

        // A native sheet has no titlebar controls; the standalone window keeps
        // its standard titlebar, as the calendar-link window does.
        let root = parent == nil ? AnyView(content) : AnyView(content.ignoresSafeArea(.container, edges: .top))

        let hosting = NSHostingController(rootView: root)
        // Explicit sizing avoids the reentrant AppKit sizing path on macOS 26.
        hosting.sizingOptions = []

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: SpeakerReviewView.contentSize),
            styleMask: parent == nil ? [.titled, .closable, .miniaturizable] : [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        win.contentViewController = hosting
        win.setContentSize(SpeakerReviewView.contentSize)
        win.title = "Identify Speakers"
        if parent != nil {
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
        }
        win.isReleasedWhenClosed = false
        win.delegate = self
        self.window = win

        if !appSettings.showDockIcon { NSApp.setActivationPolicy(.regular) }
        if let parent {
            presentationParent = parent
            parentCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: parent, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.complete(sessionID: session.id) { await recordingManager.cancelReview(sessionID: session.id) }
                }
            }
            bringToFront(parent)
            // AppKit queues this behind the launch sheet if its dismissal is
            // still in progress when speaker detection finishes.
            parent.beginSheet(win)
        } else {
            win.center()
            bringToFront(win)
        }
    }

    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Resolve the review (confirm or cancel): run the resume work, then tear down.
    private func complete(sessionID: UUID, _ work: @escaping () async -> Void) {
        guard !isCompleting, appState?.pendingSpeakerReview?.id == sessionID else { return }
        isCompleting = true
        Task { await work() }
        teardown()
    }

    private func teardown() {
        if let parentCloseObserver {
            NotificationCenter.default.removeObserver(parentCloseObserver)
            self.parentCloseObserver = nil
        }
        window?.delegate = nil
        if let window, let parent = presentationParent {
            parent.endSheet(window)
        }
        window?.orderOut(nil)
        window = nil
        presentationParent = nil
        if let appSettings, !appSettings.showDockIcon {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Dismiss the window without treating it as Cancel — used when the owning processing
    /// job is cancelled outright, so the review is moot and must not resume anything.
    /// `isCompleting` suppresses the `windowWillClose` → `cancelReview` path; `show()`
    /// resets it for the next review.
    func dismissForCancelledJob() {
        guard window != nil else { return }
        isCompleting = true
        teardown()
    }

    // The user closed the window with the red button (no Confirm/Cancel pressed):
    // treat as Cancel so the held pipeline resumes and nothing is stranded.
    func windowWillClose(_ notification: Notification) {
        guard !isCompleting else { return }
        isCompleting = true
        if let recordingManager, let id = appState?.pendingSpeakerReview?.id {
            Task { await recordingManager.cancelReview(sessionID: id) }
        }
        teardown()
    }
}
