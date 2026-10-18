import Foundation
import Testing
@testable import dBrief

/// One global error string used to overwrite earlier errors and was cleared by
/// unrelated actions such as pressing Record.
@Suite @MainActor struct NoticeListTests {
    private let meeting = URL(fileURLWithPath: "/tmp/notices/meeting.m4a")

    @Test func laterNoticesDoNotOverwriteEarlierOnes() {
        var list = NoticeList()
        list.post(.init(tone: .error, message: "Couldn't send to Notion.", source: .integrations,
                        actions: [.reviewIntegrations(meeting)]))
        list.post(.init(tone: .error, message: "Microphone switch failed.", source: .capture))
        #expect(list.items.map(\.message) == ["Microphone switch failed.", "Couldn't send to Notion."])
    }

    @Test func clearingOneSourceKeepsTheOthers() {
        var list = NoticeList()
        list.post(.init(tone: .error, message: "Couldn't send to Notion.", source: .integrations))
        list.post(.init(tone: .error, message: "Couldn't resume recording.", source: .capture))
        list.clear(source: .capture)
        #expect(list.items.map(\.source) == [.integrations])
    }

    @Test func repeatsMoveToTheTopInsteadOfStacking() {
        var list = NoticeList()
        list.post(.init(tone: .error, message: "Same", source: .queue))
        list.post(.init(tone: .error, message: "Other", source: .queue))
        list.post(.init(tone: .error, message: "Same", source: .queue))
        #expect(list.items.map(\.message) == ["Same", "Other"])
    }

    @Test func keepsTheNewestFewAndDismissesOne() throws {
        var list = NoticeList()
        for index in 1...8 { list.post(.init(tone: .info, message: "\(index)", source: .processing)) }
        #expect(list.items.map(\.message) == ["8", "7", "6", "5", "4"])
        let id = try #require(list.items.first?.id)
        list.dismiss(id)
        #expect(list.items.first?.message == "7")
    }

    @Test func recordingNoticesCanBeShownWhereThatRecordingIsOpen() {
        var list = NoticeList()
        list.post(.init(tone: .error, message: "Reprocessing failed.", source: .reprocessing, recordingURL: meeting))
        list.post(.init(tone: .error, message: "Unrelated", source: .capture))
        #expect(list.items(for: meeting).map(\.message) == ["Reprocessing failed."])
    }

    /// Untouched call sites still set `lastError`; it must not clear typed notices.
    @Test func legacyLastErrorOnlyTouchesItsOwnNotices() {
        let state = AppState()
        state.post(.init(tone: .error, message: "Couldn't send to Notion.", source: .integrations))
        state.lastError = "Something failed."
        #expect(state.lastError == "Something failed.")
        state.lastError = nil
        #expect(state.notices.items.map(\.message) == ["Couldn't send to Notion."])
        #expect(state.lastError == "Couldn't send to Notion.")
    }
}
