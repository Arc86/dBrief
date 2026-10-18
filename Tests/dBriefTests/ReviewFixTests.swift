import AppKit
import SwiftUI
import Testing
@testable import dBrief

@Suite("Final review fixes", .serialized) @MainActor
struct ReviewFixTests {
    // Important #1: hiding the transcript tab must not write `isEnabled` into the
    // environment, which bypasses Equatable rows and re-renders every one on each tab
    // switch. Other hidden tabs are disabled so Tab can't reach their buttons.
    private final class Probe { var values: [Bool] = [] }
    private struct EnabledProbe: View {
        let probe: Probe
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            probe.values.append(isEnabled)
            return Color.clear
        }
    }

    @Test func hiddenTranscriptTabKeepsTheEnvironmentUnchanged() async throws {
        let values = try await enabledValues(ViewerMountedTab(isCurrent: false, disablesWhenHidden: false))
        #expect(!values.isEmpty)
        #expect(values.allSatisfy { $0 })
    }

    @Test func otherHiddenTabsAreDisabled() async throws {
        let values = try await enabledValues(ViewerMountedTab(isCurrent: false))
        #expect(!values.isEmpty)
        #expect(values.allSatisfy { !$0 })
        #expect(try await enabledValues(ViewerMountedTab(isCurrent: true)).allSatisfy { $0 })
    }

    private func enabledValues(_ tab: ViewerMountedTab) async throws -> [Bool] {
        _ = NSApplication.shared
        let probe = Probe()
        let host = NSHostingView(rootView: EnabledProbe(probe: probe).modifier(tab).frame(width: 50, height: 50))
        host.frame = NSRect(x: 0, y: 0, width: 50, height: 50)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        return probe.values
    }

    // Minor #3 (re-graded): two handles must not leave window dragging stuck off.
    @Test func overlappingSuppressionsRestoreWindowDragging() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.isMovableByWindowBackground = true
        let a = WindowDragBlocker.BlockerView(), b = WindowDragBlocker.BlockerView()
        window.contentView?.addSubview(a)
        window.contentView?.addSubview(b)
        b.apply(suppressed: true)   // pointer on the assistant handle
        a.apply(suppressed: true)   // coalesced update: A enters while B still suppressing
        b.apply(suppressed: false)
        #expect(!window.isMovableByWindowBackground)   // A still hovering
        a.apply(suppressed: false)
        #expect(window.isMovableByWindowBackground)
    }
}
