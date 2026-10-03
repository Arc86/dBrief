import Foundation
import Testing
import dBriefWire
@testable import dBrief

private func dispatchProfile() -> LiveResourceProfile {
    let request = MLRequest.prewarmWhisper(config: .init(modelName: "large-v3",language: nil,diarizationEnabled: false),refresh: false)
    let key: String
    if case .background(let model) = LiveModelJobAdmission.job(for: request) { key = model }
    else { key = "invalid-whisper-fixture" }
    return .init(id: "test",hardware: "fixture",modelRevision: "asr",chunkMs: 1120,sourceCount: 1,
          qualificationID: "model-free",asrBytes: 500,attributionBytes: nil,headroomBytes: 100,
          concurrentChatModels: ["gemma-4-e4b": 300,key: 400],backgroundWorkQualified: true)
}
private func dispatchRequest() -> LiveResourceRequest {
    .init(profileID: "test",hardware: "fixture",modelRevision: "asr",chunkMs: 1120,sourceCount: 1,attributionRequested: false)
}

private actor DispatchProbe {
    var samples = 0
    var finished: Set<String> = []
    var errors: [String:MLHostError] = [:]
    var firstExitEntered = false
    private var exits = 0
    private var exitWaiter: CheckedContinuation<Void,Never>?
    var firstRetirementReturnEntered = false
    private var retirementReturns = 0
    private var retirementWaiter: CheckedContinuation<Void,Never>?
    private var retirementReleased = false
    func memory() -> LiveResourceMeasurement { samples += 1; return .init(availableBytes: 2000,pressure: .normal) }
    func result(_ name: String,error: Error? = nil) { finished.insert(name); errors[name] = error as? MLHostError }
    func observeExit() async {
        exits += 1
        if exits == 1 { firstExitEntered = true; await withCheckedContinuation { exitWaiter = $0 } }
    }
    func releaseExit() { exitWaiter?.resume(); exitWaiter = nil }
    func holdFirstRetirementReturn() async {
        retirementReturns += 1
        if retirementReturns == 1, !retirementReleased {
            firstRetirementReturnEntered = true
            await withCheckedContinuation { retirementWaiter = $0 }
        }
    }
    func releaseRetirementReturn() { retirementReleased = true; retirementWaiter?.resume(); retirementWaiter = nil }
}

