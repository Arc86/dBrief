import Foundation
import Testing
@testable import dBrief

@Suite("Reprocessing derivative write protection")
struct ReprocessingDerivativeTests {
    private func fixture() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("meeting.m4a")
        try Data("original audio".utf8).write(to: audio)
        return (directory, audio)
    }

    @Test("Retired chat cannot overwrite or delete restored conversation after unlock")
    func invalidatedConversation() async throws {
        let (directory, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = audio.deletingPathExtension().appendingPathExtension("chat.json")
        let store = ChatStore()
        let old = ChatHistory(messages: [ChatMessage(role: .user, content: "old context")])
        let restored = ChatHistory(messages: [ChatMessage(role: .user, content: "restored context")])
        let validity = RecordingDerivativeValidity()
        try await store.save(old, to: url, validity: validity)
        let attemptID = UUID()
        try RecordingResultMutation.claim(audioURL: audio, attemptID: attemptID)
        validity.invalidate()
        RecordingResultMutation.release(audioURL: audio, attemptID: attemptID)
        try await store.save(restored, to: url)
        do {
            try await store.save(old, to: url, validity: validity)
            Issue.record("A retired session overwrote restored chat")
        } catch is CancellationError { }
        await store.delete(at: url, validity: validity)
        #expect(try await store.load(from: url) == restored)
    }

    @Test("Pending attempts reject chat writes and spoken-summary script writes")
    func pendingAttempt() async throws {
        let (directory, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chatURL = audio.deletingPathExtension().appendingPathExtension("chat.json")
        let scriptURL = audio.deletingPathExtension().appendingPathExtension("spokensummary.json")
        let attemptID = UUID()
        try RecordingResultMutation.claim(audioURL: audio, attemptID: attemptID)
        defer { RecordingResultMutation.release(audioURL: audio, attemptID: attemptID) }
        let chat = ChatHistory(messages: [ChatMessage(role: .user, content: "stale")])
        do {
            try await ChatStore().save(chat, to: chatURL)
            Issue.record("Chat wrote during a pending attempt")
        } catch ReprocessingStore.StoreError.alreadyPending { }
        let script = SpokenSummary(script: "stale", audioFileName: "meeting.spokensummary.m4a", voice: nil,
                                   language: nil, engine: "test", generatedAt: Date())
        do {
            try await SpokenSummaryStore().save(script, to: scriptURL)
            Issue.record("Spoken summary wrote during a pending attempt")
        } catch ReprocessingStore.StoreError.alreadyPending { }
        #expect(!FileManager.default.fileExists(atPath: chatURL.path))
        #expect(!FileManager.default.fileExists(atPath: scriptURL.path))
    }
}
