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

    @Test func autoDismissCallPromptDefaultsToNever() {
        UserDefaults.standard.removeObject(forKey: "autoDismissCallPromptSeconds")
        let settings = AppSettings()
        #expect(settings.autoDismissCallPromptSeconds == 0)
    }

    @Test func autoDismissCallPromptPersists() {
        UserDefaults.standard.removeObject(forKey: "autoDismissCallPromptSeconds")
        let settings = AppSettings()
        settings.autoDismissCallPromptSeconds = 15
        #expect(UserDefaults.standard.integer(forKey: "autoDismissCallPromptSeconds") == 15)
        let reloaded = AppSettings()
        #expect(reloaded.autoDismissCallPromptSeconds == 15)
        UserDefaults.standard.removeObject(forKey: "autoDismissCallPromptSeconds")
    }

    @Test func calendarMatchWindowDefaultsToFifteenMinutes() {
        UserDefaults.standard.removeObject(forKey: "calendarMatchWindowMinutes")
        defer { UserDefaults.standard.removeObject(forKey: "calendarMatchWindowMinutes") }

        let settings = AppSettings()

        #expect(settings.calendarMatchWindowMinutes == 15)
    }

    @Test func calendarPreferencesPersist() {
        UserDefaults.standard.removeObject(forKey: "calendarMatchWindowMinutes")
        UserDefaults.standard.removeObject(forKey: "showAllMeetingsFromRecordingDay")
        defer {
            UserDefaults.standard.removeObject(forKey: "calendarMatchWindowMinutes")
            UserDefaults.standard.removeObject(forKey: "showAllMeetingsFromRecordingDay")
        }

        let settings = AppSettings()
        settings.calendarMatchWindowMinutes = 30
        settings.showAllMeetingsFromRecordingDay = true

        let reloaded = AppSettings()
        #expect(reloaded.calendarMatchWindowMinutes == 30)
        #expect(reloaded.showAllMeetingsFromRecordingDay == true)
    }

    @Test func calendarMatchWindowNormalizesUnsupportedStoredValues() {
        UserDefaults.standard.set(17, forKey: "calendarMatchWindowMinutes")
        defer { UserDefaults.standard.removeObject(forKey: "calendarMatchWindowMinutes") }

        let settings = AppSettings()

        #expect(settings.calendarMatchWindowMinutes == 15)
        #expect(UserDefaults.standard.integer(forKey: "calendarMatchWindowMinutes") == 15)
    }

    @Test func iCalCalendarFilterDefaultsToAllCalendars() {
        UserDefaults.standard.removeObject(forKey: "selectedICalCalendarIDs")
        defer { UserDefaults.standard.removeObject(forKey: "selectedICalCalendarIDs") }

        let settings = AppSettings()

        #expect(settings.selectedICalCalendarIDs == nil)
    }

    @Test func iCalCalendarFilterPersistsMultipleCalendars() {
        UserDefaults.standard.removeObject(forKey: "selectedICalCalendarIDs")
        defer { UserDefaults.standard.removeObject(forKey: "selectedICalCalendarIDs") }

        let settings = AppSettings()
        settings.selectedICalCalendarIDs = ["business", "shared-team"]

        let reloaded = AppSettings()
        #expect(reloaded.selectedICalCalendarIDs == ["business", "shared-team"])
    }

    @Test func emptyICalCalendarFilterRemainsDistinctFromAllCalendars() {
        UserDefaults.standard.removeObject(forKey: "selectedICalCalendarIDs")
        defer { UserDefaults.standard.removeObject(forKey: "selectedICalCalendarIDs") }

        let settings = AppSettings()
        settings.selectedICalCalendarIDs = []

        #expect(UserDefaults.standard.object(forKey: "selectedICalCalendarIDs") != nil)
        let reloaded = AppSettings()
        #expect(reloaded.selectedICalCalendarIDs == [])
    }

    @Test func retentionRunStatusPersists() {
        let dateKey = "lastRetentionCleanupDate"
        let summaryKey = "lastRetentionCleanupSummary"
        UserDefaults.standard.removeObject(forKey: dateKey)
        UserDefaults.standard.removeObject(forKey: summaryKey)
        defer {
            UserDefaults.standard.removeObject(forKey: dateKey)
            UserDefaults.standard.removeObject(forKey: summaryKey)
        }

        let expectedDate = Date(timeIntervalSince1970: 1_750_000_000)
        let settings = AppSettings()
        settings.lastRetentionCleanupDate = expectedDate
        settings.lastRetentionCleanupSummary = "Deleted 2 files (4 KB)."

        let reloaded = AppSettings()
        #expect(reloaded.lastRetentionCleanupDate == expectedDate)
        #expect(reloaded.lastRetentionCleanupSummary == "Deleted 2 files (4 KB).")
    }
}
