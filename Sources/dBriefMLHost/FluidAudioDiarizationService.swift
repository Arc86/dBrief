import dBriefWire
@preconcurrency import FluidAudio
import Foundation
import OSLog

/// Standalone speaker diarization that returns per-speaker **voice embeddings**,
/// powering the speaker-recognition library. Uses FluidAudio's Pyannote +
/// WeSpeaker pipeline (`DiarizerManager`), which — unlike SpeakerKit at this SDK
/// version — exposes an `embedding: [Float]` on every `TimedSpeakerSegment`.
///
/// Engine-agnostic and independent of transcription: the caller maps the
/// returned `DiarizedTurn`s onto transcript segments by time overlap (via
/// `SpeakerMerge`), and matches the embeddings against the library (via the pure
/// `SpeakerRecognizer`). Coexists with `WhisperKitTranscriptionService.diarize`
/// (SpeakerKit), which stays the default when recognition is off.
actor FluidAudioDiarizationService {
    private let stateHandler: @Sendable (LocalAIPluginState) -> Void
    private var manager: DiarizerManager?

    init(stateHandler: @escaping @Sendable (LocalAIPluginState) -> Void) {
        self.stateHandler = stateHandler
    }

    /// Diarize `fileURL` and return speaker turns carrying voice embeddings.
    /// - Parameter onState: progress sink; defaults to the service's own handler.
    ///   The download has no fine-grained callback, so an indeterminate
    ///   "downloading" state is surfaced when the model cache is empty (mirrors
    ///   the SpeakerKit path), then `.diarizing` while the pipeline runs.
    func diarize(
        fileURL: URL,
        onState: (@Sendable (LocalAIPluginState) -> Void)? = nil
    ) async throws -> [DiarizedTurn] {
        let emitState = onState ?? stateHandler
        Logger.localAI.info("FluidAudio diarization (with embeddings) for \(fileURL.lastPathComponent, privacy: .public)")

        let samples: [Float]
        do {
            // Normalize to 16 kHz mono Float32 — the diarizer's expected input.
            samples = try AudioConverter().resampleAudioFile(fileURL)
        } catch {
            throw WireError(kind: .audioLoadFailed, message: error.localizedDescription)
        }

        let mgr = try await loadManager(emitState: emitState)

        emitState(.diarizing)
        let result: DiarizationResult
        do {
            result = try mgr.performCompleteDiarization(samples, sampleRate: 16000)
        } catch {
            throw WireError(kind: .diarizationFailed, message: error.localizedDescription)
        }

        let turns = Self.turns(from: result.segments)
        let speakerCount = Set(turns.map(\.speakerId)).count
        Logger.localAI.info("FluidAudio diarization: \(speakerCount) speakers, \(turns.count) turns")
        return turns
    }

    /// Map FluidAudio segments to our wire turns, relabeling the engine's raw
    /// speaker ids to the familiar "Speaker N" form by first-appearance order so
    /// downstream ordinal participant mapping and UI colors behave as they do for
    /// the SpeakerKit path. The embedding is carried through unchanged.
    static func turns(from segments: [TimedSpeakerSegment]) -> [DiarizedTurn] {
        var labelForRaw: [String: String] = [:]
        var nextIndex = 1
        return segments.map { seg in
            let label: String
            if let existing = labelForRaw[seg.speakerId] {
                label = existing
            } else {
                label = "Speaker \(nextIndex)"
                labelForRaw[seg.speakerId] = label
                nextIndex += 1
            }
            return DiarizedTurn(
                speakerId: label,
                start: Double(seg.startTimeSeconds),
                end: Double(seg.endTimeSeconds),
                embedding: seg.embedding
            )
        }
    }

    func unload() {
        manager = nil
    }

    func purgeModels() throws {
        manager = nil
        let base = try Self.downloadBase()
        try? FileManager.default.removeItem(at: base)
        Logger.localAI.info("FluidAudio diarizer: model cache purged")
    }

    nonisolated func isModelDownloaded() -> Bool {
        guard let base = try? Self.downloadBase(),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: base.path)
        else { return false }
        return !contents.isEmpty
    }

    // MARK: - Private

    private func loadManager(emitState: @Sendable (LocalAIPluginState) -> Void) async throws -> DiarizerManager {
        if let manager { return manager }

        let base = try Self.downloadBase()
        if !isModelDownloaded() {
            emitState(.downloading(progress: nil, stage: .speakerKitModel))
        }
        let models = try await DiarizerModels.downloadIfNeeded(to: base)

        let mgr = DiarizerManager()
        mgr.initialize(models: models)
        self.manager = mgr
        return mgr
    }

    private static func downloadBase() throws -> URL {
        try SupportPaths.subdirectory("FluidDiarizer")
    }
}
