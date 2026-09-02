import Foundation
import Testing
@testable import dBrief

@Suite("Durability diagnostics")
struct DurabilityDiagnosticsTests {
    @Test
    func journalRoundTripsEventsAndRotatesToTheRetentionLimit() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DurabilityJournal(
            directoryURL: root,
            maxBytes: 1,
            retainedEventCount: 2
        )
        let sessionID = UUID()

        journal.record(.init(sessionID: sessionID, name: "one", outcome: .started))
        journal.record(.init(sessionID: sessionID, name: "two", outcome: .warning))
        journal.record(.init(sessionID: sessionID, name: "three", outcome: .succeeded))

        let events = journal.recentEvents(limit: 10)
        #expect(events.map(\.name) == ["two", "three"])
        #expect(events.allSatisfy { $0.sessionID == sessionID })
    }

    @Test
    func reportContainsAggregateRecoveryDataWithoutPathsOrMeetingContent() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
        let recovery = root.appendingPathComponent("Recovery", isDirectory: true)
        let diagnostics = root.appendingPathComponent("Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let session = try InterruptedSessionStore.createSession(
            id: UUID(),
            startedAt: Date(),
            rootURL: recovery
        )
        try Data(repeating: 7, count: 5_000).write(
            to: session.directoryURL.appendingPathComponent("capture.mic.caf")
        )
        let journal = DurabilityJournal(directoryURL: diagnostics)
        journal.record(.init(name: "capture_stopped", outcome: .succeeded))

        let report = DBriefDiagnosticsExporter.makeReport(
            recordingFolderURL: recordings,
            journal: journal,
            recoveryRootURL: recovery
        )
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)

        #expect(report.recoverySessions.count == 1)
        #expect(report.recoverySessions[0].existingTrackBytes == 5_000)
        #expect(report.recentDurabilityEvents.map(\.name) == ["capture_stopped"])
        #expect(!encoded.contains(recordings.path))
        #expect(!encoded.contains(session.directoryURL.path))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dbrief-diagnostics-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
