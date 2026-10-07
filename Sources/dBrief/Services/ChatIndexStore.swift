import Foundation
import os
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

    /// Vector-less (BM25-only fallback) indexes are never persisted. Like `ChatStore`,
    /// the write goes through the reprocessing publication boundary, and a retired
    /// session (`validity` invalidated) never writes.
    func save(_ index: ChatIndex, to url: URL, validity: RecordingDerivativeValidity? = nil) throws {
        guard index.dims > 0, !index.windows.isEmpty else { throw EmptyIndexError() }
        let data = try JSONEncoder().encode(index)
        try RecordingResultMutation.withWrite(to: url) {
            try Task.checkCancellation()
            if let validity {
                try validity.withValidResult { try data.write(to: url, options: .atomic) }
            } else {
                try data.write(to: url, options: .atomic)
            }
        }
    }

    /// A failed or refused save is non-fatal: the in-memory index is still returned.
    func index(for windows: [TranscriptWindow], at url: URL, validity: RecordingDerivativeValidity? = nil,
               embed: @Sendable ([String]) async throws -> [[Float]]) async throws -> ChatIndex {
        let model = EmbeddingPrompt.current.id
        if let existing = load(from: url), existing.isValid(for: windows, model: model) {
            return existing
        }
        let vectors = try await embed(windows.map(\.text))
        try Task.checkCancellation() // a retired chat session must not write a sidecar
        let index = ChatIndex(windows: windows, vectors: vectors, model: model)
        if index.dims > 0 {
            do { try save(index, to: url, validity: validity) } catch {
                Logger.ai.warning("Chat index save failed; using in-memory index: \(error.localizedDescription, privacy: .public)")
            }
        }
        return index
    }
}
