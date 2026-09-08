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
            generatedTitle: "Generated",
            markdownPath: "/tmp/x.md"
        )
        try await store.save(insights, to: url)
        let loaded = try await store.load(from: url)
        #expect(loaded == insights)
    }

    @Test("legacy analysis without generated title still decodes")
    func legacyGeneratedTitleDecode() throws {
        let json = """
        {"version":1,"summary":"S","actionItems":[],"tags":[],"sentiment":"","markdownPath":null}
        """
        let decoded = try JSONDecoder().decode(
            RecordingInsights.self,
            from: Data(json.utf8)
        )
        #expect(decoded.generatedTitle == nil)
    }

    @Test("future analysis versions fail without changing the file")
    func futureVersionIsRejected() async throws {
        let store = InsightsStore()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data("""
        {"version":99,"summary":"S","actionItems":[],"tags":[],"sentiment":"","markdownPath":null}
        """.utf8)
        try bytes.write(to: url)

        await #expect(throws: InsightsStoreError.self) {
            _ = try await store.load(from: url)
        }
        #expect(try Data(contentsOf: url) == bytes)
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
