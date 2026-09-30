import AppKit
import Foundation
import Testing
@testable import dBrief

@Suite("AudioPlayer timer", .serialized) @MainActor
struct AudioPlayerTimerTests {
    /// While a menu tracks, the main run loop runs in `.eventTracking` mode only.
    /// (AVAudioPlayer can't play in the test process, so this drives the real
    /// scheduling code with a counting tick instead of real audio.)
    @Test func ticksKeepArrivingWhileAMenuIsTracking() {
        // In the app NSApplication exists and registers .eventTracking as a common mode.
        _ = NSApplication.shared
        var ticks = 0
        let timer = AudioPlayer.scheduleTickTimer(interval: 0.05) { ticks += 1 }
        defer { timer.invalidate() }
        // Generous deadline: a loaded machine (full parallel suite) delays ticks, but
        // default-mode scheduling delivers none at all in .eventTracking.
        let deadline = Date().addingTimeInterval(3)
        while ticks < 3, Date() < deadline {
            _ = RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.1))
        }
        #expect(ticks >= 3)
    }
}
