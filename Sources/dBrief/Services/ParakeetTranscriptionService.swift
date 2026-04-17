import Foundation
import CoreML
import Accelerate
@preconcurrency import WhisperKit  // for AudioProcessor utility
import OSLog

// MARK: - Errors

enum ParakeetError: LocalizedError {
    case inferenceFailed(String)
    case insufficientMemory(model: String, requiredGB: String)

    var errorDescription: String? {
        switch self {
        case .inferenceFailed(let msg): "Parakeet inference failed: \(msg)"
        case .insufficientMemory(let model, let gb): "Not enough memory to load \(model) (requires \(gb) GB)."
        }
    }
}

// MARK: - Service

actor ParakeetTranscriptionService {

    // HuggingFace repo hosting argmaxinc's Parakeet CoreML conversions.
    // Expected layout per variant: encoder.mlmodelc + ctc_head.mlmodelc
    private static let modelRepo = "argmaxinc/parakeetkit-coreml"

    nonisolated let stateStream: AsyncStream<LocalAIPluginState>
    private let stateContinuation: AsyncStream<LocalAIPluginState>.Continuation

    private let fileManager = FileManager.default
    private var loadedVariant: String?
    private var encoder: MLModel?
    private var ctcHead: MLModel?

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

        Logger.localAI.info("Parakeet: loading audio \(fileURL.lastPathComponent, privacy: .public)")
        let audioArray: [Float]
        do {
            audioArray = try AudioProcessor.loadAudioAsFloatArray(fromPath: fileURL.path)
        } catch {
            throw TranscriptionServiceError.audioLoadFailed(error.localizedDescription)
        }

        let (enc, ctc) = try await loadModels(variant: modelVariant)
        stateContinuation.yield(.transcribing)

        Logger.localAI.info("Parakeet: running inference with \(modelVariant, privacy: .public)")
        let rawText = try runInference(audioArray: audioArray, encoder: enc, ctcHead: ctc)

        let duration = Double(audioArray.count) / 16_000
        let segment = dBrief.TranscriptionResult.Segment(start: 0, end: duration, text: rawText)
        return dBrief.TranscriptionResult(text: rawText, segments: [segment], language: language ?? "en")
    }

    func purgeModels() throws {
        let base = Self.downloadBase
        if fileManager.fileExists(atPath: base.path) {
            try fileManager.removeItem(at: base)
        }
        encoder = nil
        ctcHead = nil
        loadedVariant = nil
        Logger.localAI.info("Parakeet: model cache purged")
    }

    // MARK: - Model Management

    private static var downloadBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dBrief/LocalAIPlugin/Parakeet", isDirectory: true)
    }

    private func modelFolder(variant: String) -> URL {
        Self.downloadBase.appendingPathComponent(variant, isDirectory: true)
    }

    private func isModelCached(variant: String) -> Bool {
        fileManager.fileExists(atPath: modelFolder(variant: variant).appendingPathComponent("encoder.mlmodelc").path)
    }

    private func loadModels(variant: String) async throws -> (MLModel, MLModel) {
        if loadedVariant == variant, let enc = encoder, let ctc = ctcHead {
            return (enc, ctc)
        }
        encoder = nil
        ctcHead = nil
        loadedVariant = nil

        let folder: URL
        if isModelCached(variant: variant) {
            folder = modelFolder(variant: variant)
        } else {
            folder = try await downloadModel(variant: variant)
        }

        stateContinuation.yield(.downloading(progress: nil, stage: .parakeetModelLoading))
        Logger.localAI.info("Parakeet: loading CoreML models from \(folder.path, privacy: .public)")

        let config = MLModelConfiguration()
        config.computeUnits = .all
        let enc = try MLModel(contentsOf: folder.appendingPathComponent("encoder.mlmodelc"), configuration: config)
        let ctc = try MLModel(contentsOf: folder.appendingPathComponent("ctc_head.mlmodelc"), configuration: config)
        self.encoder = enc
        self.ctcHead = ctc
        self.loadedVariant = variant
        return (enc, ctc)
    }

    private func downloadModel(variant: String) async throws -> URL {
        Logger.localAI.info("Parakeet: downloading \(variant, privacy: .public) from \(Self.modelRepo, privacy: .public)")
        return try await WhisperKit.download(
            variant: variant,
            downloadBase: Self.downloadBase,
            from: Self.modelRepo,
            progressCallback: { [stateContinuation] progress in
                stateContinuation.yield(.downloading(progress: progress.fractionCompleted, stage: .parakeetModel))
            }
        )
    }

    // MARK: - Inference

    // Assumes NeMo → CoreML export format:
    //   encoder inputs:  "processed_signal" [1, 80, T], "processed_signal_length" [1] int32
    //   encoder output:  "encoded" [1, D, T']
    //   ctc_head inputs: "encoded" [1, D, T'], "encoded_len" [1] int32
    //   ctc_head output: "log_probs" [1, T', vocab_size]
    private func runInference(audioArray: [Float], encoder: MLModel, ctcHead: MLModel) throws -> String {
        let melSpec = computeLogMelSpectrogram(audioArray)
        let T = melSpec.count
        guard T > 0 else { return "" }

        var flatMel = [Float](repeating: 0, count: 80 * T)
        for (t, frame) in melSpec.enumerated() {
            for (m, v) in frame.enumerated() { flatMel[m * T + t] = v }
        }
        guard let melArray = try? MLMultiArray(shape: [1, 80, NSNumber(value: T)], dataType: .float32) else {
            throw ParakeetError.inferenceFailed("Failed to allocate mel array")
        }
        flatMel.withUnsafeBytes { melArray.dataPointer.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }

        let signalLen = try MLMultiArray(shape: [1], dataType: .int32)
        signalLen[0] = NSNumber(value: T)

        let encoderOutput = try encoder.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
            "processed_signal": MLFeatureValue(multiArray: melArray),
            "processed_signal_length": MLFeatureValue(multiArray: signalLen),
        ]))

        guard let encoded = encoderOutput.featureValue(for: "encoded")?.multiArrayValue else {
            throw ParakeetError.inferenceFailed("Encoder produced no 'encoded' output")
        }

        let encLen = try MLMultiArray(shape: [1], dataType: .int32)
        encLen[0] = NSNumber(value: encoded.shape[2].intValue)

        let ctcOutput = try ctcHead.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
            "encoded": MLFeatureValue(multiArray: encoded),
            "encoded_len": MLFeatureValue(multiArray: encLen),
        ]))

        guard let logProbs = ctcOutput.featureValue(for: "log_probs")?.multiArrayValue else {
            throw ParakeetError.inferenceFailed("CTC head produced no 'log_probs' output")
        }

        return greedyCTCDecode(logProbs: logProbs)
    }

    // MARK: - Log-Mel Spectrogram
    // 80 filters, 25 ms window (400 samples), 10 ms hop (160 samples), 16 kHz — NeMo defaults.
    // FFT uses 512 (next power-of-2 ≥ 400) as required by vDSP_DFT_zop_CreateSetup.

    private func computeLogMelSpectrogram(_ audio: [Float]) -> [[Float]] {
        let windowLength = 400      // 25 ms @ 16 kHz
        let hopLength = 160         // 10 ms @ 16 kHz
        let fftSize = 512           // next power-of-2 ≥ windowLength (required by vDSP DFT)
        let halfFFT = fftSize / 2 + 1
        let numFrames = audio.count > windowLength ? (audio.count - windowLength) / hopLength + 1 : 0
        guard numFrames > 0 else { return [] }

        var window = [Float](repeating: 0, count: windowLength)
        vDSP_hann_window(&window, vDSP_Length(windowLength), Int32(vDSP_HANN_NORM))

        let melFilters = buildMelFilterbank(nMels: 80, halfFFT: halfFFT, fftSize: fftSize, sampleRate: 16_000)

        guard let fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), vDSP_DFT_Direction.FORWARD) else { return [] }
        defer { vDSP_DFT_DestroySetup(fftSetup) }

        var realIn  = [Float](repeating: 0, count: fftSize)
        var imagIn  = [Float](repeating: 0, count: fftSize)
        var realOut = [Float](repeating: 0, count: fftSize)
        var imagOut = [Float](repeating: 0, count: fftSize)
        var count = Int32(80)

        return (0..<numFrames).map { frameIdx in
            let start = frameIdx * hopLength
            // Zero-pad to fftSize; copy windowLength samples with Hann weighting
            realIn = [Float](repeating: 0, count: fftSize)
            let copyLen = min(windowLength, audio.count - start)
            for i in 0..<copyLen { realIn[i] = audio[start + i] * window[i] }
            imagIn = [Float](repeating: 0, count: fftSize)
            vDSP_DFT_Execute(fftSetup, &realIn, &imagIn, &realOut, &imagOut)

            var power = [Float](repeating: 0, count: halfFFT)
            for k in 0..<halfFFT { power[k] = realOut[k] * realOut[k] + imagOut[k] * imagOut[k] }

            var melEnergies = [Float](repeating: 0, count: 80)
            for m in 0..<80 {
                var energy: Float = 0
                vDSP_dotpr(melFilters[m], 1, power, 1, &energy, vDSP_Length(halfFFT))
                melEnergies[m] = max(energy, 1e-10)
            }

            var logMel = [Float](repeating: 0, count: 80)
            vvlogf(&logMel, &melEnergies, &count)
            return logMel
        }
    }

    private func buildMelFilterbank(nMels: Int, halfFFT: Int, fftSize: Int, sampleRate: Int) -> [[Float]] {
        func hzToMel(_ hz: Float) -> Float { 2595 * log10(1 + hz / 700) }
        func melToHz(_ mel: Float) -> Float { 700 * (pow(10, mel / 2595) - 1) }

        let melMin = hzToMel(0)
        let melMax = hzToMel(Float(sampleRate) / 2)
        let melPoints = (0..<(nMels + 2)).map { i in
            melToHz(melMin + Float(i) * (melMax - melMin) / Float(nMels + 1))
        }
        let fftFreqs = (0..<halfFFT).map { Float($0) * Float(sampleRate) / Float(fftSize) }

        return (0..<nMels).map { m in
            var filter = [Float](repeating: 0, count: halfFFT)
            let lower = melPoints[m], center = melPoints[m + 1], upper = melPoints[m + 2]
            for k in 0..<halfFFT {
                let f = fftFreqs[k]
                if f >= lower && f <= center { filter[k] = (f - lower) / (center - lower) }
                else if f > center && f <= upper { filter[k] = (upper - f) / (upper - center) }
            }
            return filter
        }
    }

    // MARK: - Greedy CTC Decode
    // Parakeet 0.6B uses a 128-character vocab; token 0 = blank, tokens 1–127 = ASCII.

    private func greedyCTCDecode(logProbs: MLMultiArray) -> String {
        // logProbs shape: [1, T', vocab_size]
        let timeSteps = logProbs.shape[1].intValue
        let vocabSize = logProbs.shape[2].intValue
        // Use strides from the array to handle any internal padding CoreML may add.
        let stride1 = logProbs.strides[1].intValue  // elements between timesteps
        let stride2 = logProbs.strides[2].intValue  // elements between vocab entries
        let ptr = logProbs.dataPointer.assumingMemoryBound(to: Float32.self)

        var decoded = [Int]()
        var lastToken = 0

        for t in 0..<timeSteps {
            let base = t * stride1
            var bestIdx = 0
            var bestVal = ptr[base]
            for v in 1..<vocabSize {
                let val = ptr[base + v * stride2]
                if val > bestVal { bestVal = val; bestIdx = v }
            }
            if bestIdx != 0 && bestIdx != lastToken { decoded.append(bestIdx) }
            lastToken = bestIdx
        }

        return String(decoded.compactMap { id -> Character? in
            guard id > 0, id < 128, let scalar = Unicode.Scalar(id) else { return nil }
            return Character(scalar)
        }).trimmingCharacters(in: .whitespaces)
    }
}
