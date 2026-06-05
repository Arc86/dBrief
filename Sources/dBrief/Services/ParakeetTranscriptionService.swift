import AVFoundation
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
    ) async throws -> dBrief.TranscriptionResult {
        defer { stateContinuation.yield(.idle) }

        let modelInfo = ParakeetModelInfo.find(modelVariant)
        let requiredBytes = Int64(modelInfo.estimatedMemoryMB) * 1_000_000
        guard MemoryPressureMonitor.hasSufficientMemory(requiredBytes: requiredBytes) else {
            throw ParakeetError.insufficientMemory(
                model: modelInfo.displayName,
                requiredGB: String(format: "%.1f", Double(requiredBytes) / 1_000_000_000)
            )
        }

        let mgr = try await loadManager(for: modelVariant)
        stateContinuation.yield(.transcribing)

        Logger.localAI.info("Parakeet: transcribing \(fileURL.lastPathComponent, privacy: .public) [\(modelVariant, privacy: .public)]")
        let result = try await mgr.transcribe(fileURL)

        let duration: Double
        if let audioFile = try? AVAudioFile(forReading: fileURL) {
            duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        } else {
            duration = 0
        }

        let segment = dBrief.TranscriptionResult.Segment(start: 0, end: duration, text: result.text)
        return dBrief.TranscriptionResult(
            text: result.text,
            segments: [segment],
            language: language ?? "en"
        )
    }

    func purgeModels() throws {
        asrManager = nil
        loadedVariant = nil

        let fm = FileManager.default
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let modelsDir = appSupport.appendingPathComponent("FluidAudio/Models")
            DownloadUtils.clearModelCache(forRepo: .parakeet, directory: modelsDir)
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