private func dispatchEventually(seconds: Int = 10,_ predicate: @escaping @Sendable () async -> Bool) async -> Bool {
    let end = ContinuousClock.now.advanced(by: .seconds(seconds))
    while ContinuousClock.now < end {
        if await predicate() { return true }
        if Task.isCancelled { return false }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await predicate()
}

@Suite struct LiveModelDispatchTests {
    @Test(arguments: ["completion","test-command"])
    func theConfiguredCLIIsNotLaunchedUntilLiveOwnershipExits(operation: String) async throws {
        let root = URL(fileURLWithPath: "/private/tmp/cli-admission-\(UUID())")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("launched")
        let policy = LiveModelResourcePolicy(profiles: [dispatchProfile()]), probe = DispatchProbe()
        let lease = try await policy.admit(identity: .init(recordingID: UUID(),captureSessionID: UUID()),request: dispatchRequest(),
            measurement: .init(availableBytes: 2000,pressure: .normal))
        await policy.confirmResident(lease)
        let service = LocalCLIService(resourceAdmission: .init(policy: policy,measurement: { await probe.memory() }))
        let config = LocalCLIConfig(command: "printf '%s' 'configured' > '\(marker.path)'; printf '%s' \"$DBRIEF_USER_PROMPT\"",timeoutSeconds: 10)
        let task = Task {
            do {
                let output: String
                if operation == "test-command" { output = try await service.runTest(config: config) }
                else { output = try await service.completeText(systemPrompt: "s",userMessage: "configured route",config: config,stage: .analysis) }
                await probe.result(output)
            } catch { await probe.result("failed",error: error) }
        }
        func cleanup() async {
            task.cancel(); await policy.release(lease); await task.value
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try #require(await dispatchEventually(seconds: 2) {
                await probe.samples > 0 || FileManager.default.fileExists(atPath: marker.path)
            })
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(await policy.jobCount == 0)
            await policy.release(lease); await task.value
            #expect(try String(contentsOf: marker,encoding: .utf8) == "configured")
            #expect(await !probe.finished.contains("failed"))
            if operation == "completion" { #expect(await probe.finished.contains("configured route")) }
            #expect(await policy.jobCount == 0)
            await cleanup()
        } catch { await cleanup(); throw error }
    }

    @Test func aCancelledCLIRunnerKeepsCaptureExcludedUntilItsActualReturn() async throws {
        let policy = LiveModelResourcePolicy(profiles: [dispatchProfile()]), probe = DispatchProbe()
        let service = LocalCLIService(resourceAdmission: .init(policy: policy,measurement: { await probe.memory() }),
            commandRunner: { _,_,_ in await probe.holdFirstRetirementReturn(); return "configured route" })
        let task = Task {
            do { _ = try await service.completeText(systemPrompt: "s",userMessage: "u",
                config: .init(command: "printf '%s' 'old implementation'",timeoutSeconds: 10),stage: .analysis) }
            catch { }
        }
        func cleanup() async { task.cancel(); await probe.releaseRetirementReturn(); await task.value }
        do {
            try #require(await dispatchEventually(seconds: 2) { await probe.firstRetirementReturnEntered })
            #expect(await policy.jobCount == 1)
            task.cancel()
            #expect(await policy.jobCount == 1)
            await #expect(throws: LiveResourceRejection.busy) {
                _ = try await policy.admit(identity: .init(recordingID: UUID(),captureSessionID: UUID()),request: dispatchRequest(),
                    measurement: .init(availableBytes: 2000,pressure: .normal))
            }
            await probe.releaseRetirementReturn(); await task.value
            #expect(await policy.jobCount == 0)
            let capture = try await policy.admit(identity: .init(recordingID: UUID(),captureSessionID: UUID()),request: dispatchRequest(),
                measurement: .init(availableBytes: 2000,pressure: .normal))
            await policy.release(capture); await cleanup()
        } catch { await cleanup(); throw error }
    }

    @Test(arguments: ["dispatch","live-preparation"])
    func anObsoleteExitWaitCannotSkipANewerHeldRetirement(operation: String) async throws {
        let root = URL(fileURLWithPath: "/private/tmp/retirement-phases-\(UUID())")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let counter = root.appendingPathComponent("phase"), exitPrefix = root.appendingPathComponent("exit-")
        let policy = LiveModelResourcePolicy(), probe = DispatchProbe()
        let conn = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),supportBase: root,
            environment: ["STUB_MODE":"retirement-phases","STUB_FLAG_1":counter.path,"STUB_FLAG_2":exitPrefix.path],
            resourceAdmission: .init(policy: policy,measurement: { await probe.memory() }),
            retirementWaitDelivery: { await probe.holdFirstRetirementReturn() })
        var first: Task<Void,Never>?, second: Task<Void,Never>?
        func cleanup() async {
            for phase in 1...10 { try? Data().write(to: URL(fileURLWithPath: exitPrefix.path + String(phase))) }
            await probe.releaseRetirementReturn(); first?.cancel(); second?.cancel()
            await conn.shutdown(); await first?.value; await second?.value
            await conn.prepareForLiveCapture()
            try? FileManager.default.removeItem(at: root)
        }
        do {
            _ = try await conn.call(.prewarmWhisper(config: .default,refresh: false))
            _ = try await conn.call(.isLLMCached)
            await conn.shutdown()
            try Data().write(to: URL(fileURLWithPath: exitPrefix.path + "1"))
            first = Task {
                do {
                    if operation == "dispatch" { _ = try await conn.call(.prewarmWhisper(config: .default,refresh: false)) }
                    else { await conn.prepareForLiveCapture() }
                    await probe.result("first")
                } catch { await probe.result("first",error: error) }
            }
            try #require(await dispatchEventually { await probe.firstRetirementReturnEntered })
            second = Task {
                do { _ = try await conn.call(.prewarmWhisper(config: .default,refresh: false)); await probe.result("second") }
                catch { await probe.result("second",error: error) }
            }
            try #require(await dispatchEventually { await probe.finished.contains("second") })
            _ = try await conn.call(.isLLMCached)
            #expect(try String(contentsOf: counter,encoding: .utf8) == "2")
            await conn.shutdown()
            await probe.releaseRetirementReturn()
            #expect(await !dispatchEventually(seconds: 1) { await probe.finished.contains("first") })
            #expect(try String(contentsOf: counter,encoding: .utf8) == "2")
            try Data().write(to: URL(fileURLWithPath: exitPrefix.path + "2"))
            #expect(await dispatchEventually { await probe.finished.contains("first") })
            #expect(await probe.errors.isEmpty)
            await cleanup()
            #expect(await policy.jobCount == 0)
        } catch { await cleanup(); throw error }
    }

    @Test(arguments: ["cpuAndGPU","cpuAndNeuralEngine","safe-workers","prewarm","download"])
    func aWhisperQualificationCannotAuthorizeAnotherExecutionVariant(variant: String) async throws {
        let config = WhisperRuntimeConfig(modelName: "large-v3",language: nil,diarizationEnabled: false)
        let qualifiedRequest = MLRequest.transcribe(path: "/fixture",initialPrompt: nil,config: config,safeMode: false,unloadAfter: true)
        let qualifiedJob = try #require(LiveModelJobAdmission.job(for: qualifiedRequest))
        guard case .background(let key) = qualifiedJob else { Issue.record("Missing Whisper execution key"); return }
        let profile = LiveResourceProfile(id: "test",hardware: "fixture",modelRevision: "asr",chunkMs: 1120,sourceCount: 1,
            qualificationID: "model-free",asrBytes: 500,attributionBytes: nil,headroomBytes: 100,
            concurrentChatModels: [key:400],backgroundWorkQualified: true)
        let policy = LiveModelResourcePolicy(profiles: [profile])
        let lease = try await policy.admit(identity: .init(recordingID: UUID(),captureSessionID: UUID()),request: dispatchRequest(),
            measurement: .init(availableBytes: 2000,pressure: .normal))
        await policy.confirmResident(lease)
        var other = config
        if variant == "cpuAndGPU" { other.computeUnits = .cpuAndGPU }
        if variant == "cpuAndNeuralEngine" { other.computeUnits = .cpuAndNeuralEngine }
        let request: MLRequest = switch variant {
        case "prewarm": .prewarmWhisper(config: other,refresh: false)
        case "download": .downloadWhisper(config: other)
        default: .transcribe(path: "/fixture",initialPrompt: nil,config: other,safeMode: variant == "safe-workers",unloadAfter: true)
        }
        let otherJob = try #require(LiveModelJobAdmission.job(for: request))
        let admission = LiveModelJobAdmission(policy: policy,measurement: { .init(availableBytes: 2000,pressure: .normal) })
        await #expect(throws: MLHostError.resourceDeferred) { _ = try await admission.acquire(owner: UUID(),job: otherJob,wait: false) }
        let exact = try await admission.acquire(owner: UUID(),job: qualifiedJob,wait: false)
        await policy.releaseJob(exact); await policy.release(lease)
    }
    @Test func changedResidencyCannotAuthorizeDispatchUsingAnEarlierMemorySample() async throws {
        let policy = LiveModelResourcePolicy(profiles: [dispatchProfile()])
        let lease = try await policy.admit(identity: .init(recordingID: UUID(),captureSessionID: UUID()),request: dispatchRequest(),
            measurement: .init(availableBytes: 2000,pressure: .normal))
        let stale = await policy.measurementToken()
        await policy.confirmResident(lease)
        await #expect(throws: LiveResourceRejection.measurementChanged) {
            _ = try await policy.reserveJob(owner: UUID(),job: .localChat(model: "gemma-4-e4b"),
                measurement: .init(availableBytes: 2000,pressure: .normal),token: stale)
        }
        await policy.release(lease)
    }

    @Test func actualChatHelperIsNotLaunchedWhenItsCombinationIsUnqualified() async throws {
        let policy = LiveModelResourcePolicy(profiles: [dispatchProfile()])
        let lease = try await policy.admit(identity: .init(recordingID: UUID(),captureSessionID: UUID()),request: dispatchRequest(),
            measurement: .init(availableBytes: 2000,pressure: .normal))
        let conn = MLHostConnection(binaryURL: URL(fileURLWithPath: "/nonexistent-helper"),supportBase: URL(fileURLWithPath: "/private/tmp"),
            resourceAdmission: .init(policy: policy,measurement: { .init(availableBytes: 2000,pressure: .normal) }))
        let stream = await conn.stream(.chatStream(systemPrompt: "fixture",userMessage: "fixture"))
        do {
            for try await _ in stream {}
            Issue.record("unqualified chat was admitted")
        } catch { #expect(error as? MLHostError == .resourceDeferred) }
        await policy.release(lease)
        await conn.shutdown()
    }

    @Test func completedWarmModelStillOwnsItsPermitUntilActualHelperExit() async throws {
        let policy = LiveModelResourcePolicy(profiles: [dispatchProfile()])
        let conn = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
            supportBase: URL(fileURLWithPath: "/private/tmp"),environment: ["STUB_MODE":"echo"],
            resourceAdmission: .init(policy: policy,measurement: { .init(availableBytes: 2000,pressure: .normal) }))
        _ = try await conn.call(.prewarmWhisper(config: .default,refresh: false))
        #expect(await policy.jobCount == 1)
        _ = try await conn.call(.isLLMCached) // Ordered receipt after prewarm's trailing .finished.
        await conn.prepareForLiveCapture()
        #expect(await policy.jobCount == 0)
        await conn.shutdown()
    }

    @Test func backgroundDispatchWaitsForActualASRReadinessThenRunsOnTheExistingHelper() async throws {
        let policy = LiveModelResourcePolicy(profiles: [dispatchProfile()]), probe = DispatchProbe()
        let lease = try await policy.admit(identity: .init(recordingID: UUID(),captureSessionID: UUID()),request: dispatchRequest(),
            measurement: .init(availableBytes: 2000,pressure: .normal))
        let conn = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
            supportBase: URL(fileURLWithPath: "/private/tmp"),environment: ["STUB_MODE":"echo"],
            resourceAdmission: .init(policy: policy,measurement: { await probe.memory() }))
        let config = WhisperRuntimeConfig(modelName: "large-v3",language: nil,diarizationEnabled: false)
        let request = Task {
            do { _ = try await conn.call(.prewarmWhisper(config: config,refresh: false)); await probe.result("background") }
            catch { await probe.result("background",error: error) }
        }
        try #require(await dispatchEventually { await probe.samples > 0 })
        #expect(await policy.jobCount == 0)
        #expect(await !probe.finished.contains("background"))
        await policy.confirmResident(lease)
        #expect(await dispatchEventually { await probe.finished.contains("background") })
        await request.value
        #expect(await probe.errors["background"] == nil)
        #expect(await probe.samples >= 2)
        await conn.shutdown(); await policy.release(lease)
    }

    @Test func cancelledChatRetainsItsChargeAcrossLiveReleaseAndActualNativeReturn() async throws {
        let policy = LiveModelResourcePolicy(profiles: [dispatchProfile()]), probe = DispatchProbe()
        let flag = URL(fileURLWithPath: "/private/tmp/chat-native-return-\(UUID())")
        defer { try? FileManager.default.removeItem(at: flag) }
        let lease = try await policy.admit(identity: .init(recordingID: UUID(),captureSessionID: UUID()),request: dispatchRequest(),
            measurement: .init(availableBytes: 2000,pressure: .normal))
        await policy.confirmResident(lease)
        let conn = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
            supportBase: URL(fileURLWithPath: "/private/tmp"),environment: ["STUB_MODE":"chat-across-live-stop","STUB_FLAG_1":flag.path],
            resourceAdmission: .init(policy: policy,measurement: { await probe.memory() }))
        let stream = await conn.stream(.chatStream(systemPrompt: "fixture",userMessage: "fixture"))
        let consumer = Task {
            do { for try await _ in stream { await probe.result("first-token") } } catch { }
        }
        try #require(await dispatchEventually { await probe.finished.contains("first-token") })
        consumer.cancel(); await consumer.value
        #expect(await policy.jobCount == 1)
        await policy.release(lease)
        #expect(await policy.jobCount == 1)
        try Data().write(to: flag)
        _ = try await conn.call(.isLLMCached)
        #expect(await policy.jobCount == 1) // Return may leave a cached model.
        await conn.prepareForLiveCapture()
        #expect(await policy.jobCount == 0)
    }

    @Test func delayedOldExitCannotLeakItsCallerOrReleaseTheReplacementPermit() async throws {
        let policy = LiveModelResourcePolicy(), probe = DispatchProbe()
        let flag = URL(fileURLWithPath: "/private/tmp/old-exit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: flag) }
        let conn = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
            supportBase: URL(fileURLWithPath: "/private/tmp"),environment: ["STUB_MODE":"crash-once","STUB_FLAG_1":flag.path],
            resourceAdmission: .init(policy: policy,measurement: { await probe.memory() }),terminationDelivery: { await probe.observeExit() })
        let first = Task {
            do { _ = try await conn.call(.transcribe(path: "/fixture",initialPrompt: nil,config: .default,safeMode: false,unloadAfter: true)); await probe.result("old") }
            catch { await probe.result("old",error: error) }
        }
        func cleanup() async {
            first.cancel(); await probe.releaseExit(); await conn.shutdown(); await first.value
            await conn.prepareForLiveCapture()
        }
        do {
        try #require(await dispatchEventually { await probe.firstExitEntered })
        _ = try await conn.call(.prewarmWhisper(config: .default,refresh: false))
        _ = try await conn.call(.isLLMCached)
        #expect(await dispatchEventually(seconds: 2) { await probe.finished.contains("old") })
        #expect(await dispatchEventually { await policy.jobCount == 1 })
        await probe.releaseExit()
        _ = try await conn.call(.isLLMCached)
        #expect(await policy.jobCount == 1)
        await cleanup()
        #expect(await probe.errors["old"] == .helperCrashed)
        #expect(await dispatchEventually { await policy.jobCount == 0 })
        } catch { await cleanup(); throw error }
    }

    @Test func alreadyWaitingBackgroundJobWakesAfterTheFullRetainedBatchBecomesIdle() async throws {
        let policy = LiveModelResourcePolicy(), probe = DispatchProbe()
        let root = URL(fileURLWithPath: "/private/tmp/dispatch-batch-\(UUID())")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let released = root.appendingPathComponent("released"), waiting = root.appendingPathComponent("waiting")
        let conn = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),supportBase: root,
            environment: ["STUB_MODE":"dispatch-batch","STUB_FLAG_1":released.path,"STUB_FLAG_2":waiting.path],
            resourceAdmission: .init(policy: policy,measurement: { await probe.memory() }))
        let batch = (0..<128).map { index in Task {
            do { _ = try await conn.call(.prewarmWhisper(config: .default,refresh: false)); await probe.result("batch-\(index)") }
            catch { await probe.result("batch-\(index)",error: error) }
        } }
        var successor: Task<Void,Never>?
        func cleanup(_ successor: Task<Void,Never>?) async {
            successor?.cancel(); for task in batch { task.cancel() }
            try? Data().write(to: released)
            await conn.shutdown()
            for task in batch { await task.value }; await successor?.value
            await conn.prepareForLiveCapture()
        }
        do {
        try #require(await dispatchEventually { FileManager.default.fileExists(atPath: waiting.path) })
        #expect(await policy.jobCount == 128)
        let waitingTask = Task {
            do { _ = try await conn.call(.prewarmWhisper(config: .default,refresh: false)); await probe.result("successor") }
            catch { await probe.result("successor",error: error) }
        }
        successor = waitingTask
        try #require(await dispatchEventually { await probe.samples >= 129 })
        #expect(await !probe.finished.contains("successor"))
        try Data().write(to: released)
        #expect(await dispatchEventually(seconds: 3) { await probe.finished.contains("successor") })
        await cleanup(waitingTask)
        #expect(await probe.errors.isEmpty)
        #expect(await dispatchEventually { await policy.jobCount == 0 })
        } catch { await cleanup(successor); throw error }
    }

    @Test(arguments: ["prepare","whisper-speakers","speaker-embeddings","parakeet-speakers"])
    func aSingleModelQualificationCannotAuthorizeAnUnmeasuredComposite(operation: String) async throws {
        let profile = LiveResourceProfile(id: "composite",hardware: "fixture",modelRevision: "asr",chunkMs: 1120,sourceCount: 1,
            qualificationID: "model-free",asrBytes: 500,attributionBytes: nil,headroomBytes: 100,
            concurrentChatModels: ["speakerkit":100,"whisper:large-v3":400,"parakeet:v3+speakerkit":300],backgroundWorkQualified: true)
        let policy = LiveModelResourcePolicy(profiles: [profile])
        let lease = try await policy.admit(identity: .init(recordingID: UUID(),captureSessionID: UUID()),
            request: .init(profileID: "composite",hardware: "fixture",modelRevision: "asr",chunkMs: 1120,sourceCount: 1,attributionRequested: false),
            measurement: .init(availableBytes: 2000,pressure: .normal))
        await policy.confirmResident(lease)
        let request: MLRequest = switch operation {
        case "prepare": .prepareModels
        case "whisper-speakers": .transcribe(path: "/fixture",initialPrompt: nil,
            config: .init(modelName: "large-v3",language: nil,diarizationEnabled: true),safeMode: false,unloadAfter: false)
        case "speaker-embeddings": .diarizeWithEmbeddings(path: "/fixture")
        default: .parakeetTranscribe(path: "/fixture",modelVariant: "v3",diarize: true)
        }
        let job = try #require(LiveModelJobAdmission.job(for: request))
        let admission = LiveModelJobAdmission(policy: policy,measurement: { .init(availableBytes: 2000,pressure: .normal) })
        await #expect(throws: MLHostError.resourceDeferred) { _ = try await admission.acquire(owner: UUID(),job: job,wait: false) }
        await policy.release(lease)
    }

    @Test func releaseBetweenDeferredDecisionAndSubscriptionWakesImmediately() async throws {
        let policy = LiveModelResourcePolicy(profiles: [dispatchProfile()])
        let lease = try await policy.admit(identity: .init(recordingID: UUID(),captureSessionID: UUID()),request: dispatchRequest(),
            measurement: .init(availableBytes: 2000,pressure: .normal))
        let token = await policy.measurementToken()
        await policy.release(lease)
        let updates = await policy.updates(since: token)
        let receipt = await withTaskGroup(of: Bool.self) { group in
            group.addTask { var iterator = updates.makeAsyncIterator(); return await iterator.next() != nil }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            let first = await group.next() ?? false; group.cancelAll(); return first
        }
        #expect(receipt)
    }

    @Test @MainActor func normalPressureWakesActualBackgroundDispatchWithoutAnotherPurgeOrLiveRelease() async throws {
        let state = AppState(liveResourceProfiles: [dispatchProfile()]), policy = state.liveModelResources, probe = DispatchProbe()
        let lease = try await policy.admit(identity: .init(recordingID: UUID(),captureSessionID: UUID()),request: dispatchRequest(),
            measurement: .init(availableBytes: 2000,pressure: .normal))
        await policy.confirmResident(lease)
        let monitor = MemoryPressureMonitor()
        var cleanups = 0, levels: [MemoryPressureLevel] = []
        monitor.registerPressureHandler { level in
            state.memoryPressureLevel = level; levels.append(level)
            await policy.measurementDidChange()
        }
        monitor.registerCleanupHandler { cleanups += 1 }
        await monitor.testTrigger(.warning)
        let conn = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
            supportBase: URL(fileURLWithPath: "/private/tmp"),environment: ["STUB_MODE":"echo"],
            resourceAdmission: .init(policy: policy,measurement: { @MainActor in
                _ = await probe.memory()
                let pressure: LiveResourceMeasurement.Pressure = switch state.memoryPressureLevel {
                case .normal: .normal
                case .warning: .warning
                case .critical: .critical
                }
                return .init(availableBytes: 2000,pressure: pressure)
            }))
        let request = Task {
            do { _ = try await conn.call(.prewarmWhisper(config: .init(modelName: "large-v3",language: nil,diarizationEnabled: false),refresh: false))
                await probe.result("recovered")
            } catch { await probe.result("recovered",error: error) }
        }
        defer { request.cancel(); Task { await conn.shutdown(); await policy.release(lease) } }
        try #require(await dispatchEventually { await probe.samples > 0 })
        #expect(await !probe.finished.contains("recovered"))
        await monitor.testTrigger(.normal)
        #expect(await dispatchEventually { await probe.finished.contains("recovered") })
        await request.value
        #expect(await probe.errors["recovered"] == nil)
        #expect(levels == [.warning,.normal] && cleanups == 1 && monitor.currentLevel == .normal)
        #expect(await policy.reservedBytes == 500)
        await conn.shutdown(); await policy.release(lease)
    }

    @Test @MainActor func actualAppleChatDefersBeforeConstructingANativeSession() async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return }
        let settings = AppSettings(), oldEngine = settings.aiEngine, oldProfiles = settings.profiles
        let oldActive = settings.activeProfileId, oldAutomatic = settings.automaticProfileId, oldOwner = settings.automaticProfileRecordingID
        defer {
            settings.aiEngine = oldEngine; settings.profiles = oldProfiles; settings.activeProfileId = oldActive
            settings.automaticProfileId = oldAutomatic; settings.automaticProfileRecordingID = oldOwner
        }
        let profile = MeetingProfile(name: "Model-free deferred Apple chat")
        settings.profiles = [profile]; settings.activeProfileId = profile.id; settings.aiEngine = .appleIntelligence
        settings.automaticProfileId = nil; settings.automaticProfileRecordingID = nil
        let policy = LiveModelResourcePolicy(profiles: [dispatchProfile()])
        let lease = try await policy.admit(identity: .init(recordingID: UUID(),captureSessionID: UUID()),request: dispatchRequest(),
            measurement: .init(availableBytes: 2000,pressure: .normal))
        let conn = MLHostConnection(binaryURL: URL(fileURLWithPath: "/nonexistent-helper"),supportBase: URL(fileURLWithPath: "/private/tmp"),
            resourceAdmission: .init(policy: policy,measurement: { .init(availableBytes: 2000,pressure: .normal) }))
        let service = TranscriptChatService(transcriptText: "Model-free meeting evidence",speakerLabels: [],appSettings: settings,
            localPlugin: LocalAIPluginService(connection: conn))
        await service.send("What was decided?")
        #expect(service.streamingError == MLHostError.resourceDeferred.localizedDescription)
        #expect(!service.isStreaming && service.messages.first?.role == .user)
        #expect(await policy.jobCount == 0)
        await policy.release(lease); await conn.shutdown()
        #endif
    }
}
