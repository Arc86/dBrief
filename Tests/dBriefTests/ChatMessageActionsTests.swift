import Foundation
import Testing
@testable import dBrief

@Suite struct ChatMessageActionsTests {
    @Test func actionsExcludeReasoning() {
        let message = ChatMessage(role: .assistant, content: "<think>Private reasoning</think>\n## Answer\n- **Send** the notes.")
        #expect(message.displayParts.reasoning == "Private reasoning")
        #expect(message.displayParts.answer == "## Answer\n- **Send** the notes.")
        #expect(message.speechText == "Answer\nSend the notes.")
    }

    @Test func unfinishedReasoningHasNoSpeakableAnswer() {
        let message = ChatMessage(role: .assistant, content: "<think>Still thinking")
        #expect(message.displayParts.answer.isEmpty)
        #expect(message.speechText.isEmpty)
    }

    @Test func userTextIsUnchanged() {
        let text = "Explain <think> tags"
        #expect(ChatMessage(role: .user, content: text).displayParts.answer == text)
    }
}

@Suite("Speech playback cancellation", .serialized)
@MainActor
struct VoicePlaybackCancellationTests {
    @Test func missingAudioShowsFailure() async {
        let player = VoicePreviewPlayer()
        player.start { _ in }
        for _ in 0..<10 { await Task.yield() }
        guard case .failed = player.state else {
            Issue.record("Unreadable generated audio must show an error")
            return
        }
        #expect(!player.isBusy)
    }

    @Test func lateFailureCannotReplaceNewRequest() async throws {
        let player = VoicePreviewPlayer()
        var oldRequest: CheckedContinuation<Void, Error>?
        var newRequest: CheckedContinuation<Void, Error>?
        player.start { _ in
            try await withCheckedThrowingContinuation { oldRequest = $0 }
        }
        while oldRequest == nil { await Task.yield() }
        player.start { _ in
            try await withCheckedThrowingContinuation { newRequest = $0 }
        }
        while newRequest == nil { await Task.yield() }
        oldRequest?.resume(throwing: CocoaError(.fileReadUnknown))
        for _ in 0..<10 { await Task.yield() }
        #expect(player.state == .synthesizing)
        player.stop()
        newRequest?.resume()
        for _ in 0..<10 { await Task.yield() }
        #expect(player.state == .idle)
    }

    @Test func clearingChatStopsSpeechAndMissingProviderIsRecoverable() async throws {
        let service = TranscriptChatService(transcriptText: "Meeting", speakerLabels: [],
                                            appSettings: AppSettings(), localPlugin: nil)
        let message = ChatMessage(role: .assistant, content: "**Send** the notes.")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-actions-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ChatStore()
        try await store.save(ChatHistory(messages: [message]), to: url)
        service.enablePersistence(store: store, url: url)
        await service.loadPersisted()
        service.toggleReadAloud(message)
        for _ in 0..<10 { await Task.yield() }
        #expect(service.spokenMessageID == message.id)
        #expect(service.speechPlayer.state == .failed(message: "Local AI plugin not available."))
        service.clearMessages()
        #expect(service.spokenMessageID == nil)
        #expect(service.speechPlayer.state == .idle)
        #expect(service.messages.isEmpty)
    }
}
