import Foundation
import Testing
import dBriefWire
@testable import dBrief

@MainActor
@Suite struct ChatTranscriptRebindTests {
    private func transcript(_ name: String, speakerOfSecond: String = "s1") -> RichTranscript {
        RichTranscript(segments: [
            RichSegment(start: 0, end: 2, text: "Budget is approved.", originalText: "Budget is approved.", speakerId: "s1"),
            RichSegment(start: 70, end: 72, text: "Send the deck.", originalText: "Send the deck.", speakerId: speakerOfSecond),
        ], speakerLabels: [SpeakerLabel(id: "s1", displayName: name), SpeakerLabel(id: "s2", displayName: "Bob")])
    }

    @Test func contentUsesDisplayNamesTimestampsAndTurns() {
        let content = ChatTranscriptContent.make(richTranscript: transcript("Alice"), fallbackText: "flat")
        #expect(content.text == "[00:00:00] Alice: Budget is approved.\n[00:01:10] Alice: Send the deck.")
        #expect(content.turns.map(\.speaker) == ["Alice", "Alice"])
        #expect(content.speakerLabels.map(\.displayName) == ["Alice", "Bob"])
    }

    @Test func contentFallsBackToFlatTextWithoutSegments() {
        let content = ChatTranscriptContent.make(richTranscript: nil, fallbackText: "flat text")
        #expect(content.text == "flat text")
        #expect(content.turns.isEmpty)
    }

    @Test func legendKeyIgnoresVoiceLibraryLinks() {
        var linked = SpeakerLabel(id: "s1", displayName: "Alice")
        linked.personId = "p1"
        #expect(ChatTranscriptContent.legendKey([linked]) == ChatTranscriptContent.legendKey([SpeakerLabel(id: "s1", displayName: "Alice")]))
        #expect(ChatTranscriptContent.legendKey([linked]) != ChatTranscriptContent.legendKey([SpeakerLabel(id: "s1", displayName: "Ann")]))
    }

    @Test func rebindAfterRenameAndMoveKeepsMessagesAndUsesNewNames() async {
        let before = ChatTranscriptContent.make(richTranscript: transcript("Alice"), fallbackText: "")
        let service = TranscriptChatService(transcriptText: before.text, speakerLabels: before.speakerLabels,
                                            appSettings: AppSettings(), localPlugin: nil, turns: before.turns)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".chat.json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ChatStore()
        try? await store.save(ChatHistory(messages: [ChatMessage(role: .user, content: "Who approved it?"),
                                                     ChatMessage(role: .assistant, content: "Alice.")]), to: url)
        service.enablePersistence(store: store, url: url)
        await service.loadPersisted()
        #expect(service.messages.count == 2)
        let renamed = ChatTranscriptContent.make(richTranscript: transcript("Carol"), fallbackText: "")
        service.rebind(renamed, insightsURL: nil, indexURL: nil)
        #expect(service.currentTranscriptText.contains("Carol: Budget is approved."))
        #expect(!service.currentTranscriptText.contains("Alice"))
        #expect(service.chatTurns == renamed.turns)
        #expect(service.speakerLabels.map(\.displayName) == ["Carol", "Bob"])
        #expect(service.messages.map(\.content) == ["Who approved it?", "Alice."])

        let moved = ChatTranscriptContent.make(richTranscript: transcript("Carol", speakerOfSecond: "s2"), fallbackText: "")
        service.rebind(moved, insightsURL: nil, indexURL: nil)
        #expect(service.currentTranscriptText.contains("[00:01:10] Bob: Send the deck."))
    }

    @Test func liveChatRebindsToTurnsAndTimestampedText() {
        let service = TranscriptChatService(transcriptProvider: { "live preview" }, speakerLabels: [],
                                            appSettings: AppSettings(), localPlugin: nil)
        #expect(service.chatTurns.isEmpty)
        let final = ChatTranscriptContent.make(richTranscript: transcript("Alice"), fallbackText: "")
        service.rebind(final, insightsURL: nil, indexURL: nil)
        #expect(service.chatTurns.count == 2)
        #expect(service.currentTranscriptText.hasPrefix("[00:00:00] Alice:"))
    }

    @Test func retiredSessionIgnoresRebind() {
        let service = TranscriptChatService(transcriptText: "old", speakerLabels: [],
                                            appSettings: AppSettings(), localPlugin: nil)
        service.invalidateForReprocessing()
        service.rebind(turns: [], transcriptText: "new", speakerLabels: [], insightsURL: nil, indexURL: nil)
        #expect(service.currentTranscriptText == "old")
    }

    @Test func scanIsOfferedAfterLongModeOrAppleOverflowOnFinishedRecordingsOnly() {
        #expect(TranscriptChatService.offersScan(coverage: .relevantParts, appleOverflowed: false, canRetrieve: true))
        #expect(TranscriptChatService.offersScan(coverage: nil, appleOverflowed: true, canRetrieve: true))
        #expect(!TranscriptChatService.offersScan(coverage: nil, appleOverflowed: true, canRetrieve: false))
        #expect(!TranscriptChatService.offersScan(coverage: .recentPart, appleOverflowed: false, canRetrieve: true))
        #expect(!TranscriptChatService.offersScan(coverage: .full, appleOverflowed: false, canRetrieve: true))
        #expect(!TranscriptChatService.offersScan(coverage: nil, appleOverflowed: false, canRetrieve: true))
    }
}
