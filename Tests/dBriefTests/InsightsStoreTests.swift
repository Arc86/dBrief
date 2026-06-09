import Testing
import Foundation
@testable import dBrief

@Suite("InsightsStore")
struct InsightsStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("insights.json")
    }

    @Test("save then load returns equal value")
    func saveLoad() async throws {
        let store = InsightsStore()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let insights = RecordingInsights(
            version: 1,
            summary: "S",
            actionItems: ["a"],
            tags: ["t"],
            sentiment: "Positive",
            markdownPath: "/tmp/x.md"
        )
        try await store.save(insights, to: url)
        let loaded = try await store.load(from: url)
        #expect(loaded == insights)
    }

    @Test("load returns nil when file is absent")
    func loadAbsent() async throws {
        let store = InsightsStore()
        let loaded = try await store.load(from: tempURL())
        #expect(loaded == nil)
    }

    @Test("save overwrites existing file")
    func overwrite() async throws {
        let store = InsightsStore()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = RecordingInsights(version: 1, summary: "first",
                                      actionItems: [], tags: [], sentiment: "", markdownPath: nil)
        let second = RecordingInsights(version: 1, summary: "second",
                                       actionItems: [], tags: [], sentiment: "", markdownPath: nil)
        try await store.save(first, to: url)
        try await store.save(second, to: url)
        let loaded = try await store.load(from: url)
        #expect(loaded?.summary == "second")
    }
}
