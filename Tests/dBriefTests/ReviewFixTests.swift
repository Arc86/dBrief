import AppKit
import SwiftUI
import Testing
@testable import dBrief

@Suite("Final review fixes", .serialized) @MainActor
struct ReviewFixTests {
    // Important #1: hiding a tab must not write `isEnabled` into the environment,
    // which bypasses Equatable rows and re-renders every one on each tab switch.
    private final class Probe { var values: [Bool] = [] }
    private struct EnabledProbe: View {
        let probe: Probe
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            probe.values.append(isEnabled)
            return Color.clear
        }
    }

    @Test func hiddenTabKeepsTheEnvironmentUnchanged() async throws {
        _ = NSApplication.shared
        let probe = Probe()
        let host = NSHostingView(rootView: EnabledProbe(probe: probe)
            .modifier(ViewerMountedTab(isCurrent: false)).frame(width: 50, height: 50))
        host.frame = NSRect(x: 0, y: 0, width: 50, height: 50)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!probe.values.isEmpty)
        #expect(probe.values.allSatisfy { $0 })
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

    // Minor #2 (re-graded): a replaced file's old waveform must not seed the first frame.
    @Test func seedingValidatesTheFileVersion() {
        let cache = WaveformCache(limit: 4)
        let url = URL(fileURLWithPath: "/tmp/seed.m4a")
        let old = Date(timeIntervalSince1970: 1)
        cache.store([0.5], for: url, modificationDate: old)
        #expect(cache.seed(for: url, modificationDate: old) == [0.5])
        #expect(cache.seed(for: url, modificationDate: Date(timeIntervalSince1970: 2)) == nil)
        #expect(cache.seed(for: url, modificationDate: nil) == nil)
    }
}
