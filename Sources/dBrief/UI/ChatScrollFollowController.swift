import AppKit
import SwiftUI

/// Only user-initiated scrolling changes follow mode. Content growing during
/// streaming must not be mistaken for the user moving away from the bottom.
@MainActor
final class ChatScrollFollowController: NSObject {
    private weak var scrollView: NSScrollView?
    private var followsBottom = true {
        didSet { if followsBottom != oldValue { onFollowChange?(followsBottom) } }
    }
    private var isUserScrolling = false
    private var wheelMonitor: Any?
    /// Called when the user scrolls away from, or back to, the bottom.
    var onFollowChange: ((Bool) -> Void)?

    var shouldFollow: Bool { followsBottom && !isUserScrolling }

    func resumeFollowing() {
        followsBottom = true
    }

    func attach(to scrollView: NSScrollView) {
        guard self.scrollView !== scrollView else { return }
        detach()
        self.scrollView = scrollView
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(scrollStarted),
                           name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        center.addObserver(self, selector: #selector(scrollMoved),
                           name: NSScrollView.didLiveScrollNotification, object: scrollView)
        center.addObserver(self, selector: #selector(scrollEnded),
                           name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.notchedWheel(event) }
            return event
        }
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
        scrollView = nil
        isUserScrolling = false
    }

    /// Notched mouse wheels post no live-scroll notifications at all, so watch
    /// their events directly. Gesture devices (no empty phases) are handled above.
    private func notchedWheel(_ event: NSEvent) {
        guard event.phase.isEmpty, event.momentumPhase.isEmpty,
              let scrollView, event.window === scrollView.window,
              scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil)) else { return }
        wheelScrolled(deltaY: event.scrollingDeltaY)
    }

    /// Runs before AppKit applies the event. Moving toward older messages pauses
    /// immediately, so a streaming token cannot pull the view back first; moving
    /// down resumes only once the scroll has landed at the bottom.
    func wheelScrolled(deltaY: CGFloat) {
        if deltaY > 0 {
            followsBottom = false
        } else if deltaY < 0 {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isAtBottom else { return }
                self.followsBottom = true
            }
        }
    }

    @objc private func scrollStarted(_ notification: Notification) {
        isUserScrolling = true
    }

    @objc private func scrollMoved(_ notification: Notification) {
        // Legacy mouse wheels send didLiveScroll without a start/end pair.
        followsBottom = isAtBottom
    }

    @objc private func scrollEnded(_ notification: Notification) {
        followsBottom = isAtBottom
        isUserScrolling = false
    }

    private var isAtBottom: Bool {
        guard let scrollView, let document = scrollView.documentView else { return true }
        let visible = scrollView.documentVisibleRect
        let remaining = document.isFlipped
            ? document.bounds.maxY - visible.maxY
            : visible.minY - document.bounds.minY
        return remaining <= 4
    }
}

/// Attach inside the chat's scroll content to observe only that scroll view.
struct ChatScrollFollowObserver: NSViewRepresentable {
    let controller: ChatScrollFollowController

    func makeCoordinator() -> ChatScrollFollowController { controller }

    func makeNSView(context: Context) -> NSView {
        let view = AttachingView(controller: controller)
        attach(from: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        attach(from: view)
    }

    static func dismantleNSView(_ view: NSView, coordinator: ChatScrollFollowController) {
        coordinator.detach()
    }

    private func attach(from view: NSView) {
        // SwiftUI attaches the background after make/updateNSView returns.
        DispatchQueue.main.async { [weak view] in
            guard let scrollView = view?.enclosingScrollView else { return }
            controller.attach(to: scrollView)
        }
    }

    /// The deferred lookup above can run before SwiftUI has placed the view in
    /// its scroll view, and nothing retries it; the chat then never learns the
    /// user scrolled. Joining a window guarantees the hierarchy is in place.
    final class AttachingView: NSView {
        private let controller: ChatScrollFollowController

        init(controller: ChatScrollFollowController) {
            self.controller = controller
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let scrollView = enclosingScrollView else { return }
            controller.attach(to: scrollView)
        }
    }
}
