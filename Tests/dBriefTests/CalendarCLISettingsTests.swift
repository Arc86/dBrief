import Foundation
import Testing
@testable import dBrief

/// Persistence and normalization of the calendar CLI configuration, and the
/// independence guarantees between calendar CLI settings and the AI/CLI
/// analysis settings.
@MainActor
struct CalendarCLISettingsTests {

    static func roundtrip(_ config: CalendarCLIConfig, key: String = "calendarCLIConfig-test-\(UUID().uuidString)") -> CalendarCLIConfig {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: key)
        }
        defer { defaults.removeObject(forKey: key) }
        return AppSettings.loadCalendarCLIConfig(forKey: key)
    }

    @Test("Malformed saved configuration falls back to defaults")
    func malformedFallsBack() {
        let key = "calendarCLIConfig-test-\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        defaults.set(Data("not json at all".utf8), forKey: key)
        defer { defaults.removeObject(forKey: key) }
        let loaded = AppSettings.loadCalendarCLIConfig(forKey: key)
        #expect(loaded == .default)
        #expect(!loaded.isConfigured)
    }

    @Test("A missing key falls back to defaults")
    func missingKeyFallsBack() {
        #expect(AppSettings.loadCalendarCLIConfig(forKey: "calendarCLIConfig-test-\(UUID().uuidString)") == .default)
    }

    @Test("Timeout clamps to 30-300 seconds")
    func timeoutBounds() {
        var low = CalendarCLIConfig.default.updating(timeoutSeconds: 5)
        #expect(low.timeoutSeconds == 30)
        low = low.updating(timeoutSeconds: 10_000)
        #expect(low.timeoutSeconds == 300)
        #expect(Self.roundtrip(.unnormalized(timeoutSeconds: 10, mailboxEmail: "a@b.co")).timeoutSeconds == 30)
        #expect(Self.roundtrip(.unnormalized(timeoutSeconds: 9_999, mailboxEmail: "a@b.co")).timeoutSeconds == 300)
        #expect(Self.roundtrip(.unnormalized(timeoutSeconds: 120, mailboxEmail: "a@b.co")).timeoutSeconds == 120)
    }

    @Test("Attendee cap clamps to 1-100")
    func capBounds() {
        #expect(Self.roundtrip(.default.updating(maxAttendees: 0)).maxAttendees == 1)
        #expect(Self.roundtrip(.default.updating(maxAttendees: 500)).maxAttendees == 100)
        #expect(Self.roundtrip(.default.updating(maxAttendees: 20)).maxAttendees == 20)
    }

    @Test("Mailbox normalizes to lowercase and trims whitespace")
    func mailboxNormalization() {
        let loaded = Self.roundtrip(.default.updating(mailboxEmail: "  Ada.Lovelace@Example.COM "))
        #expect(loaded.mailboxEmail == "ada.lovelace@example.com")
    }

    @Test("Unsafe model IDs fall back to the Claude default")
    func modelIDSanitization() {
        #expect(Self.roundtrip(.default.updating(modelID: "haiku")).modelID == "haiku")
        #expect(Self.roundtrip(.default.updating(modelID: "claude-sonnet-4.5")).modelID == "claude-sonnet-4.5")
        #expect(Self.roundtrip(.default.updating(modelID: "haiku; rm -rf /")).modelID == nil)
        #expect(Self.roundtrip(.default.updating(modelID: "`reboot`")).modelID == nil)
        #expect(Self.roundtrip(.default.updating(modelID: "x y")).modelID == nil)
    }

    @Test("Policy and command roundtrip through persistence")
    func policyAndCommandRoundtrip() {
        let config = CalendarCLIConfig.default.updating(
            modelID: "sonnet",
            attendeePolicy: .never,
            maxAttendees: 5,
            command: "claude -p --no-session-persistence"
        )
        let loaded = Self.roundtrip(config)
        #expect(loaded.attendeePolicy == .never)
        #expect(loaded.modelID == "sonnet")
        #expect(loaded.maxAttendees == 5)
        #expect(loaded.command == "claude -p --no-session-persistence")
        #expect(loaded.validateCommand())
    }

    @Test("Old calendar source selections decode unchanged")
    func oldSourceSelectionsUnchanged() {
        #expect(CalendarSource(rawValue: "disabled") == .disabled)
        #expect(CalendarSource(rawValue: "iCal") == .iCal)
        #expect(CalendarSource(rawValue: "outlook") == .outlook)
        #expect(CalendarSource(rawValue: "claudeCLI") == .claudeCLI)
        #expect(CalendarSource(rawValue: "nonsense") == nil)
        // The coercion for an unconfigured Outlook never touches other sources.
        #expect(AppSettings.resolveCalendarSource(.outlook, outlookConfigured: false) == .disabled)
        #expect(AppSettings.resolveCalendarSource(.outlook, outlookConfigured: true) == .outlook)
        #expect(AppSettings.resolveCalendarSource(.claudeCLI, outlookConfigured: false) == .claudeCLI)
        #expect(AppSettings.resolveCalendarSource(.iCal, outlookConfigured: false) == .iCal)
        #expect(AppSettings.resolveCalendarSource(.disabled, outlookConfigured: false) == .disabled)
    }

    @Test("Calendar CLI config is stored independently of the AI analysis CLI config")
    func independenceFromAIConfig() {
        let defaults = UserDefaults.standard
        let aiKey = "calendarCLIConfig-test-ai-\(UUID().uuidString)"
        let calendarKey = "calendarCLIConfig-test-cal-\(UUID().uuidString)"

        // Save an AI config, then save a calendar config; the AI blob is untouched.
        let aiConfig = LocalCLIConfig(command: "ollama run llama3", timeoutSeconds: 45)
        if let data = try? JSONEncoder().encode(aiConfig) {
            defaults.set(data, forKey: aiKey)
        }
        let calendarConfig = CalendarCLIConfig.default.updating(timeoutSeconds: 240, mailboxEmail: "ada@example.com")
        if let data = try? JSONEncoder().encode(calendarConfig) {
            defaults.set(data, forKey: calendarKey)
        }
        defer {
            defaults.removeObject(forKey: aiKey)
            defaults.removeObject(forKey: calendarKey)
        }

        let loadedAI = AppSettings.loadLocalCLIConfig(forKey: aiKey)
        #expect(loadedAI.command == "ollama run llama3")
        #expect(loadedAI.timeoutSeconds == 45)
        let loadedCalendar = AppSettings.loadCalendarCLIConfig(forKey: calendarKey)
        #expect(loadedCalendar.mailboxEmail == "ada@example.com")
        #expect(loadedCalendar.timeoutSeconds == 240)
    }

    @Test("Persistence roundtrips freshness settings")
    func freshnessRoundtrip() {
        let config = CalendarCLIConfig.default.updating(
            listFreshnessSeconds: 1800,
            detailFreshnessSeconds: 7200
        )
        let loaded = Self.roundtrip(config)
        #expect(loaded.listFreshnessSeconds == 1800)
        #expect(loaded.detailFreshnessSeconds == 7200)
    }

    @Test("Calendar list freshness supports manual mode and a full day")
    func extendedFreshness() {
        #expect(Self.roundtrip(.default.updating(listFreshnessSeconds: 0)).listFreshnessSeconds == 0)
        #expect(Self.roundtrip(.default.updating(listFreshnessSeconds: 5 * 60)).listFreshnessSeconds == 5 * 60)
        #expect(Self.roundtrip(.default.updating(listFreshnessSeconds: 24 * 60 * 60)).listFreshnessSeconds == 24 * 60 * 60)
        #expect(Self.roundtrip(.default.updating(listFreshnessSeconds: 1)).listFreshnessSeconds == 5 * 60)
        #expect(Self.roundtrip(.default.updating(listFreshnessSeconds: 100_000)).listFreshnessSeconds == 24 * 60 * 60)
    }
}
