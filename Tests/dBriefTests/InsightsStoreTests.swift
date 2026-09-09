import Testing
import Foundation
@testable import dBrief

@Suite("InsightsStore")
struct InsightsStoreTests {
    @Test func exportLinkUpdatePreservesLatestAnalysisAndActionChecks() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = InsightsStore()
        let initial = RecordingInsights(summary: "User edited summary", actionItems: ["Follow up"], tags: ["keep"],
                                        sentiment: "Positive", generatedTitle: "Old title", markdownPath: nil)
        try await store.save(initial, to: url)
        async let checkbox = store.setActionCompleted("Follow up", completed: true, at: url)
        async let link: Void = store.setExportLink(URL(fileURLWithPath: "/tmp/new-note.md"), generatedTitle: "New title", at: url)
        _ = try await (checkbox, link)
        let saved = try #require(try await store.load(from: url))
        #expect(saved.summary == initial.summary && saved.actionItems == initial.actionItems && saved.tags == initial.tags)
        #expect(saved.completedActions == ["Follow up"])
        #expect(saved.markdownPath == "/tmp/new-note.md" && saved.generatedTitle == "New title")
    }

    @Test func exportLinkMissingCorruptAndCancelledUpdatesDoNotReplaceEvidence() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = InsightsStore()
        try await store.setExportLink(nil, generatedTitle: nil, at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let original = Data("corrupt analysis".utf8)
        try original.write(to: url)
        await #expect(throws: (any Error).self) { try await store.setExportLink(nil, generatedTitle: "Title", at: url) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.setExportLink(nil, generatedTitle: "Title", at: url)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func completionSurvivesRelaunchAndCanBeReopenedWithoutChangingAnalysis() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let initial = RecordingInsights(summary: "Keep summary", actionItems: ["Alice: follow up", "  ", "Bob: review"],
            tags: ["important"], sentiment: "Positive", generatedTitle: "Keep title", markdownPath: "/tmp/keep.md")
        let store = InsightsStore()
        try await store.save(initial, to: url)
        let completed = try await store.setActionCompleted("Alice: follow up", completed: true, at: url)
        #expect(completed.unfinishedActionItems == ["Bob: review"])
        let loaded = try #require(try await InsightsStore().load(from: url))
        #expect(loaded == completed)
        #expect(loaded.summary == initial.summary && loaded.tags == initial.tags)
        #expect(loaded.generatedTitle == initial.generatedTitle && loaded.markdownPath == initial.markdownPath)
        let reopened = try await store.setActionCompleted("Alice: follow up", completed: false, at: url)
        #expect(reopened.unfinishedActionItems == ["Alice: follow up", "Bob: review"])
    }

    @Test func concurrentCompletionsAndStaleAnalysisSavePreserveAllCurrentCheckboxes() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = InsightsStore()
        let initial = RecordingInsights(summary: "Before", actionItems: ["a", "b", "c"], tags: [], sentiment: "", markdownPath: nil)
        try await store.save(initial, to: url)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for action in initial.actionItems {
                group.addTask { _ = try await store.setActionCompleted(action, completed: true, at: url) }
            }
            try await group.waitForAll()
        }
        var staleEdit = initial
        staleEdit.summary = "After"
        try await store.save(staleEdit, to: url)
        let saved = try #require(try await store.load(from: url))
        #expect(saved.completedActions == ["a", "b", "c"])
        #expect(saved.unfinishedActionItems.isEmpty)
        #expect(saved.summary == "After")
    }

    @Test func changedMissingCorruptAndFutureActionsDoNotWrite() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = InsightsStore()
        await #expect(throws: InsightsStoreError.self) { _ = try await store.setActionCompleted("a", completed: true, at: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        for bytes in [
            Data("corrupt".utf8),
            Data(#"{"version":99,"summary":"S","actionItems":["a"],"tags":[],"sentiment":""}"#.utf8),
            Data(#"{"version":1,"summary":"S","actionItems":["edited a"],"tags":[],"sentiment":""}"#.utf8)
        ] {
            try bytes.write(to: url)
            await #expect(throws: (any Error).self) { _ = try await store.setActionCompleted("a", completed: true, at: url) }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test func legacyActionsStartOpenAndIdenticalTextSharesCompletion() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"version":1,"summary":"S","actionItems":["a","a","b"],"tags":[],"sentiment":""}"#.utf8).write(to: url)
        let store = InsightsStore()
        let legacy = try #require(try await store.load(from: url))
        #expect(legacy.completedActions.isEmpty)
        #expect(legacy.unfinishedActionItems == ["a", "a", "b"])
        let done = try await store.setActionCompleted("a", completed: true, at: url)
        #expect(done.unfinishedActionItems == ["b"])
        #expect(done.completedActionItems == ["a"])
    }

    @Test func analysisSavePreservesCompletionForUnchangedActions() async throws {
        let store = InsightsStore()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"version":1,"summary":"old","actionItems":["a","b"],"completedActionItems":["a","b"],"tags":[],"sentiment":""}"#.utf8).write(to: url)
        let regenerated = RecordingInsights(summary: "new", actionItems: ["a", "new task"], tags: [], sentiment: "", markdownPath: nil)
        try await store.save(regenerated, to: url)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["completedActionItems"] as? [String] == ["a"])
        #expect(json["summary"] as? String == "new")
    }
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
