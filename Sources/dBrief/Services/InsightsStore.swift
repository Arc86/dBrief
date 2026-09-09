import Foundation
import OSLog

/// Loads and saves the `<base>.insights.json` AI-analysis sidecar.
/// Mirrors `TranscriptStore`'s actor + atomic-write pattern.
actor InsightsStore {
    private let fileManager = FileManager.default

    // Primary URL-based interface
    func load(from url: URL) async throws -> RecordingInsights? {
        try read(from: url)
    }

    private func read(from url: URL) throws -> RecordingInsights? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let insights = try JSONDecoder().decode(RecordingInsights.self, from: data)
        guard insights.version == RecordingInsights.currentVersion else {
            throw InsightsStoreError.unsupportedVersion(insights.version)
        }
        return insights
    }

    func save(_ insights: RecordingInsights, to url: URL) async throws {
        try Task.checkCancellation()
        guard insights.version == RecordingInsights.currentVersion else {
            throw InsightsStoreError.unsupportedVersion(insights.version)
        }
        var updated = insights
        // Generic analysis/edit saves cannot undo a checkbox change from another
        // view. Only the targeted completion API changes that user-owned state.
        if let existing = try read(from: url) {
            updated.completedActionItems = existing.completedActionItems.map {
                Array(Set($0).intersection(updated.actionItems)).sorted()
            }
        } else {
            updated.completedActionItems = updated.completedActionItems.map {
                Array(Set($0).intersection(updated.actionItems)).sorted()
            }
        }
        try write(updated, to: url)
    }

    /// Read, modify and verify synchronously within this actor turn. Awaiting a
    /// public load/save between those steps would permit stale competing writes.
    func setActionCompleted(_ action: String, completed: Bool, at url: URL) throws -> RecordingInsights {
        guard var insights = try read(from: url) else { throw InsightsStoreError.noSidecarURL }
        guard insights.actionItems.contains(action), !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InsightsStoreError.actionChanged
        }
        var keys = insights.completedActions
        if completed { keys.insert(action) } else { keys.remove(action) }
        insights.completedActionItems = keys.sorted()
        try write(insights, to: url)
        return insights
    }

    /// Export changes only its link/title. Read-modify-write in one actor turn
    /// so a separately loaded snapshot cannot replace newer analysis or checks.
    func setExportLink(_ markdownURL: URL?, generatedTitle: String?, at url: URL) throws {
        try Task.checkCancellation()
        guard var insights = try read(from: url) else { return }
        insights.markdownPath = markdownURL?.path
        insights.generatedTitle = generatedTitle
        try Task.checkCancellation()
        try write(insights, to: url)
        try Task.checkCancellation()
    }

    private func write(_ insights: RecordingInsights, to url: URL) throws {
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(insights)
        try Task.checkCancellation()
        try RecordingResultMutation.withWrite(to: url) {
            try Task.checkCancellation()
            try data.write(to: url, options: .atomic)
        }
        guard let verified = try read(from: url), verified == insights else {
            throw InsightsStoreError.verificationFailed
        }
        RecordingLibraryChange.notify()
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
    case actionChanged

    var errorDescription: String? {
        switch self {
        case .noSidecarURL:
            "Cannot determine the analysis sidecar path."
        case .unsupportedVersion(let version):
            "Analysis version \(version) is not supported."
        case .verificationFailed:
            "Analysis could not be verified after saving."
        case .actionChanged:
            "This action changed. Reload the summary before updating its status."
        }
    }
}
