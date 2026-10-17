import Foundation
import Testing
@testable import dBrief

@Suite("Recording analysis edits")
struct RecordingAnalysisEditTests {
    @Test("Edited fields win while untouched fields and newer export metadata remain current")
    func editsOnlyFieldsChangedFromTheirBaseline() async throws {
        let (directory, _, sidecarURL) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InsightsStore()
        let baseline = RecordingInsights(
            summary: "Baseline summary",
            actionItems: ["Alice: send notes", "Morgan: review launch"],
            tags: ["baseline"],
            sentiment: "Neutral",
            generatedTitle: "Original title",
            markdownPath: "/tmp/original-note.md"
        )
        try await store.save(baseline, to: sidecarURL)

        var latest = baseline
        latest.summary = "Newer analysis summary"
        latest.actionItems.append("Lee: share draft")
        latest.tags = ["launch", "customer"]
        latest.sentiment = "Positive"
        latest.generatedTitle = "Fresh meeting title"
        latest.markdownPath = "/tmp/fresh-note.md"
        try await store.save(latest, to: sidecarURL)
        _ = try await store.setActionCompleted("Alice: send notes", completed: true, at: sidecarURL)
        _ = try await store.setActionCompleted("Lee: share draft", completed: true, at: sidecarURL)

        var edited = baseline
        edited.summary = "User-edited summary"
        edited.actionItems = [
            "Alice: send notes",
            "Morgan: review launch",
            "Customer: add a rollout note",
        ]
        // Tags, sentiment, export path, and generated title are unchanged from
        // the editor's baseline, so this edit must not restore their stale values.
        let saved = try await store.saveAnalysisEdit(edited, basedOn: baseline, to: sidecarURL)
        let reloaded = try #require(try await store.load(from: sidecarURL))

        #expect(saved == reloaded)
        #expect(saved.summary == "User-edited summary")
        #expect(saved.actionItems == [
            "Alice: send notes",
            "Morgan: review launch",
            "Customer: add a rollout note",
        ])
        #expect(saved.tags == ["launch", "customer"])
        #expect(saved.sentiment == "Positive")
        #expect(saved.generatedTitle == "Fresh meeting title")
        #expect(saved.markdownPath == "/tmp/fresh-note.md")
        #expect(saved.completedActionItems == ["Alice: send notes"])
        #expect(saved.unfinishedActionItems == [
            "Morgan: review launch",
            "Customer: add a rollout note",
        ])
    }

    @Test("A renamed action does not inherit completion from its old raw key")
    func changedActionKeyStartsUnfinished() async throws {
        let (directory, _, sidecarURL) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InsightsStore()
        let baseline = RecordingInsights(
            summary: "Summary",
            actionItems: ["Morgan: send notes"],
            tags: [],
            sentiment: "Neutral",
            markdownPath: nil
        )
        try await store.save(baseline, to: sidecarURL)
        _ = try await store.setActionCompleted("Morgan: send notes", completed: true, at: sidecarURL)

        var edited = baseline
        edited.actionItems = ["Morgan: send notes to the team"]
        let saved = try await store.saveAnalysisEdit(edited, basedOn: baseline, to: sidecarURL)

        #expect(saved.actionItems == ["Morgan: send notes to the team"])
        #expect(saved.completedActions.isEmpty)
        #expect(saved.unfinishedActionItems == ["Morgan: send notes to the team"])
    }

    @Test("Completion keys preserve the exact identity of similar-looking actions")
    func similarRawActionKeysRemainDistinct() async throws {
        let (directory, _, sidecarURL) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InsightsStore()
        let rawActions = ["Alex: follow-up notes", "Alex: follow up notes"]
        let baseline = RecordingInsights(
            summary: "Before",
            actionItems: rawActions,
            tags: [],
            sentiment: "",
            markdownPath: nil
        )
        try await store.save(baseline, to: sidecarURL)
        _ = try await store.setActionCompleted(rawActions[1], completed: true, at: sidecarURL)

        var edited = baseline
        edited.summary = "After"
        let saved = try await store.saveAnalysisEdit(edited, basedOn: baseline, to: sidecarURL)

        #expect(saved.actionItems == rawActions)
        #expect(saved.completedActionItems == ["Alex: follow up notes"])
        #expect(saved.unfinishedActionItems == ["Alex: follow-up notes"])
    }

    @Test("A rejected write leaves the editor draft and stored sidecar unchanged")
    func failedWriteDoesNotReplaceDraftOrSidecar() async throws {
        let (directory, audioURL, sidecarURL) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InsightsStore()
        let baseline = RecordingInsights(
            summary: "Saved summary",
            actionItems: ["Taylor: review draft"],
            tags: ["review"],
            sentiment: "Neutral",
            generatedTitle: "Review meeting",
            markdownPath: "/tmp/review.md"
        )
        try await store.save(baseline, to: sidecarURL)
        let originalBytes = try Data(contentsOf: sidecarURL)
        var edited = baseline
        edited.summary = "Draft summary that must stay visible"
        edited.actionItems = ["Taylor: publish draft"]
        let attemptID = UUID()
        try RecordingResultMutation.claim(audioURL: audioURL, attemptID: attemptID)
        defer { RecordingResultMutation.release(audioURL: audioURL, attemptID: attemptID) }

        do {
            _ = try await store.saveAnalysisEdit(edited, basedOn: baseline, to: sidecarURL)
            Issue.record("A pending result mutation should reject the analysis edit.")
        } catch ReprocessingStore.StoreError.alreadyPending {
            // The editor keeps its in-memory draft when the persistence closure fails.
        }

        let reloaded = try #require(try await store.load(from: sidecarURL))
        #expect(edited.summary == "Draft summary that must stay visible")
        #expect(edited.actionItems == ["Taylor: publish draft"])
        #expect(reloaded == baseline)
        #expect(try Data(contentsOf: sidecarURL) == originalBytes)
    }

    private func fixture() throws -> (directory: URL, audio: URL, sidecar: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-analysis-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("meeting.m4a")
        try Data("test audio placeholder".utf8).write(to: audioURL)
        let sidecarURL = audioURL.deletingPathExtension().appendingPathExtension("insights.json")
        return (directory, audioURL, sidecarURL)
    }
}
