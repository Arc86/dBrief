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
        // helper already uses (same dir as ParakeetTranscriptionService).
        let modelsDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FluidAudio/Models")
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
            return await embeddings(fromSamples: audio, segments: segments)
        } catch {
            Logger.localAI.error("Speaker embedding extraction failed (decode): \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    /// Same as `embeddings(forAudioAt:)` but reuses already-decoded 16 kHz mono
    /// samples, so callers that decoded the file for transcription don't pay a
    /// second full decode+resample of the recording.
    func embeddings(fromSamples audio: [Float], segments: [TranscriptionResult.Segment]) async -> [String: [Float]] {
        do {
            let speakered = segments.filter { $0.speaker != nil }.count
            let ranges = SpeakerClipRanges.build(segments: segments, totalSamples: audio.count)
            Logger.localAI.info("Embedding pass: \(audio.count) samples, \(speakered) speakered segs, \(ranges.count) qualifying speaker cluster(s)")
            guard !ranges.isEmpty else {
                Logger.localAI.error("Embedding pass produced NO clusters (all speakers < min duration or no speaker segments) — embeddings empty")
                return [:]
            }
            let mgr = try await ensureLoaded()
            var out: [String: [Float]] = [:]
            var skipped: [String] = []
            for (speakerId, rs) in ranges {
                var clip: [Float] = []
                for r in rs { clip.append(contentsOf: audio[r]) }
                let seconds = Double(clip.count) / 16000.0
                do {
                    let emb = try mgr.extractSpeakerEmbedding(from: clip)
                    if emb.contains(where: { $0 != 0 }) {
                        out[speakerId] = emb
                    } else {
                        skipped.append("\(speakerId)(zero-vector, \(String(format: "%.1f", seconds))s)")
                    }
                } catch {
                    skipped.append("\(speakerId)(error: \(error.localizedDescription), \(String(format: "%.1f", seconds))s)")
                }
            }
            if skipped.isEmpty {
                Logger.localAI.info("Extracted \(out.count) speaker embedding(s)")
            } else {
                Logger.localAI.error("Extracted \(out.count) embedding(s); skipped \(skipped.count): \(skipped.joined(separator: ", "), privacy: .public)")
            }
            return out
        } catch {
            Logger.localAI.error("Speaker embedding extraction failed (model load): \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }
}
