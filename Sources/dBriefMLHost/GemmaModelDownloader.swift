import Foundation
import dBriefWire
import MLXLMCommon

/// Captures the request's sink before the Hub SDK invokes callbacks on its own tasks.
struct GemmaModelDownloader: Downloader {
    let base: any Downloader
    let stateHandler: MLProgress.Sink

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        stateHandler(.downloading(progress: nil, stage: .llmModelPreparing))
        let directory = try await base.download(
            id: id, revision: revision, matching: patterns, useLatest: useLatest
        ) { progress in
            let fraction = progress.fractionCompleted
            let value = progress.totalUnitCount > 0 && fraction.isFinite ? min(1, max(0, fraction)) : nil
            stateHandler(.downloading(progress: value, stage: .llmModel))
            progressHandler(progress)
        }
        // Hub can return a partially downloaded directory when cancelled.
        try Task.checkCancellation()
        stateHandler(.downloading(progress: nil, stage: .llmModelLoading))
        return directory
    }
}
