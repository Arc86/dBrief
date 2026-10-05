import Foundation
import dBriefWire

/// Admission wraps existing execution paths; it never chooses another provider.
struct LiveModelJobAdmission: Sendable {
    let policy: LiveModelResourcePolicy
    let measurement: @Sendable () async throws -> LiveResourceMeasurement

    static func live(policy: LiveModelResourcePolicy,state: AppState) -> Self {
        .init(policy: policy,measurement: { @MainActor [weak state] in
            let pressure: LiveResourceMeasurement.Pressure = switch state?.memoryPressureLevel {
            case .normal: .normal
            case .warning: .warning
            case .critical, nil: .critical
            }
            // Free pages are deliberately conservative; stale/failed telemetry
            // cannot grant admission by substituting a model-size estimate.
            let free = MemoryPressureMonitor.getMemoryStats()?.free ?? 0
            return .init(availableBytes: UInt64(max(0,free)),pressure: pressure)
        })
    }

    func acquire(owner: UUID,job: LiveResourceJob,wait: Bool) async throws -> LiveResourceJobLease {
        while true {
            try Task.checkCancellation()
            let token = await policy.measurementToken()
            let current = try await measurement()
            do {
                if let lease = try await policy.reserveJob(owner: owner,job: job,measurement: current,token: token) { return lease }
            } catch LiveResourceRejection.measurementChanged { continue }
            guard wait else { throw MLHostError.resourceDeferred }
            let updates = await policy.updates(since: token)
            var iterator = updates.makeAsyncIterator()
            guard await iterator.next() != nil else { try Task.checkCancellation(); throw MLHostError.resourceDeferred }
        }
    }

    func acquire(owner: UUID,request: MLRequest) async throws -> LiveResourceJobLease? {
        guard let job = Self.job(for: request) else { return nil }
        let wait: Bool = if case .localChat = job { false } else { true }
        return try await acquire(owner: owner,job: job,wait: wait)
    }

    static func job(for request: MLRequest) -> LiveResourceJob? {
        switch request {
        case .chatStream: .localChat(model: "gemma-4-e4b")
        case .analyze, .analyzeStream, .downloadLLM: .background(model: "gemma-4-e4b")
        case .transcribe(_,_,let config,let safeMode,let unloadAfter):
            .background(model: whisperKey(config,operation: "transcribe",workers: safeMode ? 4 : 12,unloadAfter: unloadAfter))
        case .prewarmWhisper(let config,let refresh):
            .background(model: whisperKey(config,operation: "prewarm",refresh: refresh))
        case .downloadWhisper(let config):
            .background(model: whisperKey(config,operation: "download"))
        case .diarize: .background(model: "speakerkit")
        case .diarizeWithEmbeddings: .background(model: "speakerkit+embedding")
        case .prepareModels: .background(model: whisperKey(.default,operation: "prepare") + "+gemma-4-e4b")
        case .parakeetTranscribe(_,let variant,let diarize): .background(model: "parakeet:" + variant + (diarize ? "+speakerkit+embedding" : ""))
        case .downloadParakeet(let variant): .background(model: "parakeet:" + variant)
        case .synthesizeSpeech(_,_,_,_,_,let model,let engine): .background(model: "tts:" + (engine ?? "ttsKit") + ":" + (model ?? "default"))
        default: nil
        }
    }

    /// Length-delimited fields prevent arbitrary model/language names from
    /// aliasing a different measured compute, worker or loading configuration.
    private static func whisperKey(_ config: WhisperRuntimeConfig,operation: String,workers: Int? = nil,
                                   unloadAfter: Bool? = nil,refresh: Bool? = nil) -> String {
        let fields = [operation,config.modelName,config.computeUnits.rawValue,
            config.language == nil ? "automatic" : "specified",config.language ?? "",
            config.diarizationEnabled ? "speakerkit+embedding" : "no-diarization",
            workers.map(String.init) ?? "no-workers",unloadAfter.map(String.init) ?? "no-unload-policy",
            refresh.map(String.init) ?? "no-refresh-policy"]
        return "whisper:" + fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

/// A terminal request may leave a cached model. This receipt survives logical
/// completion and returns its charge only after its exact process has exited.
final class MLNativeJobOwnership: @unchecked Sendable {
    let lease: LiveResourceJobLease
    let process: Process
    private let policy: LiveModelResourcePolicy
    private let inputWriter: LivePipeWriter?
    private let lock = NSLock()
    private var task: Task<Void,Never>?
    init(lease: LiveResourceJobLease, process: Process, policy: LiveModelResourcePolicy, inputWriter: LivePipeWriter? = nil) {
        self.lease = lease; self.process = process; self.policy = policy; self.inputWriter = inputWriter
    }
    deinit { _ = retire() }
    @discardableResult func retire() -> Task<Void,Never> {
        lock.withLock {
            if let task { return task }
            let process = self.process, lease = self.lease, policy = self.policy, inputWriter = self.inputWriter
            let work = Task {
                if process.isRunning { process.terminate() }
                await Task.detached { process.waitUntilExit() }.value
                await inputWriter?.retire().value
                await policy.releaseJob(lease)
            }
            task = work; return work
        }
    }
}
