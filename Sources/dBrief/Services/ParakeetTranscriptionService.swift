import Foundation
import dBriefWire

/// In-app proxy for Parakeet transcription, forwarding to the `dBriefMLHost`
/// helper over the shared connection. Parakeet ignores language selection, so
/// the `language` argument is accepted (to match the call site) but not sent.
final class ParakeetTranscriptionService: Sendable {
    private let connection: MLHostConnection
    private let broadcaster = StateBroadcaster()

    /// Fresh subscriber stream per access; survives re-subscription across ops
    /// (see `StateBroadcaster`).
    nonisolated var stateStream: AsyncStream<LocalAIPluginState> { broadcaster.subscribe() }

    init(connection: MLHostConnection) {
        self.connection = connection
        broadcaster.pump { await connection.stateStream(for: .parakeet) }
    }

    func transcribe(fileURL: URL, language: String?, modelVariant: String) async throws -> TranscriptionResult {
        guard case let .transcriptionResult(r) = try await connection.call(
            .parakeetTranscribe(path: fileURL.path, modelVariant: modelVariant)
        ) else { throw WireError(kind: .generic, message: "no transcription") }
        return r
    }

    func prepareModel(variant: String) async throws { _ = try await connection.call(.downloadParakeet(variant: variant)) }
    func purgeModels() async throws { _ = try await connection.call(.purgeParakeet) }
    func isModelDownloaded() async -> Bool {
        guard case let .boolResult(b) = try? await connection.call(.isParakeetCached) else { return false }
        return b
    }
}
