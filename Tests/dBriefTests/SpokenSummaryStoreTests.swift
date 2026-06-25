import Testing
import Foundation
@testable import dBrief

@Suite struct SpokenSummaryStoreTests {
    @Test func savesAndLoadsRoundTrip() async throws {
        let store = SpokenSummaryStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).spokensummary.json")
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = SpokenSummary(
            script: "A spoken briefing.",
            audioFileName: "meeting.spokensummary.m4a",
            voice: nil,
            language: "en",
            engine: "appleIntelligence",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await store.save(summary, to: url)
        let loaded = try await store.load(from: url)
        #expect(loaded == summary)
    }

    @Test func loadReturnsNilWhenAbsent() async throws {
        let store = SpokenSummaryStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).spokensummary.json")
        #expect(try await store.load(from: url) == nil)
    }
}
