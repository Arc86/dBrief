import Foundation
import dBriefWire

extension ProcessingPipeline {
    enum RecoveryInputMode: Sendable {
        case export(hasFrozenPlan: Bool, transcribe: Bool)
        case aiRetry
    }
    struct RecoveryInputRequest: Sendable {
        let mode: RecoveryInputMode
        let transcriptURL: URL?
        let richTranscriptURL: URL?
        let transcription: TranscriptionResult?
        let richTranscript: RichTranscript?

        /// The UI validates only paths this request reads. Frozen exports and
        /// memory-backed retry inputs remain usable if unused sidecars move.
        func validatePaths(transcriptURL currentRaw: URL?, richTranscriptURL currentRich: URL?) throws {
            let needsRaw: Bool
            let needsRich: Bool
            switch mode {
            case .export(let frozen, let transcribe):
                guard !frozen, transcribe else { return }
                needsRaw = true; needsRich = true
            case .aiRetry:
                needsRaw = transcription == nil
                needsRich = richTranscript == nil
            }
            guard (!needsRaw || transcriptURL == currentRaw),
                  (!needsRich || richTranscriptURL == currentRich) else { throw CancellationError() }
        }
    }
    struct RecoveredInputs: Sendable {
        let transcription: TranscriptionResult
        let richTranscript: RichTranscript?
        let loadedTranscriptURL: URL?
    }

    /// Export recovery requires canonical inputs only when rendering is still
    /// needed. Explicit AI retry may reuse memory and keeps rich loading optional.
    /// Return one value for atomic, ownership-checked UI publication; never write
    /// or rebuild sidecars while recovering these inputs.
    func recoverInputs(_ request: RecoveryInputRequest,
                       loadRich: @Sendable (URL) async throws -> RichTranscript,
                       validateOwnership: @Sendable () async throws -> Void = {}) async throws -> RecoveredInputs? {
        try await validateRecoveryInputOwner(validateOwnership)
        let retry: Bool
        switch request.mode {
        case .export(let frozen, let transcribe):
            if frozen || !transcribe { return nil }
            retry = false
        case .aiRetry:
            retry = true
        }
        let transcription: TranscriptionResult
        let loadedURL: URL?
        if retry, let inMemory = request.transcription {
            transcription = inMemory
            loadedURL = nil
        } else {
            guard let saved = try loadTranscript(from: request.transcriptURL) else {
                throw TranscriptStoreError.noSidecarURL
            }
            transcription = saved
            loadedURL = request.transcriptURL
        }
        try await validateRecoveryInputOwner(validateOwnership)
        let rich: RichTranscript?
        if retry, let inMemory = request.richTranscript {
            rich = inMemory
        } else {
            do {
                guard let url = request.richTranscriptURL else { throw TranscriptStoreError.noSidecarURL }
                rich = try await loadRich(url)
            } catch {
                try await validateRecoveryInputOwner(validateOwnership)
                if !retry { throw error }
                rich = nil
            }
        }
        try await validateRecoveryInputOwner(validateOwnership)
        return .init(transcription: transcription, richTranscript: rich, loadedTranscriptURL: loadedURL)
    }

    private func validateRecoveryInputOwner(_ validate: @Sendable () async throws -> Void) async throws {
        try Task.checkCancellation()
        try await validate()
        try Task.checkCancellation()
    }
}
