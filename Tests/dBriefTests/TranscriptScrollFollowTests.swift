import AppKit
import SwiftUI
import Testing
@testable import dBrief

@Suite("Transcript scroll following", .serialized)
@MainActor
struct TranscriptScrollFollowTests {
    private func nativeListScrollView() -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.documentView = NSTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 1200))
        return scrollView
    }

    private func fixture() -> (NSScrollView, TranscriptScrollFollowController) {
        let scrollView = nativeListScrollView()
        let controller = TranscriptScrollFollowController()
        controller.attach(to: scrollView)
        return (scrollView, controller)
    }

    @Test("A gesture pauses immediately and remains paused after it ends")
    func gesturePausesImmediately() {
        let (scrollView, controller) = fixture()
        #expect(controller.shouldFollow)

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        #expect(!controller.shouldFollow)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        #expect(!controller.shouldFollow)

        controller.resumeFollowing()
        #expect(controller.shouldFollow)
    }

    @Test("Legacy mouse-wheel did-only events pause playback-follow")
    func legacyMouseWheelPauses() {
        let (scrollView, controller) = fixture()
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
        #expect(!controller.shouldFollow)
    }

    @Test("Programmatic bounds and document-size changes do not pause playback-follow")
    func programmaticChangesDoNotPause() {
        let (scrollView, controller) = fixture()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 120))
        scrollView.documentView?.setFrameSize(NSSize(width: 400, height: 1600))
        #expect(controller.shouldFollow)
    }

    @Test("Scrolling another pane does not affect transcript follow")
    func unrelatedPaneIsIgnored() {
        let (_, controller) = fixture()
        let otherScrollView = nativeListScrollView()
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: otherScrollView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: otherScrollView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: otherScrollView)
        #expect(controller.shouldFollow)
    }

    @Test("Resume waits until a gesture ends; detach clears it and removes observers")
    func resumeAndDetach() {
        let (scrollView, controller) = fixture()
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        controller.resumeFollowing()
        #expect(!controller.shouldFollow)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        #expect(!controller.shouldFollow)

        controller.resumeFollowing()
        #expect(controller.shouldFollow)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        controller.detach()
        controller.resumeFollowing()
        #expect(controller.shouldFollow)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
        #expect(controller.shouldFollow)
    }

    @Test("Discovery picks the closest native List, not another pane or a regular scroll view")
    func discoversNearestNativeList() {
        let root = NSView()
        let localPane = NSView()
        let probe = NSView()
        let plainScroll = NSScrollView()
        plainScroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 300))
        let transcriptList = nativeListScrollView()
        localPane.addSubview(probe)
        localPane.addSubview(plainScroll)
        localPane.addSubview(transcriptList)
        root.addSubview(localPane)

        let otherPane = NSView()
        otherPane.addSubview(nativeListScrollView())
        root.addSubview(otherPane)

        #expect(TranscriptListScrollDiscovery.find(from: probe) === transcriptList)
    }

    @Test("The background observer attaches to an actual mounted SwiftUI List")
    func attachesToMountedList() async throws {
        let controller = TranscriptScrollFollowController()
        func content(rows: Int) -> some View {
            List(0..<rows, id: \.self) { row in Text("Transcript row \(row)") }
                .background(TranscriptScrollFollowObserver(controller: controller))
        }
        let host = NSHostingView(rootView: content(rows: 100))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(35))
        }
        let scrollView = try #require(TranscriptListScrollDiscovery.find(from: host))
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        #expect(!controller.shouldFollow)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        controller.resumeFollowing()
        #expect(controller.shouldFollow)
        // Ordinary content updates retain the mounted observer attachment.
        host.rootView = content(rows: 150)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(70))
        let updatedScrollView = try #require(TranscriptListScrollDiscovery.find(from: host))
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: updatedScrollView)
        #expect(!controller.shouldFollow)
    }

    @Test("Ambiguous equally near native Lists are not chosen arbitrarily")
    func ambiguousDiscoveryDoesNotGuess() {
        let pane = NSView()
        let probe = NSView()
        let firstList = nativeListScrollView()
        let secondList = nativeListScrollView()
        pane.addSubview(probe)
        pane.addSubview(firstList)
        pane.addSubview(secondList)

        #expect(TranscriptListScrollDiscovery.find(from: probe) == nil)
    }
}
