import AppKit
import SwiftUI

/// Playback follows transcript turns until the user scrolls. Any native wheel
/// or trackpad movement pauses follow; only an explicit resume starts it again.
@MainActor
final class TranscriptScrollFollowController: NSObject {
    private weak var scrollView: NSScrollView?
    private var followsPlayback = true
    private var isUserScrolling = false

    var shouldFollow: Bool { followsPlayback && !isUserScrolling }

    func resumeFollowing() {
        guard !isUserScrolling else { return }
        followsPlayback = true
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
        guard isForAttachedScrollView(notification) else { return }
        followsPlayback = false
        isUserScrolling = true
    }

    @objc private func scrollMoved(_ notification: Notification) {
        // Legacy mouse wheels can send didLiveScroll without a start/end pair.
        guard isForAttachedScrollView(notification) else { return }
        followsPlayback = false
    }

    @objc private func scrollEnded(_ notification: Notification) {
        guard isForAttachedScrollView(notification) else { return }
        followsPlayback = false
        isUserScrolling = false
    }

    private func isForAttachedScrollView(_ notification: Notification) -> Bool {
        guard let notifiedScrollView = notification.object as? NSScrollView else { return false }
        return notifiedScrollView === scrollView
    }
}

/// Locates the recycling AppKit List scroll view for the transcript. The probe
/// can be outside the native NSScrollView, so discovery checks the enclosing
/// view first and then searches the closest ancestor subtree for an NSTableView
/// document view. Ordinary SwiftUI ScrollViews are deliberately excluded.
@MainActor
enum TranscriptListScrollDiscovery {
    static func find(from probe: NSView) -> NSScrollView? {
        if let enclosing = probe.enclosingScrollView, isTranscriptList(enclosing) {
            return enclosing
        }

        var ancestor: NSView? = probe
        while let subtree = ancestor {
            let result = closestTranscriptList(in: subtree, to: probe)
            if result.ambiguous { return nil }
            if let scrollView = result.scrollView { return scrollView }
            ancestor = subtree.superview
        }
        return nil
    }

    private static func isTranscriptList(_ scrollView: NSScrollView) -> Bool {
        scrollView.documentView is NSTableView
    }

    private static func closestTranscriptList(in subtree: NSView, to probe: NSView)
        -> (scrollView: NSScrollView?, ambiguous: Bool) {
        var closest: NSScrollView?
        var closestDistance = Int.max
        var ambiguous = false

        func visit(_ view: NSView) {
            if let scrollView = view as? NSScrollView, isTranscriptList(scrollView),
               let distance = treeDistance(from: probe, to: scrollView) {
                if distance < closestDistance {
                    closest = scrollView
                    closestDistance = distance
                    ambiguous = false
                } else if distance == closestDistance, closest !== scrollView {
                    ambiguous = true
                }
            }
            for child in view.subviews { visit(child) }
        }

        visit(subtree)
        return (closest, ambiguous)
    }

    private static func treeDistance(from first: NSView, to second: NSView) -> Int? {
        var firstAncestors: [NSView] = []
        var node: NSView? = first
        while let current = node {
            firstAncestors.append(current)
            node = current.superview
        }

        var secondAncestors: [NSView] = []
        node = second
        while let current = node {
            secondAncestors.append(current)
            node = current.superview
        }

        for (firstDistance, ancestor) in firstAncestors.enumerated() {
            if let secondDistance = secondAncestors.firstIndex(where: { $0 === ancestor }) {
                return firstDistance + secondDistance
            }
        }
        return nil
    }
}

/// A lightweight probe placed in the transcript List's background. Discovery
/// runs after AppKit has inserted the representable into its native hierarchy.
struct TranscriptScrollFollowObserver: NSViewRepresentable {
    let controller: TranscriptScrollFollowController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        let coordinator = context.coordinator
        view.onHierarchyChange = { [weak coordinator, weak view] in
            guard let view else { return }
            coordinator?.scheduleAttach(from: view)
        }
        context.coordinator.scheduleAttach(from: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.scheduleAttach(from: view)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private let controller: TranscriptScrollFollowController
        private var attachRequest = 0
        private weak var attachedScrollView: NSScrollView?
        private weak var attachedParent: NSView?

        init(controller: TranscriptScrollFollowController) {
            self.controller = controller
        }

        func scheduleAttach(from view: NSView) {
            // Playback updates the parent at 10 Hz. Discover once per mounted
            // List instead of walking its native hierarchy on each update.
            if let attachedScrollView, attachedScrollView.window != nil,
               attachedScrollView.window === view.window, attachedParent === view.superview { return }
            attachRequest += 1
            let request = attachRequest
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.attachRequest == request,
                      let scrollView = TranscriptListScrollDiscovery.find(from: view) else { return }
                self.controller.attach(to: scrollView)
                self.attachedScrollView = scrollView
                self.attachedParent = view.superview
            }
        }

        func detach() {
            attachRequest += 1
            controller.detach()
            attachedScrollView = nil
            attachedParent = nil
        }
    }

    @MainActor
    private final class ProbeView: NSView {
        var onHierarchyChange: (() -> Void)?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            onHierarchyChange?()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onHierarchyChange?()
        }
    }
}
