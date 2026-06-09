import Foundation
import OSLog

/// Loads and saves the `<base>.insights.json` AI-analysis sidecar.
/// Mirrors `TranscriptStore`'s actor + atomic-write pattern.
actor InsightsStore {
    private let fileManager = FileManager.default

    // Primary URL-based interface
    func load(from url: URL) async throws -> RecordingInsights? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RecordingInsights.self, from: data)
    }

    func save(_ insights: RecordingInsights, to url: URL) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(insights)
        try data.write(to: url, options: .atomic)
    }

    // Convenience Recording-based overloads
    func load(for recording: Recording) async throws -> RecordingInsights? {
        guard let url = await MainActor.run(body: { recording.insightsSidecarURL }) else { return nil }
        return try await load(from: url)
    }

    func save(_ insights: RecordingInsights, for recording: Recording) async throws {
        guard let url = await MainActor.run(body: { recording.insightsSidecarURL }) else {
            throw InsightsStoreError.noSidecarURL
        }
        try await save(insights, to: url)
    }
}

enum InsightsStoreError: Error {
    case noSidecarURL
}
