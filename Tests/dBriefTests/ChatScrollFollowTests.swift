import AppKit
import Testing
@testable import dBrief

@Suite("Chat scroll following", .serialized)
@MainActor
struct ChatScrollFollowTests {
    private final class DocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    private func fixture() -> (NSScrollView, ChatScrollFollowController) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scroll.documentView = DocumentView(frame: NSRect(x: 0, y: 0, width: 400, height: 1200))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 900))
        let controller = ChatScrollFollowController()
        controller.attach(to: scroll)
        return (scroll, controller)
    }

    @Test("A gesture takes priority immediately, even before the first movement")
    func gestureTakesPriority() {
        let (scroll, controller) = fixture()
        #expect(controller.shouldFollow)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        #expect(!controller.shouldFollow)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        #expect(!controller.shouldFollow)
        scroll.documentView?.setFrameSize(NSSize(width: 400, height: 1500))
        #expect(!controller.shouldFollow)
    }

    @Test("Returning to the bottom resumes following only after the gesture ends")
    func returnToBottom() {
        let (scroll, controller) = fixture()
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        #expect(!controller.shouldFollow)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        #expect(controller.shouldFollow)
    }

    @Test("Legacy mouse wheels pause and resume without gesture start/end events")
    func legacyMouse() {
        let (scroll, controller) = fixture()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        #expect(!controller.shouldFollow)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 900))
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        #expect(controller.shouldFollow)
    }

    @Test("Content growth alone does not disable following")
    func contentGrowth() {
        let (scroll, controller) = fixture()
        scroll.documentView?.setFrameSize(NSSize(width: 400, height: 1500))
        #expect(controller.shouldFollow)
    }

    @Test("Sending a new prompt resumes a paused conversation")
    func newPrompt() {
        let (scroll, controller) = fixture()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        #expect(!controller.shouldFollow)
        controller.resumeFollowing()
        #expect(controller.shouldFollow)
    }

    @Test("Scrolling another pane does not affect the chat")
    func unrelatedPane() {
        let (scroll, controller) = fixture()
        let other = NSScrollView()
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: other)
        #expect(controller.shouldFollow)
        controller.detach()
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        #expect(controller.shouldFollow)
    }
}
