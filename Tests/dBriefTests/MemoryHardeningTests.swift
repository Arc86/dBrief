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
}
