import AVFoundation
import dBriefWire
@preconcurrency import FluidAudio
import Foundation
import OSLog

/// Crash-isolated wrapper around FluidAudio's Kokoro (KokoroAne) text-to-speech.
///
/// Second TTS backend alongside `TTSService` (TTSKit / Qwen3). Kokoro is
/// ANE-resident, fast, and per-variant (English / Mandarin / Japanese load
/// different CoreML models), so a single manager is keyed by the loaded variant
/// and re-initialized when the requested voice's variant changes. The orchestrator
/// unloads after every synthesis, so in practice each call loads once.
///
/// Audio is written to a WAV file at `outputPath` (never sent over the pipe — same
/// contract as transcription/Qwen3). Voice ids are passed verbatim to
/// `KokoroAneManager`, which downloads the embedding on demand.
final class KokoroTTSService: @unchecked Sendable {
    private let stateHandler: @Sendable (LocalAIPluginState) -> Void
    private var manager: KokoroAneManager?
    /// Variant of the currently-loaded `manager`, so a language change reloads.
    private var loadedVariant: KokoroAneVariant?

    init(stateHandler: @escaping @Sendable (LocalAIPluginState) -> Void) {
        self.stateHandler = stateHandler
    }

    // MARK: - Public API

    /// Synthesize `text` to a mono WAV at `outputPath`. Loads the model on first
    /// call (or on a variant change). `voice` is a Kokoro voice id (e.g. `af_heart`);
    /// the language/variant is derived from it. `language`/`instruction`/`model` are
    /// accepted for wire symmetry but unused (Kokoro infers language from the voice
    /// and has no style-instruction or model-size control).
    func synthesize(text: String, outputPath: String, voice: String?, language: String?, instruction: String?, model: String?) async throws -> SpeechSynthesisResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WireError(kind: .generic, message: "Kokoro: empty text")
        }
        let voiceID = voice?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedVoice = (voiceID?.isEmpty ?? true) ? KokoroAneConstants.defaultVoice : voiceID!
        let variant = Self.variant(for: resolvedVoice)

        guard variant != .japanese else {
            // The Japanese KokoroAne variant ships no text→IPA frontend
            // (synthesizeDetailed/phonemes(for:) throw); it needs pre-computed
            // IPA. We don't offer Japanese voices, but guard defensively.
            throw WireError(kind: .generic, message: "Kokoro: Japanese voices are not supported.")
        }

        let engine = try await loadManager(variant: variant)

        // KokoroAne caps input at 510 phonemes and does NOT auto-chunk (unlike
        // TTSKit), so a whole summary overflows. Split into phoneme-bounded
        // chunks, synthesize each, and concatenate the samples with a short gap.
        let chunks = try await Self.chunk(trimmed, engine: engine)
        var samples: [Float] = []
        var sampleRate = KokoroAneConstants.sampleRate
        let gap = [Float](repeating: 0, count: KokoroAneConstants.sampleRate / 10) // ~100 ms
        do {
            for (index, chunk) in chunks.enumerated() {
                let result = try await engine.synthesizeDetailed(text: chunk, voice: resolvedVoice)
                sampleRate = result.sampleRate
                if index > 0 { samples.append(contentsOf: gap) }
                samples.append(contentsOf: result.samples)
            }
        } catch {
            Logger.localAI.error("Kokoro generation failed")
            throw WireError(kind: .generic, message: "Kokoro generation failed: \(error.localizedDescription)")
        }

        let url = URL(fileURLWithPath: outputPath)
        do {
            try TTSService.writeWAV(samples: samples, sampleRate: sampleRate, to: url)
        } catch {
            throw WireError(kind: .generic, message: "Kokoro: writing audio failed: \(error.localizedDescription)")
        }
        let duration = sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0
        return SpeechSynthesisResult(
            outputPath: url.path,
            durationSeconds: duration,
            sampleRate: sampleRate
        )
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
        loadedVariant = nil
    }

    /// Delete the cached FluidAudio Kokoro model directory (best-effort).
    func purgeModels() throws {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let modelsDir = appSupport.appendingPathComponent("FluidAudio/Models")
        for repo in [Repo.kokoro, .kokoroAne, .kokoroAneZh, .kokoroAneJa] {
            ModelHub.clearCache(for: repo, directory: modelsDir)
        }
    }

    // MARK: - Chunking

    /// Safe phoneme budget per chunk (margin under `maxPhonemeLength = 510`).
    private static let maxChunkPhonemes = 480

    /// Split `text` into chunks whose phoneme length stays under the KokoroAne
    /// limit. Greedily packs sentences, measuring each candidate via the engine's
    /// own `phonemes(for:)` G2P; a single sentence that still overflows is split
    /// by words. Falls back to the whole text if measuring fails.
    private static func chunk(_ text: String, engine: KokoroAneManager) async throws -> [String] {
        let sentences = splitSentences(text)
        var chunks: [String] = []
        var current = ""

        func phonemeCount(_ s: String) async -> Int {
            ((try? await engine.phonemes(for: s))?.count) ?? s.count
        }

        for sentence in sentences {
            let candidate = current.isEmpty ? sentence : current + " " + sentence
            if await phonemeCount(candidate) <= maxChunkPhonemes {
                current = candidate
                continue
            }
            if !current.isEmpty { chunks.append(current); current = "" }
            if await phonemeCount(sentence) <= maxChunkPhonemes {
                current = sentence
            } else {
                chunks.append(contentsOf: await splitByWords(sentence, engine: engine))
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [text] : chunks
    }

    /// Greedily pack words into phoneme-bounded chunks (last-resort split for a
    /// single sentence longer than the limit).
    private static func splitByWords(_ sentence: String, engine: KokoroAneManager) async -> [String] {
        var chunks: [String] = []
        var current = ""
        for word in sentence.split(separator: " ").map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            let count = ((try? await engine.phonemes(for: candidate))?.count) ?? candidate.count
            if count <= maxChunkPhonemes {
                current = candidate
            } else {
                if !current.isEmpty { chunks.append(current) }
                current = word
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Split on sentence terminators (Latin + CJK), keeping the delimiter.
    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let terminators: Set<Character> = [".", "!", "?", "\n", "。", "！", "？"]
        for char in text {
            current.append(char)
            if terminators.contains(char) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences.isEmpty ? [text] : sentences
    }

    // MARK: - Loading

    /// Maps a Kokoro voice id to its KokoroAne variant by id prefix
    /// (`zf_`/`zm_` → Mandarin, `jf_`/`jm_` → Japanese, else English).
    private static func variant(for voice: String) -> KokoroAneVariant {
        let prefix = voice.prefix(2).lowercased()
        switch prefix {
        case "zf", "zm": return .mandarin
        case "jf", "jm": return .japanese
        default: return .english
        }
    }

    private func loadManager(variant: KokoroAneVariant) async throws -> KokoroAneManager {
        if let manager, loadedVariant == variant { return manager }
        if manager != nil { await unload() }

        stateHandler(.downloading(progress: nil, stage: .kokoroTTSModel))
        let mgr = KokoroAneManager(variant: variant)
        do {
            try await mgr.initialize()
        } catch {
            Logger.localAI.error("Kokoro initialization failed")
            throw WireError(kind: .generic, message: "Kokoro model load failed: \(error.localizedDescription)")
        }
        self.manager = mgr
        self.loadedVariant = variant
        return mgr
    }
}
