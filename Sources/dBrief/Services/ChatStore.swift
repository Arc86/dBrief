import Foundation
import OSLog

/// Loads and saves the `<base>.chat.json` transcript-chat sidecar.
/// Mirrors `InsightsStore`'s actor + atomic-write pattern.
actor ChatStore {
    private let fileManager = FileManager.default

    // Primary URL-based interface
    func load(from url: URL) async throws -> ChatHistory? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ChatHistory.self, from: data)
    }

    func save(_ history: ChatHistory, to url: URL) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(history)
        try data.write(to: url, options: .atomic)
    }

    func delete(at url: URL) async {
        try? fileManager.removeItem(at: url)
    }

    // Convenience Recording-based overloads
    func load(for recording: Recording) async throws -> ChatHistory? {
        guard let url = await MainActor.run(body: { recording.chatSidecarURL }) else { return nil }
        return try await load(from: url)
    }

    func save(_ history: ChatHistory, for recording: Recording) async throws {
        guard let url = await MainActor.run(body: { recording.chatSidecarURL }) else {
            throw ChatStoreError.noSidecarURL
        }
        try await save(history, to: url)
    }
}

enum ChatStoreError: Error {
    case noSidecarURL
}
