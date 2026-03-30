import Testing
@testable import dBrief

@MainActor
struct MemoryHardeningTests {

    @Test func appStateMemoryLevelDefaultsToNormal() {
        let state = AppState()
        #expect(state.memoryPressureLevel == .normal)
    }

    @Test func appStatePreflightWarningDefaultsToNil() {
        let state = AppState()
        #expect(state.preflightWarning == nil)
    }

    @Test func appStateMemoryLevelCanBeUpdated() {
        let state = AppState()
        state.memoryPressureLevel = .warning
        #expect(state.memoryPressureLevel == .warning)
    }

    @Test func pressureMonitorHandlerReceivesLevel() async {
        let monitor = MemoryPressureMonitor()
        var received: MemoryPressureLevel?
        monitor.registerPressureHandler { level in
            received = level
        }
        // Directly invoke internal trigger to avoid needing a real dispatch source
        await monitor.testTrigger(.warning)
        #expect(received == .warning)
    }
}
