import AppKit
import SwiftUI

/// Only user-initiated scrolling changes follow mode. Content growing during
/// streaming must not be mistaken for the user moving away from the bottom.
@MainActor
final class ChatScrollFollowController: NSObject {
    private weak var scrollView: NSScrollView?
    private var followsBottom = true
    private var isUserScrolling = false

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
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        scrollView = nil
        isUserScrolling = false
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
        let view = NSView()
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
}
