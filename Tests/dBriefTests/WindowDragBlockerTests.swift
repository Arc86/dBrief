import AppKit
import SwiftUI
import Testing
@testable import dBrief

@Suite(.serialized) @MainActor struct WindowDragBlockerTests {
    private func window(movable: Bool) -> (NSWindow, WindowDragBlocker.BlockerView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = movable
        let blocker = WindowDragBlocker.BlockerView()
        window.contentView?.addSubview(blocker)
        return (window, blocker)
    }

    @Test func suppressingDisablesBackgroundDraggingAndReleasingRestoresIt() {
        let (window, blocker) = window(movable: true)
        defer { window.close() }
        blocker.apply(suppressed: true)
        #expect(!window.isMovableByWindowBackground)
        blocker.apply(suppressed: false)
        #expect(window.isMovableByWindowBackground)
    }

    @Test func aWindowThatWasNotMovableStaysThatWay() {
        let (window, blocker) = window(movable: false)
        defer { window.close() }
        blocker.apply(suppressed: true)
        blocker.apply(suppressed: false)
        #expect(!window.isMovableByWindowBackground)
    }

    @Test func repeatedSuppressionRestoresTheOriginalValue() {
        let (window, blocker) = window(movable: true)
        defer { window.close() }
        blocker.apply(suppressed: true)
        blocker.apply(suppressed: true)
        blocker.apply(suppressed: false)
        #expect(window.isMovableByWindowBackground)
    }

    @Test func removingTheBlockerWhileSuppressedRestoresTheWindow() {
        let (window, blocker) = window(movable: true)
        defer { window.close() }
        blocker.apply(suppressed: true)
        blocker.removeFromSuperview()
        blocker.releaseSuppression(on: window)
        #expect(window.isMovableByWindowBackground)
    }

    @Test func windowConfigurationSetsMovableOnlyOnce() {
        // A later SwiftUI update must not re-enable dragging while a handle
        // has suppressed it.
        let (window, blocker) = window(movable: false)
        defer { window.close() }
        let config = ViewerWindowConfiguration.WindowView(color: .black)
        window.contentView?.addSubview(config)   // first attach enables dragging once
        #expect(window.isMovableByWindowBackground)
        blocker.apply(suppressed: true)
        config.configureWindow()                 // a later SwiftUI update
        #expect(!window.isMovableByWindowBackground)
    }
}
