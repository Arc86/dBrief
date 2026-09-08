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
        let insights = try JSONDecoder().decode(RecordingInsights.self, from: data)
        guard insights.version == RecordingInsights.currentVersion else {
            throw InsightsStoreError.unsupportedVersion(insights.version)
        }
        return insights
    }

    func save(_ insights: RecordingInsights, to url: URL) async throws {
        guard insights.version == RecordingInsights.currentVersion else {
            throw InsightsStoreError.unsupportedVersion(insights.version)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(insights)
        try data.write(to: url, options: .atomic)
        guard let verified = try await load(from: url), verified == insights else {
            throw InsightsStoreError.verificationFailed
        }
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

enum InsightsStoreError: Error, LocalizedError {
    case noSidecarURL
    case unsupportedVersion(Int)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .noSidecarURL:
            "Cannot determine the analysis sidecar path."
        case .unsupportedVersion(let version):
            "Analysis version \(version) is not supported."
        case .verificationFailed:
            "Analysis could not be verified after saving."
        }
    }
}
