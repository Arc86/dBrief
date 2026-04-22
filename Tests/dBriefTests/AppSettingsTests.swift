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
}
