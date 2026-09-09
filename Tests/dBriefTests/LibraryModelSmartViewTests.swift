import Foundation
import Testing
@testable import dBrief

@Suite("Smart-view library model") @MainActor
struct LibraryModelSmartViewTests {
    @Test func routineRefreshKeepsLoadedResultsAndDoesNotShowInitialLoadingAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: folder.appendingPathComponent("Meeting.wav"))
        let suite = "library-refresh-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RecordingLibraryModel(index: LibraryIndex(cacheRoot: root.appendingPathComponent("cache"), jobsRoot: root.appendingPathComponent("jobs")), selectionStore: .init(defaults: defaults))
        model.selectView(.all)
        model.open(folder)
        #expect(model.showsInitialLoading)
        try await waitForQuery(model)
        let urls = model.matches.map(\.url)
        #expect(urls.count == 1)
        model.refresh()
        #expect(!model.showsInitialLoading)
        #expect(model.matches.map(\.url) == urls)
        model.refreshTimeContext()
        #expect(model.matches.map(\.url) == urls)
        try await waitForQuery(model)
        #expect(!model.showsInitialLoading)
        #expect(model.matches.map(\.url) == urls)
    }

    @Test func openingLibraryUsesSavedPresetWhileKeepingAllItemsForDetailSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["open", "done"] {
            try Data([1]).write(to: folder.appendingPathComponent(name + ".wav"))
        }
        try Data(#"{"actionItems":["Follow up"]}"#.utf8).write(to: folder.appendingPathComponent("open.insights.json"))
        let suite = "dBrief-smart-model-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selection = LibrarySmartViewSelection(defaults: defaults)
        selection.save(.unfinishedActions)
        let index = LibraryIndex(cacheRoot: root.appendingPathComponent("cache"), jobsRoot: root.appendingPathComponent("jobs"))
        let model = RecordingLibraryModel(index: index, selectionStore: selection)
        model.open(folder)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (model.refreshedRevision == 0 || model.matches.isEmpty) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.items.count == 2)
        #expect(model.matches.map(\.name) == ["open"])
    }
    private func waitForQuery(_ model: RecordingLibraryModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (model.isRefreshing || model.isQuerying) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isRefreshing && !model.isQuerying)
    }

    @Test func changedPresetsSearchAndActivePinsKeepOnlyLatestResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Alpha", "Beta"] {
            try Data([1]).write(to: folder.appendingPathComponent(name + ".wav"))
            try Data(#"{"actionItems":["Follow up"]}"#.utf8).write(to: folder.appendingPathComponent(name + ".insights.json"))
        }
        let suite = "dBrief-smart-model-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selection = LibrarySmartViewSelection(defaults: defaults)
        let model = RecordingLibraryModel(index: LibraryIndex(cacheRoot: root.appendingPathComponent("cache"),
            jobsRoot: root.appendingPathComponent("jobs")), selectionStore: selection)
        model.open(folder)
        try await waitForQuery(model)
        #expect(model.matches.count == 2)
        model.search(text: "Alpha", status: nil)
        model.selectView(.failedJobs)
        model.selectView(.unfinishedActions)
        model.search(text: "Beta", status: nil)
        #expect(!model.hasMatches)
        try await waitForQuery(model)
        #expect(model.matches.map(\.name) == ["Beta"])
        #expect(selection.load() == .unfinishedActions)
        let audio = folder.appendingPathComponent("Beta.wav")
        model.updateActiveWork(ids: [], audioURLs: [audio])
        try await waitForQuery(model)
        #expect(!model.hasMatches)
        #expect(model.items.count == 2)
        model.updateActiveWork(ids: [], audioURLs: [])
        try await waitForQuery(model)
        #expect(model.matches.map(\.name) == ["Beta"])
        try Data(#"{"actionItems":["Follow up"],"completedActionItems":["Follow up"]}"#.utf8)
            .write(to: folder.appendingPathComponent("Beta.insights.json"), options: .atomic)
        model.refresh()
        try await waitForQuery(model)
        #expect(!model.hasMatches)
        #expect(model.error == nil)
    }

    @Test func changedFilterFailureClearsResultsAndRefreshFailurePreservesSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("recordings")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: folder.appendingPathComponent("Alpha.wav"))
        let suite = "dBrief-smart-model-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RecordingLibraryModel(index: LibraryIndex(cacheRoot: cache, jobsRoot: root.appendingPathComponent("jobs")),
            selectionStore: .init(defaults: defaults))
        model.open(folder)
        try await waitForQuery(model)
        #expect(model.matches.count == 1)
        try FileManager.default.removeItem(at: folder)
        model.refresh()
        try await waitForQuery(model)
        #expect(model.matches.count == 1)
        #expect(model.error != nil)
        model.search(text: "Alpha", status: nil)
        try await waitForQuery(model)
        #expect(model.matches.count == 1)
        #expect(model.error != nil) // A successful cache query cannot hide discovery failure.
        try FileManager.default.removeItem(at: cache)
        model.search(text: "Beta", status: nil)
        #expect(!model.hasMatches)
        try await waitForQuery(model)
        #expect(!model.hasMatches)
        #expect(model.error != nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("Beta.wav"))
        model.refresh(rebuild: true)
        try await waitForQuery(model)
        #expect(model.error == nil)
        #expect(model.matches.map(\.name) == ["Beta"])
    }

    @Test func timeRefreshMovesPeopleBetweenMonthsWithoutChangingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = folder.appendingPathComponent("meeting.wav")
        try Data([1]).write(to: audio)
        try Data(#"{"dateISO8601":"2026-09-08T12:00:00Z","participants":["Alice"]}"#.utf8)
            .write(to: folder.appendingPathComponent("meeting.json"))
        let suite = "dBrief-smart-model-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RecordingLibraryModel(index: LibraryIndex(cacheRoot: root.appendingPathComponent("cache"),
            jobsRoot: root.appendingPathComponent("jobs")), selectionStore: .init(defaults: defaults))
        model.open(folder)
        try await waitForQuery(model)
        model.selectView(.peopleThisMonth)
        let september = try #require(ISO8601DateFormatter().date(from: "2026-09-10T12:00:00Z"))
        let october = try #require(ISO8601DateFormatter().date(from: "2026-10-10T12:00:00Z"))
        model.refreshTimeContext(now: september)
        try await waitForQuery(model)
        #expect(model.peopleGroups.map(\.person.key) == ["alice"])
        model.refreshTimeContext(now: october)
        try await waitForQuery(model)
        #expect(model.peopleGroups.isEmpty)
        model.refreshTimeContext(now: september)
        try await waitForQuery(model)
        model.updateActiveWork(ids: [], audioURLs: [audio])
        model.refreshTimeContext(now: september)
        try await waitForQuery(model)
        #expect(model.peopleGroups.isEmpty)
        #expect(model.items.count == 1)
    }

}
