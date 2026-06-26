import Foundation

/// Loads and saves the `<base>.spokensummary.json` sidecar. Mirrors
/// `InsightsStore`'s actor + atomic-write pattern.
actor SpokenSummaryStore {
    private let fileManager = FileManager.default

    func load(from url: URL) async throws -> SpokenSummary? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SpokenSummary.self, from: data)
    }

    func save(_ summary: SpokenSummary, to url: URL) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(summary)
        try data.write(to: url, options: .atomic)
    }
}
