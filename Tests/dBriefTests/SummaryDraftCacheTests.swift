import Foundation
import Testing
@testable import dBrief

@MainActor
@Suite("Summary draft cache")
struct SummaryDraftCacheTests {
    private let url = URL(fileURLWithPath: "/tmp/2026-09-30_1400_ITSM.m4a")

    private func makeInsights(summary: String) -> RecordingInsights {
        RecordingInsights(summary: summary, actionItems: ["Scan draaien"], tags: ["itsm"], sentiment: "positive", markdownPath: nil)
    }

    private func dirtyState(summary: String = "Overview") -> SummaryEditState {
        var state = SummaryEditState(insights: makeInsights(summary: summary))
        state.draft.apply(.loaded(markdown: summary + "\n"))
        state.draft.apply(.changed(markdown: summary + "\n\nNieuwe alinea\n"))
        return state
    }

    @Test("A dirty draft survives leaving and reopening the recording")
    func restoresDirtyDraft() {
        let cache = SummaryDraftCache()
        let state = dirtyState()
        cache.store(state, for: url)
        #expect(cache.restore(for: url) == state)
    }

    @Test("Clean drafts and cleared edits are not kept")
    func dropsCleanAndCleared() {
        let cache = SummaryDraftCache()
        var clean = SummaryEditState(insights: makeInsights(summary: "Overview"))
        clean.draft.apply(.loaded(markdown: "Overview\n"))
        cache.store(clean, for: url)
        #expect(cache.restore(for: url) == nil)

        cache.store(dirtyState(), for: url)
        cache.store(nil, for: url)   // saved or cancelled
        #expect(cache.restore(for: url) == nil)
    }

    @Test("Drafts are per recording")
    func perRecording() {
        let cache = SummaryDraftCache()
        cache.store(dirtyState(), for: url)
        #expect(cache.restore(for: URL(fileURLWithPath: "/tmp/other.m4a")) == nil)
    }

    @Test("A draft is stale once the stored summary changed underneath it")
    func staleness() {
        let state = SummaryEditState(insights: makeInsights(summary: "Old summary"))
        #expect(!state.isStale(currentSummary: "Old summary"))
        #expect(state.isStale(currentSummary: "Regenerated summary"))
        #expect(state.isStale(currentSummary: nil))
    }

    @Test("A new edit starts from the stored summary, clean")
    func initialState() {
        let state = SummaryEditState(insights: makeInsights(summary: "Overview"))
        #expect(state.draft.current == "Overview")
        #expect(!state.draft.isDirty)
    }
}
