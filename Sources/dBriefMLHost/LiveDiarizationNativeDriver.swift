@preconcurrency import CoreML
import CryptoKit
import FluidAudio
import Foundation
import dBriefWire

struct LiveDiarizationNativeConfiguration: Sendable {
    let configuration: LiveDiarizationConfiguration
    init(_ configuration: LiveDiarizationConfiguration) throws {
        guard configuration.isValid else { throw LiveDiarizationNativeError.invalidConfiguration }
        self.configuration = configuration
    }
    var sdk: Nemotron3Config {
        switch configuration.identity.preset {
        case .ultraLow: .ultraLow
        case .veryLow: .veryLow
        case .low: .low
        case .fast: .fast
        case .fast24: .fast24
        case .fast32: .fast32
        case .efficient: .efficient
        case .fast128: .fast128
        }
    }
    func modelConfiguration() -> MLModelConfiguration {
        LiveASRNativePolicy(computeUnits: configuration.identity.computeUnits,allowLowPrecisionGPUAccumulation: false).modelConfiguration()
    }
}
struct LiveDiarizationNativeLoadRequest: Sendable {
    let snapshot: LiveDiarizationReadOnlySnapshot
    let policy: LiveDiarizationNativeConfiguration
    let contract: LiveDiarizationModelContract
}

/// Trusted test seam; no wire value can supply a native object or SDK model.
protocol LiveDiarizationModelObject: AnyObject, Sendable {
    var snapshot: LiveDiarizationReadOnlySnapshot { get }
    func append(_ samples: [Float]) throws -> [LiveDiarizationChunk]
    func finish() throws -> [LiveDiarizationChunk]
}

/// Whole SDK operations have no suspension. Its private native object owns the
/// snapshot until native destruction, including errors and terminal replay.
actor LiveDiarizationOwnedDriver: LiveDiarizationDriving {
    private enum State { case active, finished, failed, closed }
    private var state = State.active
    private var object: (any LiveDiarizationModelObject)?
    private let preset: LiveDiarizationPreset
    private var sampleEnd: Int64 = 0, frameEnd: Int64 = 0
    init(snapshot: LiveDiarizationReadOnlySnapshot,object: any LiveDiarizationModelObject) throws {
        guard object.snapshot === snapshot, snapshot.configuration.isValid else { throw LiveDiarizationNativeError.invalidModel }
        self.object = object; preset = snapshot.configuration.identity.preset
    }
    func append(_ samples: [Float]) throws -> [LiveDiarizationChunk] {
        try Task.checkCancellation()
        guard state == .active, let object else { throw LiveDiarizationNativeError.inactive }
        let end = sampleEnd.addingReportingOverflow(Int64(samples.count))
        guard (1...3_200).contains(samples.count), samples.allSatisfy(\.isFinite), !end.overflow,
              end.partialValue <= Int64.max - 320, end.partialValue - frameEnd*160 <= preset.pendingSampleLimit else {
            state = .failed; throw LiveDiarizationNativeError.invalidInput
        }
        do {
            let chunks = try checked(object.append(samples),sampleEnd: end.partialValue)
            try Task.checkCancellation()
            sampleEnd = end.partialValue; frameEnd += Int64(chunks.reduce(0) { $0+$1.frameCount })
            return chunks
        } catch { state = .failed; throw LiveDiarizationNativeError.failed }
    }
    func finish() throws -> [LiveDiarizationChunk] {
        try Task.checkCancellation()
        if state == .finished { return [] }
        guard state == .active, let object else { throw LiveDiarizationNativeError.inactive }
        state = .finished // Seal before the SDK's terminal operation.
        do {
            let chunks = try checked(object.finish(),sampleEnd: sampleEnd)
            try Task.checkCancellation()
            frameEnd += Int64(chunks.reduce(0) { $0+$1.frameCount }); return chunks
        } catch { state = .failed; throw LiveDiarizationNativeError.failed }
    }
    func shutdown() { state = .closed; object = nil }
    private func checked(_ chunks: [LiveDiarizationChunk],sampleEnd: Int64) throws -> [LiveDiarizationChunk] {
        guard chunks.count <= 64 else { throw LiveDiarizationNativeError.invalidOutput }
        var frames = 0, result: [LiveDiarizationChunk] = []
        for chunk in chunks {
            guard chunk.numSpeakers == 8, chunk.frameCount >= 0, chunk.frameCount <= preset.core*8,
                  chunk.probabilities.count == chunk.frameCount*8,
                  chunk.probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw LiveDiarizationNativeError.invalidOutput }
            if chunk.frameCount == 0 { continue } // Only a genuinely empty SDK tail.
            frames += chunk.frameCount
            guard frames <= preset.maximumBatchFrames else { throw LiveDiarizationNativeError.invalidOutput }
            result.append(chunk)
        }
        let end = frameEnd.addingReportingOverflow(Int64(frames))
        guard !end.overflow, end.partialValue <= (sampleEnd+320)/160 else { throw LiveDiarizationNativeError.invalidOutput }
        return result
    }
    static func load(_ request: LiveDiarizationNativeLoadRequest) throws -> Self {
        guard request.policy.configuration == request.snapshot.configuration,
              request.contract.preset == request.snapshot.configuration.identity.preset,
              request.contract.metadataDigest == Data(SHA256.hash(data: request.snapshot.metadata.metadata)) else { throw LiveDiarizationNativeError.invalidConfiguration }
        let object = try CoreMLDiarizationObject(request)
        return try .init(snapshot: request.snapshot,object: object)
    }
}

