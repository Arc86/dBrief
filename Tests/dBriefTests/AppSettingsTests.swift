import Foundation
import Testing
@testable import dBrief

@MainActor
struct AppSettingsTests {
    @Test func aiProcessingEnabledDefaultsToTrue() {
        // Clear any persisted value so we test the real default
        UserDefaults.standard.removeObject(forKey: "aiProcessingEnabled")
        let settings = AppSettings()
        #expect(settings.aiProcessingEnabled == true)
    }

    @Test func acousticEchoCancellationDefaultsToTrue() {
        UserDefaults.standard.removeObject(forKey: "acousticEchoCancellation")
        let settings = AppSettings()
        #expect(settings.acousticEchoCancellation == true)
    }

    @Test func acousticEchoCancellationPersists() {
        UserDefaults.standard.removeObject(forKey: "acousticEchoCancellation")
        let settings = AppSettings()
        settings.acousticEchoCancellation = false
        #expect(UserDefaults.standard.bool(forKey: "acousticEchoCancellation") == false)
        let reloaded = AppSettings()
        #expect(reloaded.acousticEchoCancellation == false)
        UserDefaults.standard.removeObject(forKey: "acousticEchoCancellation")
    }
}
