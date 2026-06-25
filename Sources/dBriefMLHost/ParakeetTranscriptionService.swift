import AVFoundation
import dBriefWire
@preconcurrency import FluidAudio
import Foundation
import OSLog

// MARK: - Errors

enum ParakeetError: LocalizedError {
    case insufficientMemory(model: String, requiredGB: String)

    var errorDescription: String? {
        switch self {
        case .insufficientMemory(let model, let gb):
            "Not enough memory to load \(model) (requires \(gb) GB)."
        }
    }
}

// MARK: - Service

actor ParakeetTranscriptionService {

    nonisolated let stateStream: AsyncStream<LocalAIPluginState>
    private let stateContinuation: AsyncStream<LocalAIPluginState>.Continuation

    private var loadedVariant: String?
    private var asrManager: AsrManager?

    init() {
        var continuation: AsyncStream<LocalAIPluginState>.Continuation!
        self.stateStream = AsyncStream<LocalAIPluginState> { continuation = $0 }
        self.stateContinuation = continuation
        continuation.yield(.idle)
    }

    // MARK: - Public

    func transcribe(
        fileURL: URL,
        language: String?,
        modelVariant: String
    ) async throws -> dBriefWire.TranscriptionResult {
        defer { stateContinuation.yield(.idle) }

        let modelInfo = ParakeetModelInfo.find(modelVariant)
        let requiredBytes = Int64(modelInfo.estimatedMemoryMB) * 1_000_000
        guard SystemMemory.hasSufficientMemory(requiredBytes: requiredBytes) else {
            throw ParakeetError.insufficientMemory(
                model: modelInfo.displayName,
                requiredGB: String(format: "%.1f", Double(requiredBytes) / 1_000_000_000)
            )
        }

        let mgr = try await loadManager(for: modelVariant)
        stateContinuation.yield(.transcribing)

        Logger.localAI.info("Parakeet: transcribing \(fileURL.lastPathComponent, privacy: .public) [\(modelVariant, privacy: .public)]")
        let result = try await Self.transcribePadded(mgr, fileURL: fileURL)

        let duration: Double
        if let audioFile = try? AVAudioFile(forReading: fileURL) {
            duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        } else {
            duration = 0
        }

        let segments = Self.buildSegments(from: result.tokenTimings, fullText: result.text, duration: duration)
        return dBriefWire.TranscriptionResult(
            text: result.text,
            segments: segments,
            language: language ?? "en"
        )
    }

    // MARK: - Trailing-silence padding

    /// Trailing silence appended before ASR so the model emits sentence-final
    /// punctuation it would otherwise drop at the sequence boundary (1 second).
    private static let trailingSilenceSamples = 16_000
    /// Above this many samples we skip in-memory padding and use FluidAudio's own
    /// (possibly disk-backed) file path, to keep memory bounded on long audio.
    /// 20 minutes @ 16 kHz.
    private static let maxInMemorySamples = 16_000 * 60 * 20

    /// Load the file to 16 kHz mono samples, append 1 s of silence, and transcribe
    /// the padded buffer. Falls back to FluidAudio's file-based path on load failure
    /// or for very long audio (preserving its memory-efficient disk-backed route).
    private static func transcribePadded(_ mgr: AsrManager, fileURL: URL) async throws -> ASRResult {
        // FluidAudio 0.15.4 makes the TDT decoder state caller-owned. We do
        // single-shot full-file transcription (not streaming), so a fresh state
        // per call is correct.
        var decoderState = try TdtDecoderState()
        guard var samples = try? AudioConverter().resampleAudioFile(fileURL),
              samples.count <= maxInMemorySamples
        else {
            return try await mgr.transcribe(fileURL, decoderState: &decoderState)
        }
        samples.append(contentsOf: repeatElement(Float(0), count: trailingSilenceSamples))
        return try await mgr.transcribe(samples, decoderState: &decoderState)
    }

    // MARK: - Segment / word reconstruction

    /// Pause gap (seconds) between words that starts a new segment.
    private static let segmentPauseThreshold = 1.0
    /// Upper bound on a single segment's duration, so long monologues still split.
    private static let maxSegmentDuration = 30.0

    /// Build word-level segments from Parakeet's token timings. Falls back to a
    /// single full-file segment when timings are unavailable (e.g. some
    /// streaming/disk-backed paths), preserving the prior behavior. Word-level
    /// timing is what makes overlap-based speaker diarization meaningful.
    static func buildSegments(
        from tokenTimings: [TokenTiming]?,
        fullText: String,
        duration: Double
    ) -> [dBriefWire.TranscriptionResult.Segment] {
        guard let tokenTimings, !tokenTimings.isEmpty else {
            return [dBriefWire.TranscriptionResult.Segment(start: 0, end: duration, text: fullText)]
        }
        let words = buildWords(from: tokenTimings)
        guard !words.isEmpty else {
            return [dBriefWire.TranscriptionResult.Segment(start: 0, end: duration, text: fullText)]
        }

        var segments: [dBriefWire.TranscriptionResult.Segment] = []
        var bucket: [dBriefWire.TranscriptionResult.Word] = []

        func flush() {
            guard let first = bucket.first, let last = bucket.last else { return }
            segments.append(
                dBriefWire.TranscriptionResult.Segment(
                    start: first.start,
                    end: last.end,
                    text: bucket.map(\.word).joined(separator: " "),
                    words: bucket
                )
            )
            bucket = []
        }

        for word in words {
            if let last = bucket.last, let first = bucket.first {
                let gap = word.start - last.end
                let segDuration = word.end - first.start
                if gap > segmentPauseThreshold || segDuration > maxSegmentDuration {
                    flush()
                }
            }
            bucket.append(word)
        }
        flush()
        return segments
    }

    /// Group SentencePiece tokens into words on the `▁`/space boundary, mirroring
    /// FluidAudio's own word reconstruction (`isWordBoundary` /
    /// `stripWordBoundaryPrefix` are public helpers in FluidAudio).
    static func buildWords(from tokenTimings: [TokenTiming]) -> [dBriefWire.TranscriptionResult.Word] {
        var words: [dBriefWire.TranscriptionResult.Word] = []
        var current = ""
        var wordStart = 0.0
        var wordEnd = 0.0
        var confidences: [Float] = []

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            current = ""
            defer { confidences = [] }
            guard !trimmed.isEmpty else { return }
            let avg = confidences.isEmpty ? nil : Double(confidences.reduce(0, +) / Float(confidences.count))
            words.append(
                dBriefWire.TranscriptionResult.Word(word: trimmed, start: wordStart, end: wordEnd, probability: avg)
            )
        }

        for timing in tokenTimings {
            let token = timing.token
            if token.isEmpty || token == "<blank>" || token == "<pad>" { continue }
            let startsNewWord = isWordBoundary(token) || current.isEmpty
            if startsNewWord, !current.isEmpty { flush() }
            if startsNewWord {
                current = stripWordBoundaryPrefix(token)
                wordStart = timing.startTime
                confidences = [timing.confidence]
            } else {
                current += token
                confidences.append(timing.confidence)
            }
            wordEnd = timing.endTime
        }
        flush()
        return words
    }

    func purgeModels() throws {
        asrManager = nil
        loadedVariant = nil

        let fm = FileManager.default
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let modelsDir = appSupport.appendingPathComponent("FluidAudio/Models")
            DownloadUtils.clearModelCache(forRepo: .parakeetV3, directory: modelsDir)
            DownloadUtils.clearModelCache(forRepo: .parakeetV2, directory: modelsDir)
        }
        Logger.localAI.info("Parakeet: model cache purged")
    }

    func unload() {
        asrManager = nil
        loadedVariant = nil
    }

    /// Download + load the given variant, then unload. Emits download progress
    /// on `stateStream`. Unloads on failure too.
    func prepareModel(variant: String) async throws {
        defer { stateContinuation.yield(.idle) }
        do {
            _ = try await loadManager(for: variant)
            unload()
        } catch {
            unload()
            throw error
        }
    }

    /// Coarse on-disk check: the FluidAudio model cache directory is non-empty.
    nonisolated func isModelDownloaded() -> Bool {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }
        let modelsDir = appSupport.appendingPathComponent("FluidAudio/Models")
        guard let contents = try? fm.contentsOfDirectory(atPath: modelsDir.path) else {
            return false
        }
        return !contents.isEmpty
    }

    // MARK: - Private

    private func loadManager(for variant: String) async throws -> AsrManager {
        if loadedVariant == variant, let mgr = asrManager {
            return mgr
        }
        asrManager = nil
        loadedVariant = nil

        let version: AsrModelVersion = variant == "v2" ? .v2 : .v3
        Logger.localAI.info("Parakeet: downloading/loading \(variant, privacy: .public)")

        let models = try await AsrModels.downloadAndLoad(
            version: version,
            progressHandler: { [stateContinuation] progress in
                let stage: DownloadStage = {
                    if case .compiling = progress.phase { return .parakeetModelLoading }
                    return .parakeetModel
                }()
                stateContinuation.yield(.downloading(progress: progress.fractionCompleted, stage: stage))
            }
        )

        stateContinuation.yield(.downloading(progress: nil, stage: .parakeetModelLoading))

        let mgr = AsrManager()
        try await mgr.loadModels(models)

        self.asrManager = mgr
        self.loadedVariant = variant
        return mgr
    }
}
