import Foundation
import dBriefWire

extension ProcessingPipeline {
    struct TranscriptFiles: Sendable {
        var read: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
        var write: @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
        var changed: @Sendable () -> Void = { RecordingLibraryChange.notify() }
    }

    enum TranscriptPersistenceError: Error, LocalizedError {
        case missingPath, verificationFailed
        var errorDescription: String? {
            switch self {
            case .missingPath: "Cannot determine the transcript checkpoint path."
            case .verificationFailed: "Transcript checkpoint verification failed."
            }
        }
    }

    /// Missing/unreadable/legacy-corrupt files retain the prior optional lookup
    /// behavior. Cancellation is distinct so callers cannot interpret it as an
    /// invitation to start transcription again.
    func loadTranscript(from url: URL?) throws -> TranscriptionResult? {
        try Task.checkCancellation()
        guard let url else { return nil }
        let data = try? transcriptFiles.read(url)
        try Task.checkCancellation()
        guard let data else { return nil }
        let result = try? JSONDecoder().decode(TranscriptionResult.self, from: data)
        try Task.checkCancellation()
        return result
    }

    /// A successful return acknowledges the complete encoded transcript, including
    /// word timing, speaker embeddings and provenance. Checkpoint advancement is
    /// allowed only after this verified write returns to the still-owning job.
    func saveTranscript(_ result: TranscriptionResult, to url: URL?) throws {
        try Task.checkCancellation()
        defer { transcriptFiles.changed() }
        guard let url else { throw TranscriptPersistenceError.missingPath }
        let data = try JSONEncoder().encode(result)
        try Task.checkCancellation()
        try transcriptFiles.write(data, url)
        try Task.checkCancellation()
        let verified = try transcriptFiles.read(url)
        try Task.checkCancellation()
        guard verified == data else { throw TranscriptPersistenceError.verificationFailed }
    }
}
