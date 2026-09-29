import SwiftUI
import Testing
@testable import dBrief

@Suite @MainActor struct TranscriptTurnRowTests {
    private let turn = SpeakerTurn(speakerId: "S1", segments: [
        RichSegment(start: 0, end: 1, text: "Hello there", originalText: "Hello there", speakerId: "S1"),
    ])

    private func model(active: Bool = false, name: String = "Alice", menuKey: Int = 0,
                       matches: [TranscriptSearch.Match] = [], current: Int = -1) -> TranscriptTurnRow<EmptyView>.Model {
        .init(turn: turn, isActive: active, isLast: false, isMe: false, showSpeakerName: true,
              displayName: name, color: .blue, matches: matches, currentMatchIndex: current,
              rowPadding: 12, headerGap: 6, menuKey: menuKey)
    }

    private func row(_ model: TranscriptTurnRow<EmptyView>.Model, onSeek: @escaping (TimeInterval) -> Void = { _ in }) -> TranscriptTurnRow<EmptyView> {
        TranscriptTurnRow(model: model, onSeek: onSeek) { EmptyView() }
    }

    @Test func closuresDoNotAffectEquality() {
        // A parent re-render creates fresh closures every time; the row must still
        // compare equal so SwiftUI skips its body.
        #expect(row(model(), onSeek: { _ in }) == row(model(), onSeek: { _ in print("other") }))
    }

    @Test func visibleStateChangesBreakEquality() {
        #expect(row(model()) != row(model(active: true)))
        #expect(row(model()) != row(model(name: "Bob")))
        #expect(row(model()) != row(model(menuKey: 1)))
    }

    @Test func currentMatchIsOnlyPassedToTheTurnThatOwnsIt() {
        let mine = TranscriptSearch.Match(turnId: turn.id, location: 0, length: 5, globalIndex: 3)
        #expect(TranscriptTurnRow<EmptyView>.rowMatchIndex(matches: [mine], current: 3) == 3)
        #expect(TranscriptTurnRow<EmptyView>.rowMatchIndex(matches: [mine], current: 4) == -1)
        #expect(TranscriptTurnRow<EmptyView>.rowMatchIndex(matches: [], current: 3) == -1)
    }
}
