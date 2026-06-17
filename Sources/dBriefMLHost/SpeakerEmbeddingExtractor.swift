import Foundation
import OSLog
@preconcurrency import FluidAudio
import dBriefWire

/// Extracts one 256-dim voice embedding per diarized speaker, using FluidAudio's
/// WeSpeaker embedding model. Lazily loads the model once and reuses it. Runs
/// inside the orchestrator's GPU mutex. Best-effort: any failure yields `[:]`.
actor SpeakerEmbeddingExtractor {
    static let modelTag = "fluidaudio-wespeaker-256"

    private var manager: DiarizerManager?

    private func ensureLoaded() async throws -> DiarizerManager {
        if let manager { return manager }
        // Cache the diarizer models alongside the other FluidAudio models the
        // helper already uses (see ParakeetTranscriptionService's models dir).
        let modelsDir = try SupportPaths.subdirectory("FluidAudio").appendingPathComponent("Models")
        let models = try await DiarizerModels.downloadIfNeeded(to: modelsDir)
        let m = DiarizerManager()
        m.initialize(models: models)
        manager = m
        return m
    }

    /// Per-speaker voiceprints for the diarized `segments` of the audio at
    /// `fileURL`. Returns `[:]` when there are no qualifying speakers or on any
    /// failure (never throws — embeddings are an optional enrichment).
    func embeddings(forAudioAt fileURL: URL, segments: [TranscriptionResult.Segment]) async -> [String: [Float]] {
        do {
            let audio = try AudioConverter().resampleAudioFile(fileURL) // 16 kHz mono [Float]
            let ranges = SpeakerClipRanges.build(segments: segments, totalSamples: audio.count)
            guard !ranges.isEmpty else { return [:] }
            let mgr = try await ensureLoaded()
            var out: [String: [Float]] = [:]
            for (speakerId, rs) in ranges {
                var clip: [Float] = []
                for r in rs { clip.append(contentsOf: audio[r]) }
                guard let emb = try? mgr.extractSpeakerEmbedding(from: clip),
                      emb.contains(where: { $0 != 0 }) else { continue }
                out[speakerId] = emb
            }
            Logger.localAI.info("Extracted \(out.count) speaker embedding(s)")
            return out
        } catch {
            Logger.localAI.error("Speaker embedding extraction failed: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }
}
