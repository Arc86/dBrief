import Foundation
import Testing
@testable import dBrief

@Suite(.serialized) @MainActor struct ChatHistoryLoadingStateTests {
    private func waitUntilLoaded(_ service: TranscriptChatService) async throws {
        for _ in 0..<100 where service.isLoadingHistory {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func loadingFlagCoversTheDiskRead() async throws {
        let service = TranscriptChatService(transcriptText: "T", speakerLabels: [], appSettings: AppSettings(), localPlugin: nil)
        let history = ChatHistory(messages: [ChatMessage(role: .user, content: "Hi"),
                                             ChatMessage(role: .assistant, content: "Hello")])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loading-\(UUID()).chat.json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ChatStore()
        try await store.save(history, to: url)
        service.enablePersistence(store: store, url: url)

        service.startLoadingPersisted()
        #expect(service.isLoadingHistory)
        try await waitUntilLoaded(service)
        #expect(!service.isLoadingHistory)
        #expect(service.messages == history.messages)
    }

    @Test func missingSidecarEndsLoadingWithNoMessages() async throws {
        let service = TranscriptChatService(transcriptText: "T", speakerLabels: [], appSettings: AppSettings(), localPlugin: nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID()).chat.json")
        service.enablePersistence(store: ChatStore(), url: url)
        service.startLoadingPersisted()
        try await waitUntilLoaded(service)
        #expect(!service.isLoadingHistory)
        #expect(service.messages.isEmpty)
    }

    @Test func invalidationClearsTheLoadingFlag() {
        let service = TranscriptChatService(transcriptText: "T", speakerLabels: [], appSettings: AppSettings(), localPlugin: nil)
        service.enablePersistence(store: ChatStore(), url: FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID()).chat.json"))
        service.startLoadingPersisted()
        service.invalidateForReprocessing()
        #expect(!service.isLoadingHistory)
    }
}
