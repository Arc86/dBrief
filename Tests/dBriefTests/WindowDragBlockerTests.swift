import AppKit
import SwiftUI
import Testing
@testable import dBrief

@Suite @MainActor struct WindowDragBlockerTests {
    @Test func blockerViewDoesNotMoveTheWindow() {
        let view = WindowDragBlocker.BlockerView()
        #expect(!view.mouseDownCanMoveWindow)
    }

    @Test func backgroundBlockerSitsBehindTheHandleAndFillsIt() {
        // The blocker must be a hit-testable AppKit view under the handle's area;
        // a drag that lands on it can't be claimed by the window's background drag.
        let host = NSHostingView(rootView:
            Color.clear.frame(width: 10, height: 40).preventsWindowDrag())
        host.frame = NSRect(x: 0, y: 0, width: 10, height: 40)
        host.layoutSubtreeIfNeeded()
        var found = false
        func walk(_ v: NSView) {
            if v is WindowDragBlocker.BlockerView { found = true }
            v.subviews.forEach(walk)
        }
        walk(host)
        #expect(found)
    }
}
