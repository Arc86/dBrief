import Testing
import Foundation
@testable import dBrief

@Suite("ChatStore")
struct ChatStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("chat.json")
    }

    private func sampleHistory() -> ChatHistory {
        ChatHistory(
            messages: [
                ChatMessage(role: .user, content: "What were the action items?"),
                ChatMessage(role: .assistant, content: "1. Ship the release."),
            ],
            engine: "appleIntelligence"
        )
    }

    @Test("save then load returns equal value")
    func saveLoad() async throws {
        let store = ChatStore()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let history = sampleHistory()
        try await store.save(history, to: url)
        let loaded = try await store.load(from: url)
        #expect(loaded == history)
    }

    @Test("load returns nil when file is absent")
    func loadAbsent() async throws {
        let store = ChatStore()
        let loaded = try await store.load(from: tempURL())
        #expect(loaded == nil)
    }

    @Test("save overwrites existing file")
    func overwrite() async throws {
        let store = ChatStore()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = ChatHistory(messages: [ChatMessage(role: .user, content: "first")])
        let second = ChatHistory(messages: [ChatMessage(role: .user, content: "second")])
        try await store.save(first, to: url)
        try await store.save(second, to: url)
        let loaded = try await store.load(from: url)
        #expect(loaded?.messages.first?.content == "second")
    }

    @Test("delete removes the sidecar so subsequent load is nil")
    func delete() async throws {
        let store = ChatStore()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try await store.save(sampleHistory(), to: url)
        await store.delete(at: url)
        let loaded = try await store.load(from: url)
        #expect(loaded == nil)
    }

    @Test("history without engine decodes cleanly (older sidecar)")
    func decodesWithoutEngine() async throws {
        let store = ChatStore()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let json = """
        { "version": 1, "messages": [] }
        """
        try json.data(using: .utf8)!.write(to: url)
        let loaded = try await store.load(from: url)
        #expect(loaded?.engine == nil)
        #expect(loaded?.messages.isEmpty == true)
    }
}
