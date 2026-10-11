import Foundation
import SwiftUI
import Testing
@testable import dBrief

@MainActor
@Suite("Focus Reader content")
struct FocusReaderContentTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    private let locale = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!

    private func insights(summary: String = "A summary.", actions: [String] = ["Alice to send the deck"],
                          tags: [String] = ["q3", " "]) -> RecordingInsights {
        RecordingInsights(summary: summary, actionItems: actions, tags: tags, sentiment: "", markdownPath: nil)
    }

    private func turn() -> TranscriptTurnRowModel {
        TranscriptTurnRowModel(turn: SpeakerTurn(speakerId: nil, segments: []), isActive: false, isPulsing: false,
            isLast: true, isMe: false, showSpeakerName: true, displayName: "Alice", color: .blue, matches: [],
            currentMatchIndex: -1, rowPadding: 8, headerGap: 4, menuKey: 0)
    }

    private func make(_ insights: RecordingInsights?, turns: [TranscriptTurnRowModel] = []) -> FocusReaderContent {
        FocusReaderContent.make(recordingID: UUID(), title: "Weekly sync", date: date, duration: 3_725,
                                insights: insights, owners: ["Alice"], turns: turns, locale: locale, timeZone: utc)
    }

    @Test func notesComeFirstWhenThereIsAnalysis() {
        let content = make(insights(), turns: [turn()])
        #expect(content.pages == [.notes, .transcript])
        #expect(content.initialPage == .notes)
        #expect(content.subtitle == "Sep 21, 2026 · 1 h 2 min")
        #expect(content.summary == "A summary.")
        #expect(content.tags == ["q3"])
        #expect(content.actionGroups.map(\.owner) == ["Alice"])
    }

    @Test func aRecordingWithoutAnalysisOpensOnTheTranscript() {
        let content = make(insights(summary: "  ", actions: [], tags: []), turns: [turn()])
        #expect(content.pages == [.transcript])
        #expect(content.initialPage == .transcript)
    }

    @Test func nothingToReadIsAnEmptyState() {
        let content = make(nil)
        #expect(content.pages.isEmpty)
        #expect(content.initialPage == nil)
    }

    @Test func placeholderActionItemsAreLeftOut() {
        let content = make(insights(summary: "", actions: ["- No action items identified"], tags: []))
        #expect(content.actionGroups.isEmpty)
        #expect(content.pages.isEmpty)
    }

    @Test func presentingStartsOnTheInitialPage() {
        let store = FocusReaderStore()
        store.page = .transcript
        store.present(make(insights(), turns: [turn()]))
        #expect(store.page == .notes)
        store.present(make(nil, turns: [turn()]))
        #expect(store.page == .transcript)
    }
}
