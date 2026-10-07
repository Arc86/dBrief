import Foundation
import dBriefWire

actor ChatIndexStore {
    struct EmptyIndexError: Error {}

    /// Returns nil when absent, undecodable, or its vector payload is misaligned.
    func load(from url: URL) -> ChatIndex? {
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(ChatIndex.self, from: data),
              index.hasConsistentVectorData else { return nil }
        return index
    }

    /// Vector-less (BM25-only fallback) indexes are never persisted.
    func save(_ index: ChatIndex, to url: URL) throws {
        guard index.dims > 0, !index.windows.isEmpty else { throw EmptyIndexError() }
        try JSONEncoder().encode(index).write(to: url, options: .atomic)
    }

    func index(for windows: [TranscriptWindow], at url: URL,
               embed: @Sendable ([String]) async throws -> [[Float]]) async throws -> ChatIndex {
        let model = EmbeddingPrompt.current.id
        if let existing = load(from: url), existing.isValid(for: windows, model: model) {
            return existing
        }
        let vectors = try await embed(windows.map(\.text))
        let index = ChatIndex(windows: windows, vectors: vectors, model: model)
        if index.dims > 0 { try save(index, to: url) }
        return index
    }
}