/// CoreML bridging is sealed here; only its owning serial actor calls it.
/// Never accepts an externally aliased Nemotron3Models/tensor/state value.
private final class CoreMLDiarizationObject: LiveDiarizationModelObject, @unchecked Sendable {
    let snapshot: LiveDiarizationReadOnlySnapshot
    private var diarizer: Nemotron3Diarizer?
    init(_ request: LiveDiarizationNativeLoadRequest) throws {
        snapshot = request.snapshot
        let directory = try snapshot.validateCurrentPath(), config = request.policy.sdk
        try Task.checkCancellation()
        let model = try MLModel(contentsOf: directory.appendingPathComponent(config.modelFileName),configuration: request.policy.modelConfiguration())
        try request.contract.validate(model.modelDescription)
        try Task.checkCancellation()
        let models = try Nemotron3Models(config: config,model: model,silenceEmbedding: snapshot.metadata.silenceEmbedding)
        diarizer = Nemotron3Diarizer(config: config,models: models)
    }
    deinit { diarizer = nil; withExtendedLifetime(snapshot) {} }
    func append(_ samples: [Float]) throws -> [LiveDiarizationChunk] {
        guard let diarizer else { throw LiveDiarizationNativeError.inactive }
        diarizer.appendAudio(samples)
        return try chunks(diarizer.processBufferedAudio())
    }
    func finish() throws -> [LiveDiarizationChunk] {
        guard let diarizer else { throw LiveDiarizationNativeError.inactive }
        return try chunks(diarizer.finishStream())
    }
    private func chunks(_ values: [Nemotron3ChunkResult]) throws -> [LiveDiarizationChunk] {
        guard values.count <= 64 else { throw LiveDiarizationNativeError.invalidOutput }
        return values.map { .init(frameCount: $0.frameCount,numSpeakers: $0.numSpeakers,probabilities: $0.probabilities) }
    }
}

enum LiveDiarizationNativeLoader {
    typealias Constructor = @Sendable (LiveDiarizationNativeLoadRequest) async throws -> any LiveDiarizationDriving
    private enum Outcome: Sendable { case loaded(any LiveDiarizationDriving), failed(LiveDiarizationNativeError), canceled }
    static func load(_ configuration: LiveDiarizationConfiguration,testingStagingDirectory: URL? = nil,
                     environment: [String:String] = ProcessInfo.processInfo.environment,
                     beforeConstruction: (@Sendable () async -> Void)? = nil,
                     constructor: @escaping Constructor = { try LiveDiarizationOwnedDriver.load($0) }) async throws -> any LiveDiarizationDriving {
        guard !environment.keys.contains(where: { $0.hasPrefix("FLUIDAUDIO_") }) else { throw LiveDiarizationNativeError.invalidConfiguration }
        let policy = try LiveDiarizationNativeConfiguration(configuration)
        try Task.checkCancellation()
        let work = Task.detached(priority: .utility) {
            do {
                try Task.checkCancellation()
                let snapshot = try LiveDiarizationReadOnlySnapshot.open(configuration,testingStagingDirectory: testingStagingDirectory)
                defer { withExtendedLifetime(snapshot) {} }
                let contract = try LiveDiarizationModelContract(metadata: snapshot.metadata.metadata,preset: configuration.identity.preset)
                await beforeConstruction?()
                try Task.checkCancellation(); _ = try snapshot.validateCurrentPath()
                let driver = try await constructor(.init(snapshot: snapshot,policy: policy,contract: contract))
                if Task.isCancelled { await driver.shutdown(); return Outcome.canceled }
                return Outcome.loaded(driver)
            } catch is CancellationError { return Outcome.canceled }
            catch let error as LiveDiarizationNativeError { return Outcome.failed(error) }
            catch { return Outcome.failed(.failed) } // No arbitrary cached Error retains native payloads.
        }
        return try await withTaskCancellationHandler {
            switch await work.value {
            case .loaded(let driver):
                if Task.isCancelled { await driver.shutdown(); throw CancellationError() }
                return driver
            case .canceled: throw CancellationError()
            case .failed(let error): throw error
            }
        } onCancel: { work.cancel() }
    }
}
