import Foundation
import CryptoKit
import Testing
@testable import dBrief

struct CalendarParticipantEnrichmentTests {
    @Test("Selection roundtrip preserves scope and occurrence identity")
    func selectionRoundtripUsesStableOccurrence() throws {
        let value = CalendarParticipantSelection(scope: CalendarCLICacheTests.scope,
            entry: CalendarCLICacheTests.entry())
        let decoded = try JSONDecoder().decode(CalendarParticipantSelection.self,
            from: JSONEncoder().encode(value))
        #expect(decoded.entry.key == value.entry.key)
        #expect(decoded.scope == value.scope)
    }

    @Test("Queue and job requests default legacy participant intent off")
    func legacyIntentDefaultsOff() throws {
        let legacyQueue = Data(#"{"transcribe":false,"summary":false,"actionItems":false,"tags":false}"#.utf8)
        let queue = try JSONDecoder().decode(QueueItem.self, from: legacyQueue)
        #expect(!queue.loadCalendarParticipants)
        let legacyRequest = Data(#"{"transcribe":false,"summary":false,"actionItems":false,"tags":false,"titleWasUserProvided":false,"autoResume":true}"#.utf8)
        let request = try JSONDecoder().decode(PersistedProcessingJob.Request.self, from: legacyRequest)
        #expect(!request.loadCalendarParticipants)
    }

    @Test("Enabled and disabled queue intent survive serialization")
    func queueIntentRoundtrip() throws {
        for enabled in [false, true] {
            let item = QueueItem(transcribe: false, summary: false, actionItems: false,
                tags: false, loadCalendarParticipants: enabled)
            let decoded = try JSONDecoder().decode(QueueItem.self, from: JSONEncoder().encode(item))
            #expect(decoded.loadCalendarParticipants == enabled)
        }
    }

    @Test("Durable request configuration contains a digest, not a custom command")
    func durableConfigurationOmitsCommand() throws {
        let secret = "custom-cli --credential=do-not-persist"
        let config = CalendarCLIConfig.unnormalized(timeoutSeconds: 30,
            mailboxEmail: "ada@example.com", command: secret)
        let scope = CalendarCLIScope(config: config)
        let value = CalendarParticipantRequestConfiguration(config: config,
            scope: scope)
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        #expect(!json.contains(secret))
        #expect(!json.contains("do-not-persist"))
        #expect(value.matches(config: config, scope: scope))
        #expect(!value.matches(config: config.updating(command: "other-cli"),
            scope: scope))
        let changedEffort = config.updating(effort: .high)
        #expect(value.restoredConfig(using: changedEffort)?.effort == config.effort)
        #expect(value.restoredConfig(using: config.updating(command: "other-cli")) == nil)
        #expect(value.restoredConfig(using: config.updating(attendeePolicy: .never)) == nil)
    }

    @Test("A launcher change invalidates recovery; no launcher keeps old journals valid")
    func launcherParticipatesInDigest() {
        let config = CalendarCLIConfig.unnormalized(timeoutSeconds: 30, mailboxEmail: "ada@example.com")
        let scope = CalendarCLIScope(config: config)
        let value = CalendarParticipantRequestConfiguration(config: config, scope: scope)
        let legacy = SHA256.hash(data: Data("managed-claude-calendar-command-v1".utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(value.commandDigest == legacy)
        #expect(!value.matches(config: config.updating(launcher: "cswap run 1 --"), scope: scope))
        #expect(value.restoredConfig(using: config.updating(launcher: "cswap run 2 --")) == nil)
    }
}
