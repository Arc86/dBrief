import Foundation
import Testing
@testable import dBrief

struct CLIReasoningEffortTests {
    @Test("Every supported effort value survives analysis configuration encoding", arguments: ["cliDefault", "low", "medium", "high", "xhigh", "max"])
    func supportedEffortRoundtrip(raw: String) throws {
        let data = Data("{\"command\":\"claude -p\",\"timeoutSeconds\":180,\"effort\":\"\(raw)\",\"effortProvider\":\"claude\"}".utf8)
        let config = try JSONDecoder().decode(LocalCLIConfig.self, from: data)
        let encoded = try JSONEncoder().encode(config)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["effort"] as? String == raw)
        #expect(object["effortProvider"] as? String == "claude")
    }

    @Test("Calendar effort does not change mailbox/calendar/time-zone cache identity")
    func calendarEffortDoesNotChangeScope() throws {
        let base = CalendarCLIConfig.default.updating(mailboxEmail: "ada@example.com", calendarName: "Team")
        let encoded = try JSONEncoder().encode(base)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["effort"] = "high"
        let changed = try JSONDecoder().decode(CalendarCLIConfig.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(CalendarCLIScope(config: base) == CalendarCLIScope(config: changed))
        let changedJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(changed)) as? [String: Any])
        #expect(changedJSON["effort"] as? String == "high")
    }
}

extension CLIReasoningEffortTests {
    @Test("Legacy calendar configuration defaults to Low effort")
    func missingCalendarEffortDefaultsLow() throws {
        let data = Data(#"{"mailboxEmail":"ada@example.com","timeoutSeconds":90}"#.utf8)
        let config = try JSONDecoder().decode(CalendarCLIConfig.self, from: data)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        #expect(object["effort"] as? String == "low")
        #expect(config.mailboxEmail == "ada@example.com")
    }

    @Test("Unknown calendar effort preserves mailbox and uses CLI default")
    func unknownCalendarEffortPreservesMailbox() throws {
        let data = Data(#"{"mailboxEmail":"ada@example.com","timeoutSeconds":90,"effort":"future"}"#.utf8)
        let config = try JSONDecoder().decode(CalendarCLIConfig.self, from: data)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        #expect(object["effort"] as? String == "cliDefault")
        #expect(config.mailboxEmail == "ada@example.com")
    }
}
