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

    private let fallbackStateHandler: MLProgress.Sink
    nonisolated private var stateHandler: MLProgress.Sink { MLProgress.sink ?? fallbackStateHandler }

    private var loadedVariant: String?
    private var asrManager: AsrManager?

    init(stateHandler: @escaping MLProgress.Sink = { _ in }) {
        self.fallbackStateHandler = stateHandler
    }

    // MARK: - Public

    /// Returns the transcript plus, when the in-memory audio path was used, the
    /// decoded 16 kHz mono samples — the orchestrator reuses them for the
    /// diarization/embedding passes instead of re-decoding the file (samples are
    /// `nil` on the disk-backed long-audio route).
    func transcribe(
        fileURL: URL,
        language: String?,
        modelVariant: String
    ) async throws -> (result: dBriefWire.TranscriptionResult, samples: [Float]?) {
        defer { stateHandler(.idle) }

        let modelInfo = ParakeetModelInfo.find(modelVariant)
        let requiredBytes = Int64(modelInfo.estimatedMemoryMB) * 1_000_000
        guard SystemMemory.hasSufficientMemory(requiredBytes: requiredBytes) else {
            throw ParakeetError.insufficientMemory(
                model: modelInfo.displayName,
                requiredGB: String(format: "%.1f", Double(requiredBytes) / 1_000_000_000)
            )
        }

        let mgr = try await loadManager(for: modelVariant)
        stateHandler(.transcribing)

        Logger.localAI.info("Parakeet: transcription started [\(modelVariant, privacy: .public)]")
        let (result, samples) = try await Self.transcribePadded(mgr, fileURL: fileURL)

        let duration: Double
        if let audioFile = try? AVAudioFile(forReading: fileURL) {
            duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        } else {
            duration = 0
        }

        let segments = Self.buildSegments(from: result.tokenTimings, fullText: result.text, duration: duration)
        let transcription = dBriefWire.TranscriptionResult(
            text: result.text,
            segments: segments,
            language: language ?? "en"
        )
        return (transcription, samples)
    }

    // MARK: - Trailing-silence padding

    /// Trailing silence appended before ASR so the model emits sentence-final
    /// punctuation it would otherwise drop at the sequence boundary (1 second).
    private static let trailingSilenceSamples = 16_000
    /// Above this many samples we hand FluidAudio a file instead of a buffer, so
    /// its memory-efficient disk-backed route runs the inference.
    /// 20 minutes @ 16 kHz.
    static let maxInMemorySamples = 16_000 * 60 * 20

    enum Input {
        /// Padded 16 kHz mono samples, transcribed in memory.
        case samples([Float])
        /// A file for FluidAudio's own file path; delete it afterwards when temporary.
        case file(URL, isTemporary: Bool)
    }

    /// Decode the file to 16 kHz mono and append 1 s of silence. Long audio is
    /// re-written as an exact-length 16 kHz PCM file: FluidAudio's disk-backed
    /// reader trusts `AVAudioFile.length`, which for AAC/MP3 is an estimate from
    /// the container header and can overshoot the decodable frames — it then
    /// fails with `eofErr` at the very end of the file. Its in-memory resampler
    /// (used here) tolerates that. Undecodable files fall through to FluidAudio's
    /// own file path unchanged.
    static func prepareInput(fileURL: URL, maxInMemorySamples: Int = maxInMemorySamples) throws -> Input {
        guard var samples = try? AudioConverter().resampleAudioFile(fileURL) else {
            return .file(fileURL, isTemporary: false)
        }
        samples.reserveCapacity(samples.count + trailingSilenceSamples)
        samples.append(contentsOf: repeatElement(Float(0), count: trailingSilenceSamples))
        guard samples.count > maxInMemorySamples else { return .samples(samples) }
        return .file(try writeTemporaryPCM(samples), isTemporary: true)
    }

    /// Write 16 kHz mono Float32 samples to a temporary CAF (no 4 GB WAV cap).
    private static func writeTemporaryPCM(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbrief-parakeet-\(UUID().uuidString).caf")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        do {
            // Scoped so the file is closed (on deinit) before FluidAudio opens it.
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunk = 16_000 * 60
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else {
                throw ASRError.processingFailed("Could not allocate audio buffer")
            }
            try samples.withUnsafeBufferPointer { all in
                var offset = 0
                while offset < all.count {
                    let count = min(chunk, all.count - offset)
                    buffer.floatChannelData![0].update(from: all.baseAddress! + offset, count: count)
                    buffer.frameLength = AVAudioFrameCount(count)
                    try file.write(from: buffer)
                    offset += count
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    /// Transcribe the prepared input. Samples are `nil` on the file route, which
    /// the orchestrator treats as "re-decode for diarization".
    private static func transcribePadded(_ mgr: AsrManager, fileURL: URL) async throws -> (ASRResult, [Float]?) {
        // FluidAudio 0.15.4 makes the TDT decoder state caller-owned. We do
        // single-shot full-file transcription (not streaming), so a fresh state
        // per call is correct.
        var decoderState = try TdtDecoderState()
        switch try prepareInput(fileURL: fileURL) {
        case .samples(let samples):
            return (try await mgr.transcribe(samples, decoderState: &decoderState), samples)
        case .file(let url, let isTemporary):
            defer { if isTemporary { try? FileManager.default.removeItem(at: url) } }
            return (try await mgr.transcribe(url, decoderState: &decoderState), nil)
        }
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
            for repo in [Repo.parakeetV2, .parakeetV3, .parakeetUltra, .parakeetRedux] {
                ModelHub.clearCache(for: repo, directory: modelsDir)
            }
        }
        Logger.localAI.info("Parakeet: model cache purged")
    }

    func unload() {
        asrManager = nil
        loadedVariant = nil
    }

    /// Download + load the given variant, then unload. Emits download progress
    /// through the request-owned state callback. Unloads on failure too.
    func prepareModel(variant: String) async throws {
        defer { stateHandler(.idle) }
        do {
            _ = try await loadManager(for: variant)
            unload()
        } catch {
            unload()
            throw error
        }
    }

    /// Whether this variant's own model files are in FluidAudio's cache.
    nonisolated func isModelDownloaded(variant: String) -> Bool {
        let version = Self.asrVersion(for: variant)
        return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    /// The FluidAudio model a variant loads. Resolved through the shared catalog,
    /// so unknown or OS-unsupported variants load the same default the UI shows.
    static func asrVersion(for variant: String) -> AsrModelVersion {
        switch ParakeetModelInfo.find(variant).id {
        case "v2": .v2
        case "ultra": .ultra
        case "redux": .redux
        case "phonon2": .phonon2
        default: .v3
        }
    }

    // MARK: - Private

    private func loadManager(for variant: String) async throws -> AsrManager {
        if loadedVariant == variant, let mgr = asrManager {
            return mgr
        }
        asrManager = nil
        loadedVariant = nil

        let version = Self.asrVersion(for: variant)
        Logger.localAI.info("Parakeet: downloading/loading \(variant, privacy: .public)")

        let models = try await AsrModels.downloadAndLoad(
            version: version,
            progressHandler: { [stateHandler] progress in
                // Only a real file transfer is "downloading"; FluidAudio also reports
                // its cached fast path and listing as .downloading(_, totalFiles: 0).
                let stage: DownloadStage = {
                    if case .downloading(_, let total) = progress.phase, total > 0 { return .parakeetModel }
                    return .parakeetModelLoading
                }()
                stateHandler(.downloading(progress: progress.fractionCompleted, stage: stage))
            }
        )

        stateHandler(.downloading(progress: nil, stage: .parakeetModelLoading))

        let mgr = AsrManager()
        try await mgr.loadModels(models)

        self.asrManager = mgr
        self.loadedVariant = variant
        return mgr
    }
}
