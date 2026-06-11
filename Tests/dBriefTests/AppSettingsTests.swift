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

    @Test func chatFallbackEngineDefaultsToOnDeviceEngine() {
        // The Local CLI chat fallback should default to a zero-config on-device
        // engine — never Remote Endpoint (usually unconfigured) or Local CLI itself.
        UserDefaults.standard.removeObject(forKey: "chatFallbackEngine")
        let settings = AppSettings()
        #expect(settings.chatFallbackEngine != .localCLI)
        #expect(settings.chatFallbackEngine != .remoteEndpoint)
        #expect([.appleIntelligence, .qwenLocal].contains(settings.chatFallbackEngine))
    }

    @Test func chatFallbackEngineCoercesAwayFromLocalCLI() {
        let settings = AppSettings()
        settings.chatFallbackEngine = .localCLI
        #expect(settings.chatFallbackEngine != .localCLI)
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

    @Test func autoProcessAfterStopDefaultsToFalse() {
        UserDefaults.standard.removeObject(forKey: "autoProcessAfterStop")
        let settings = AppSettings()
        #expect(settings.autoProcessAfterStop == false)
    }

    @Test func autoProcessAfterStopPersists() {
        UserDefaults.standard.removeObject(forKey: "autoProcessAfterStop")
        let settings = AppSettings()
        settings.autoProcessAfterStop = true
        #expect(UserDefaults.standard.bool(forKey: "autoProcessAfterStop") == true)
        let reloaded = AppSettings()
        #expect(reloaded.autoProcessAfterStop == true)
        UserDefaults.standard.removeObject(forKey: "autoProcessAfterStop")
    }
}
