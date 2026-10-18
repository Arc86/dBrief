import Foundation
import Testing
@testable import dBrief

@Suite @MainActor struct RecordingHistoryIdentityTests {
    private func item(_ path: String, title: String? = nil) -> RecordingHistoryView.HistoryItem {
        RecordingHistoryView.HistoryItem(
            url: URL(fileURLWithPath: path), name: "2026-09-29_1000_meeting", date: .distantPast,
            size: 1, duration: 60, profileName: nil, hasTranscript: true, hasRichTranscript: true,
            hasInsights: false, isQueued: false, generatedTitle: title, markdownURL: nil)
    }

    @Test func reloadedItemsKeepTheirIdentity() {
        let first = item("/tmp/a.m4a")
        let reloaded = item("/tmp/a.m4a")
        #expect(first.id == reloaded.id)
        #expect(first == reloaded)
    }

    @Test func changedMetadataIsNotEqualButKeepsIdentity() {
        let before = item("/tmp/a.m4a")
        let after = item("/tmp/a.m4a", title: "Planning")
        #expect(before.id == after.id)
        #expect(before != after)
    }

    @Test func reconcileDropsStateForRecordingsThatDisappeared() {
        let kept = item("/tmp/a.m4a")
        let gone = URL(fileURLWithPath: "/tmp/b.m4a")
        let result = RecordingHistoryView.reconcile(
            loaded: [kept],
            summaries: [kept.url: "A", gone: "B"],
            expanded: gone)
        #expect(result.summaries == [kept.url: "A"])
        #expect(result.expanded == nil)
    }

    @Test func reconcileKeepsExpandedRowThatStillExists() {
        let kept = item("/tmp/a.m4a")
        let result = RecordingHistoryView.reconcile(loaded: [kept], summaries: [:], expanded: kept.url)
        #expect(result.expanded == kept.url)
    }
}
