import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import dBriefWire
@testable import dBrief

private actor ACGate {
    private(set) var entered = false
    private var open = false
    private var waiters: [CheckedContinuation<Void,Never>] = []
    func hold() async { entered = true; if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; let w = waiters; waiters = []; for c in w { c.resume() } }
}
@MainActor private func ACuntil(_ body: @MainActor () async -> Bool) async -> Bool {
    let end = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < end { if await body() { return true }; try? await Task.sleep(for: .milliseconds(2)) }
    return await body()
}
private struct ACAssets: Sendable {
    let root: URL, source: URL, staging: URL
    let identity: LiveDiarizationIdentity
    init(extraFiles: [String: Data] = [:]) throws {
        root = URL(fileURLWithPath: "/private/tmp/capture-attribution-\(UUID())")
        source = root.appendingPathComponent("source"); staging = root.appendingPathComponent("staging")
        let model = LiveDiarizationPreset.low.modelFileName
        var bits = Float(0.375).bitPattern.littleEndian
        let scalar = withUnsafeBytes(of: &bits) { Data($0) }
        let embedding = (0..<512).reduce(into: Data()) { data, _ in data.append(scalar) }
        var files: [String: Data] = [model+"/metadata.json":Data("{}".utf8),model+"/model.mil":Data("fixture".utf8),
                     model+"/weights/weight.bin":Data([1,2,3]),"learnable_sil_emb.bin":embedding,
                     ".fluidaudio-nemotron3-weights":Data(LiveDiarizationIdentity.currentModelRevision.utf8)]
        files.merge(extraFiles) { _, replacement in replacement }
        var directories = Set<String>()
        for file in files.keys {
            let components = file.split(separator: "/")
            for count in 1..<components.count { directories.insert(components.prefix(count).joined(separator: "/")) }
        }
        try FileManager.default.createDirectory(at: staging,withIntermediateDirectories: true,attributes: [.posixPermissions:0o700])
        for (rel,bytes) in files { let p = source.appendingPathComponent(rel); try FileManager.default.createDirectory(at: p.deletingLastPathComponent(),withIntermediateDirectories: true); try bytes.write(to:p) }
        var hash = SHA256(); hash.update(data: Data("dBrief.DiarizationAssets.v1\0".utf8))
        for path in (Array(files.keys)+Array(directories)).sorted() {
            let bytes=files[path], name=Data(path.utf8); hash.update(data: Data([bytes == nil ? 0 : 1]))
            var n=UInt32(name.count).littleEndian, size=UInt64(bytes?.count ?? 0).littleEndian
            withUnsafeBytes(of:&n) { hash.update(bufferPointer:$0) };hash.update(data:name)
            withUnsafeBytes(of:&size) { hash.update(bufferPointer:$0) }; if let bytes { hash.update(data:Data(SHA256.hash(data:bytes))) }
        }
        identity = .init(modelRevision:LiveDiarizationIdentity.currentModelRevision,
                         modelFingerprint:hash.finalize().map { String(format:"%02x",$0) }.joined(),
                         preset:.low,computeUnits:.cpuOnly)
    }
    static func inventoryFiles(_ kind: String?) -> [String: Data] {
        guard let kind else { return [:] }
        var result: [String: Data] = [:]
        var parent = LiveDiarizationPreset.low.modelFileName + "/weights"
        for level in 0..<(kind == "deep" ? 4 : 1) {
            for index in 0..<(kind == "deep" ? 18 : 60) {
                result[parent + "/z-" + String(format: "%03d", index) + String(repeating: "w", count: 210) + ".bin"] = Data([UInt8(level + 1)])
            }
            parent += "/a"
        }
        return result
    }
    func assets(_ budget: LiveASRStagingBudget, probe: LiveASRModelAssets.Probe? = nil) throws -> LiveDiarizationModelAssets {
        try .init(sourceDirectory:source,identity:identity,budget:budget,testingStagingDirectory:staging,probe:probe)
    }
}
@MainActor private final class ACCapture {
    let asr: ASRAssetsFixture, diar: ACAssets
    let policy: LiveModelResourcePolicy, registry: LiveRecordingSessionRegistry
    let staging = LiveASRStagingBudget()
    let prepared: CaptureLiveDerivative.Prepared
    let entry: LiveRecordingSessionRegistry.Entry
    let connection: MLHostConnection
    let output: AsyncStream<LiveAudioBuffer>.Continuation
    let microphoneOutput: AsyncStream<LiveAudioBuffer>.Continuation?
    var rawStart = 0, microphoneStart = 0
    let rawEpoch = UUID()
    let flag: URL
    init(copyGate: ACGate? = nil, ackGate: ACGate? = nil, evaluationGate: ACGate? = nil, claimGate: ACGate? = nil,
         available: UInt64 = 2000, workingBudget: LiveRecordingPayloadBudget? = nil,
         labelsEnabled: Bool = true, mode: String = "live-capture-attribution", missingOptional: Bool = false, sources: [LiveSource] = [.system], inventory: String? = nil, optionalTransportAvailable: Bool = true,
         publicationGate: ACGate? = nil, publicationPhase: String = "registration") throws {
        asr = try ASRAssetsFixture();diar = try ACAssets(extraFiles: ACAssets.inventoryFiles(inventory));flag=diar.root.appendingPathComponent("retired")
        policy = .init(profiles:[.init(id:"capture",hardware:"fixture",modelRevision:"fixture-asr",chunkMs:1120,sourceCount:sources.count,
            qualificationID:"model-free",asrBytes:500,attributionBytes:40,headroomBytes:100,concurrentChatModels:[:],
            backgroundWorkQualified:false,asr:ASRAssetsFixture.identity(),diarization:diar.identity)])
        registry = .init(artifactRoot:diar.root.appendingPathComponent("history"),payloadBudget:workingBudget)
        connection = .init(binaryURL:URL(fileURLWithPath:".build/debug/dBriefMLHostStub"),supportBase:diar.root,
            environment:["STUB_MODE":mode,"STUB_FLAG_2":flag.path],role:.live,liveEventLimits:.recording,
            testingAfterDiarizationClaim: { await claimGate?.hold() })
        let asr=asr,diar=diar,staging=staging,connection=connection
        let admission=LiveModelJobAdmission(policy:policy,measurement:{ .init(availableBytes:available,pressure:.normal) })
        let factory=LiveRecordingFactory(registry:registry,admission:admission,makeTransport:{ _ in
                var transport = LiveASRTransport.live(connection)
                if !optionalTransportAvailable { transport.openDiarization = nil;transport.diarizationControl = nil;transport.sealDiarization = nil }
                return transport
            },makeStoreAccess:{ store in
                .init(admit: { event in
                    let blocked: Bool
                    switch event.payload {
                    case .progress(let progress): blocked = progress.capturedSampleEnd >= (publicationPhase == "registration" ? 1 : 1_280)
                    default: blocked = false
                    }
                    if blocked, let publicationGate { await publicationGate.hold();return .rejected(.capacity) }
                    return await store.admit(event)
                })
            },
            makeASRAssets:{ selected in try asr.assets(budget:staging,identity:selected.identity) },
            makeDiarizationAssets:{ _ in
                if missingOptional { throw LiveProtocolError.unavailable }
                return try diar.assets(staging,probe:{ point,_ in if point == .afterCreateDirectory,let copyGate { await copyGate.hold() } })
            },attributionHooks:.init(afterRegistration:{ _,_ in await ackGate?.hold() },beforeEvaluation:{ await evaluationGate?.hold() }))
        let id=UUID();var request=CaptureCoordinator.Request(id:id,startedAt:Date(),liveTranscription:true,language:"auto",
            privacyScope:.init(recordingID:id,store:.init(gapDirectoryURL:diar.root.appendingPathComponent("gaps")),pendingRootURL:diar.root.appendingPathComponent("privacy")))
        request.liveEngine = .nemotron
        request.liveSpeakerLabelsEnabled = labelsEnabled
        request.nemotronSelection = .init(profileID:"capture",hardware:"fixture",sourceDirectory:asr.source,
            identity:ASRAssetsFixture.identity(),language:.auto,chunkMs:1120,sources:sources,captureQualified:true,
            diarization:.init(sourceDirectory:diar.source,identity:diar.identity))
        guard let p=factory.prepare(request),let e=registry.entry(recordingID:id) else { throw LiveProtocolError.invalidConfiguration }
        prepared=p;entry=e
        let(stream,out)=AsyncStream<LiveAudioBuffer>.makeStream();output=out
        if sources.contains(.microphone) {
            let (mic, micOut) = AsyncStream<LiveAudioBuffer>.makeStream(); microphoneOutput = micOut
            p.session.register(.init(mic:mic,system:stream,language:"auto"))
        } else { microphoneOutput = nil; p.session.register(.init(mic:nil,system:stream,language:"auto")) }
    }
    var core: LiveCaptureSessionCoordinator { entry.coordinator! }
    func feed(_ frames: Int = 640, source: LiveSource = .system) throws {
        let format=try #require(AVAudioFormat(standardFormatWithSampleRate:16000,channels:1))
        let buffer=try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(frames)))
        buffer.frameLength=AVAudioFrameCount(frames);for i in 0..<frames { buffer.floatChannelData![0][i]=0.25 }
        let metadata=LiveAudioMetadata(sourceEpoch:rawEpoch,role:source == .system ? .system : .mic,timestamp:.unavailable,
            emittedFrames:.init(startFrame:Int64(source == .system ? rawStart : microphoneStart),frameCount:Int64(frames),sampleRate:16000),writeOutcome:.failed,converter:nil)
        let ticket=try #require(prepared.ingress.reserveRaw(source:source,metadata:metadata,frames:frames,rate:16000,bytes:frames*4,format:format))
        if source == .system { rawStart += frames; output.yield(.init(buffer,metadata:metadata,ingress:ticket)) }
        else { microphoneStart += frames; microphoneOutput?.yield(.init(buffer,metadata:metadata,ingress:ticket)) }
    }
    func commit() async throws {
        let state=try #require(await core.streamState(source:.system))
        #expect(await core.requestUtteranceBoundary(scope:state.scope))
    }
    func stop() async { prepared.session.beginClosing();output.finish();microphoneOutput?.finish();await prepared.session.hardwareDidClose() }
    func clean() async {
        prepared.session.expire();output.finish();microphoneOutput?.finish();await connection.shutdownLiveAndWaitForExit()
        _=await ACuntil { await self.policy.reservedBytes == 0 && self.staging.usage.workers == 0 && self.staging.usage.roots == 0 }
        asr.remove();try? FileManager.default.removeItem(at:diar.root)
    }
}
private actor ACMeasurement {
    private var pressure: LiveResourceMeasurement.Pressure = .normal
    func set(_ value: LiveResourceMeasurement.Pressure) { pressure = value }
    func snapshot() -> LiveResourceMeasurement { .init(availableBytes:2000,pressure:pressure) }
}
@MainActor @Suite struct LiveCaptureAttributionTests {
    @Test func selectedOptionalIdentityDoesNotGrantPermissionOrChangeMandatoryProfileAdmission() async throws {
        let f = try ACCapture(labelsEnabled: false); defer { Task { await f.clean() } }
        #expect(f.prepared.ingress.input.diarization == nil)
        #expect(await ACuntil { await f.core.readySources == [.system] })
        #expect(await f.policy.reservedBytes == 500)
        let working = await f.core.attributionWorkingBytes
        let staged = try FileManager.default.contentsOfDirectory(atPath: f.diar.staging.path)
        #expect(staged.isEmpty && working == 0)
        #expect(!f.core.attributionContextWasAcknowledged)
        try f.feed()
        #expect(await ACuntil { (await f.entry.store.checkpoint()).lanes.first?.progress.effectiveASRConsumedSampleEnd ?? 0 >= 640 })
        try await f.commit()
        #expect(await ACuntil { !(await f.entry.store.checkpoint()).segments.isEmpty })
        let checkpoint = await f.entry.store.checkpoint()
        #expect(checkpoint.segments.allSatisfy { $0.diarizerContextID == nil } && checkpoint.annotations.isEmpty)
        await f.stop(); #expect(await ACuntil { await f.policy.reservedBytes == 0 })
    }
    @Test func lateOwnedCopyDoesNotDelayMandatoryCaptureOrReleaseItsOriginalWorkOnStop() async throws {
        let gate=ACGate();let f=try ACCapture(copyGate:gate)
        defer { Task { await gate.release();await f.clean() } }
        #expect(await ACuntil { let ready = await f.core.readySources; return await gate.entered && ready == [.system] })
        #expect(f.staging.usage.workers == 1)
        try f.feed();#expect(await ACuntil { (await f.entry.store.checkpoint()).lanes.first?.progress.capturedSampleEnd ?? 0 >= 640 })
        try await f.commit();#expect(await ACuntil { !(await f.entry.store.checkpoint()).segments.isEmpty })
        let stop=Task { await f.stop() };await stop.value
        #expect(await f.policy.reservedBytes > 0)
        #expect(f.staging.usage.workers == 1)
        #expect(f.registry.reservedPayloadBytes >= LiveRecordingArtifactOwner.reservationBytes + LiveAttributionWorkingSet.limit)
        await gate.release()
        #expect(await ACuntil { await f.policy.reservedBytes == 0 && f.staging.usage.workers == 0 && f.staging.usage.roots == 0 })
    }
    @Test func heldPostRegistrationAckAllowsTextAndSynchronousStopPreventsItsLaterDispatch() async throws {
        let gate=ACGate();let f=try ACCapture(ackGate:gate)
        defer { Task { await gate.release();await f.clean() } }
        #expect(await ACuntil { await gate.entered })
        try f.feed();#expect(await ACuntil { (await f.entry.store.checkpoint()).lanes.first?.progress.effectiveASRConsumedSampleEnd ?? 0 >= 640 })
        try await f.commit();#expect(await ACuntil { !(await f.entry.store.checkpoint()).segments.isEmpty })
        let before=await f.entry.store.checkpoint();#expect(before.segments.allSatisfy { $0.diarizerContextID == nil })
        f.prepared.session.beginClosing()
        #expect(!f.core.attributionPublicationIsActive)
        #expect(!f.core.attributionContextWasAcknowledged)
        await gate.release();await f.stop()
        #expect(!f.core.attributionContextWasAcknowledged)
        #expect(await ACuntil { await f.policy.reservedBytes == 0 })
        #expect((await f.entry.store.checkpoint()).segments == before.segments)
        #expect(await f.connection.diarizationPendingCount == 0)
    }
    @Test func actualContextPosteriorUnknownAnnotationsAndFrozenBasisPreserveOriginalText() async throws {
        let f=try ACCapture();defer { Task { await f.clean() } }
        #expect(await ACuntil { await f.core.attributionContextID != nil })
        try f.feed();#expect(await ACuntil { await f.core.attributionPosteriorCount == 2 })
        try await f.commit()
        #expect(await ACuntil { !(await f.entry.store.checkpoint()).annotations.isEmpty })
        let first=await f.entry.store.checkpoint(),ids=first.segments.map(\.id)
        let frozen=await f.entry.store.snapshot(selection:.evidence(ids,includeUnaligned:true))
        #expect(first.segments.count == 1 && first.segments[0].text == "Fixture tail")
        #expect(first.segments[0].diarizerContextID != nil)
        #expect(first.annotations.allSatisfy { $0.assignment == .unknown })
        #expect(frozen.speakerLegend.isEmpty)
        #expect(f.core.attributionContextWasAcknowledged)
        try f.feed();#expect(await ACuntil { (await f.entry.store.checkpoint()).lanes.first?.progress.effectiveASRConsumedSampleEnd ?? 0 >= 1280 })
        try await f.commit();#expect(await ACuntil { (await f.entry.store.checkpoint()).segments.count == 2 })
        #expect(frozen.segments.count == 1 && frozen.segments[0].text == first.segments[0].text)
        await f.stop();#expect(await ACuntil { await f.policy.reservedBytes == 0 })
    }
    @Test func missingOptionalCacheOrInsufficientNativeMemoryLeavesActualASRRunning() async throws {
        for missing in [false,true] {
            let f=try ACCapture(available:missing ? 2000:610,missingOptional:missing)
            #expect(await ACuntil { await f.core.readySources == [.system] })
            try f.feed();#expect(await ACuntil { (await f.entry.store.checkpoint()).lanes.first?.progress.effectiveASRConsumedSampleEnd ?? 0 >= 640 })
            try await f.commit();#expect(await ACuntil { !(await f.entry.store.checkpoint()).segments.isEmpty })
            #expect(await f.core.attributionContextID == nil)
            await f.stop();await f.clean()
        }
    }
    @Test func warningSealsHeldEvaluationAndNativeRetirementCannotRefundRetainedHistory() async throws {
        let gate=ACGate();let f=try ACCapture(evaluationGate:gate,mode:"live-capture-attribution-held-retirement")
        defer { Task { await gate.release();await f.clean() } }
        #expect(await ACuntil { await f.core.attributionContextID != nil })
        try f.feed();#expect(await ACuntil { await f.core.attributionPosteriorCount == 2 })
        try await f.commit();#expect(await ACuntil { await gate.entered })
        let held=f.registry.reservedPayloadBytes
        f.registry.sealAttributionForPressure(.warning)
        #expect(!f.core.attributionPublicationIsActive)
        await f.registry.applyResourcePressure(.init(availableBytes:0,pressure:.warning),policy:f.policy)
        #expect(await f.policy.reservedBytes == 540)
        #expect(f.registry.reservedPayloadBytes == held)
        try f.feed();#expect(await ACuntil { (await f.entry.store.checkpoint()).lanes.first?.progress.effectiveASRConsumedSampleEnd ?? 0 >= 1280 })
        try Data().write(to:f.flag);try f.feed()
        #expect(await ACuntil { await f.policy.reservedBytes == 500 })
        await gate.release()
        #expect(await ACuntil { await f.core.attributionWorkingBytes == 0 })
        #expect(f.registry.reservedPayloadBytes >= LiveRecordingArtifactOwner.reservationBytes + LiveTranscriptStore.attributionLimit)
        #expect((await f.entry.store.checkpoint()).annotations.isEmpty)
        await f.registry.applyResourcePressure(.init(availableBytes:2000,pressure:.normal),policy:f.policy)
        #expect(!f.core.attributionPublicationIsActive)
        await f.stop()
    }
    @Test func validWideAndDeepOptionalInventoriesRetireBeforeRootCreationWhileASRContinues() async throws {
        for kind in ["wide", "deep"] {
            let f = try ACCapture(inventory: kind)
            defer { Task { await f.clean() } }
            // Independent fingerprint plus the unchanged legacy copier proves
            // these are valid caches, rather than malformed-layout rejection.
            let legacyBudget = LiveASRStagingBudget(), legacyOwner = UUID()
            let legacy = try f.diar.assets(legacyBudget)
            #expect(legacy.bind(to: legacyOwner));try await legacy.prepare(owner: legacyOwner)
            #expect(try legacy.snapshot(owner: legacyOwner).fingerprint == f.diar.identity.modelFingerprint)
            await legacy.retire(owner: legacyOwner)?.value
            #expect(legacyBudget.usage.workers == 0 && legacyBudget.usage.roots == 0)
            #expect(await ACuntil { await f.core.readySources == [.system] && !f.core.attributionPublicationIsActive })
            #expect(await ACuntil { await f.policy.reservedBytes == 500 && f.staging.usage.workers == 0 })
            #expect(try FileManager.default.contentsOfDirectory(atPath: f.diar.staging.path).isEmpty)
            #expect(await f.core.attributionContextID == nil)
            try f.feed();#expect(await ACuntil { (await f.entry.store.checkpoint()).lanes.first?.progress.effectiveASRConsumedSampleEnd ?? 0 >= 640 })
            try await f.commit();#expect(await ACuntil { !(await f.entry.store.checkpoint()).segments.isEmpty })
            await f.stop();#expect(await ACuntil { await f.policy.reservedBytes == 0 })
        }
    }
    @Test func nativeRetirementWithoutEvaluatorKeepsSharedInventoryUntilActualProofAndCleanup() async throws {
        let f = try ACCapture(mode: "live-capture-attribution-held-retirement")
        defer { Task { await f.clean() } }
        #expect(await ACuntil { await f.core.attributionContextID != nil && f.core.attributionContextWasAcknowledged })
        let held = f.registry.reservedPayloadBytes
        #expect(held >= LiveRecordingArtifactOwner.reservationBytes + LiveTranscriptStore.attributionLimit + LiveAttributionWorkingSet.limit)
        f.registry.sealAttributionForPressure(.warning)
        await f.registry.applyResourcePressure(.init(availableBytes: 0,pressure: .warning),policy: f.policy)
        // No evaluator or copied-row hold can mask premature fixed-credit return.
        #expect(await ACuntil { await f.core.attributionWorkingBytes == 0 })
        #expect(await f.policy.reservedBytes == 540)
        #expect(f.registry.reservedPayloadBytes == held)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: f.diar.staging.path)).isEmpty)
        try f.feed();#expect(await ACuntil { (await f.entry.store.checkpoint()).lanes.first?.progress.effectiveASRConsumedSampleEnd ?? 0 >= 640 })
        try await f.commit();#expect(await ACuntil { !(await f.entry.store.checkpoint()).segments.isEmpty })
        try Data().write(to: f.flag);try f.feed()
        var cleanupPrecededEveryObservedRefund = true
        #expect(await ACuntil {
            let returned = await f.policy.reservedBytes == 500
            if returned { cleanupPrecededEveryObservedRefund = cleanupPrecededEveryObservedRefund &&
                (try? FileManager.default.contentsOfDirectory(atPath: f.diar.staging.path).isEmpty) == true }
            return returned && f.registry.reservedPayloadBytes == held - LiveAttributionWorkingSet.limit
        })
        #expect(cleanupPrecededEveryObservedRefund)
        let after = await f.entry.store.checkpoint()
        #expect(!f.core.attributionPublicationIsActive && after.annotations.isEmpty)
        await f.stop();#expect(await ACuntil { await f.policy.reservedBytes == 0 })
    }
    @Test func copiedCaptureTreeRetainsItsEnumerationBoundForLaterPathValidation() async throws {
        let fixture = try ACAssets(), budget = LiveASRStagingBudget(), owner = UUID()
        let assets = try fixture.assets(budget)
        defer { Task { await assets.retire(owner: owner)?.value;try? FileManager.default.removeItem(at: fixture.root) } }
        #expect(assets.bind(to: owner));try await assets.prepare(owner: owner,captureInventoryLimit: 65_536)
        let snapshot = try assets.snapshot(owner: owner)
        let weights = URL(fileURLWithPath: assets.configuration.modelDirectory).appendingPathComponent(LiveDiarizationPreset.low.modelFileName + "/weights")
        let names = (0..<60).map { "later-" + String(format: "%03d", $0) + String(repeating: "x",count:210) + ".bin" }
        try FileManager.default.setAttributes([.posixPermissions: 0o700],ofItemAtPath: weights.path)
        for name in names { try Data([9]).write(to: weights.appendingPathComponent(name)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555],ofItemAtPath: weights.path)
        #expect(throws: LiveASRAssetError.oversized) { _ = try snapshot.validateCurrentPath() }
        // Remove only test-owned additions. Existing cleanup never gains foreign inventory authority.
        try FileManager.default.setAttributes([.posixPermissions: 0o700],ofItemAtPath: weights.path)
        for name in names { try FileManager.default.removeItem(at: weights.appendingPathComponent(name)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555],ofItemAtPath: weights.path)
        _ = try snapshot.validateCurrentPath()
        await assets.retire(owner: owner)?.value
        #expect(budget.usage.workers == 0 && budget.usage.roots == 0)
    }
    @Test func claimedOpenValidationFailureKeepsExactSharedFallbackWhileASRContinuesUntilActualExit() async throws {
        let gate = ACGate(), f = try ACCapture(claimGate: gate)
        defer { Task { await gate.release();await f.clean() } }
        #expect(await ACuntil { await gate.entered })
        let held = f.registry.reservedPayloadBytes
        let copied = try #require(try FileManager.default.contentsOfDirectory(at: f.diar.staging,includingPropertiesForKeys: nil).first)
        let weights = copied.appendingPathComponent(LiveDiarizationPreset.low.modelFileName + "/weights")
        let names = (0..<60).map { "foreign-" + String(format: "%03d", $0) + String(repeating: "x",count:210) + ".bin" }
        try FileManager.default.setAttributes([.posixPermissions: 0o700],ofItemAtPath: weights.path)
        for name in names { try Data([7]).write(to: weights.appendingPathComponent(name)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555],ofItemAtPath: weights.path)
        await gate.release()
        #expect(await ACuntil { let bytes = await f.core.attributionWorkingBytes;return !f.core.attributionPublicationIsActive && bytes == 0 })
        #expect(!f.core.attributionContextWasAcknowledged)
        #expect(await f.core.attributionContextID == nil)
        #expect(await f.policy.reservedBytes == 540 && f.registry.reservedPayloadBytes == held)
        #expect(FileManager.default.fileExists(atPath: copied.path))
        #expect(try Data(contentsOf: weights.appendingPathComponent(names[0])) == Data([7]))
        try f.feed();#expect(await ACuntil { (await f.entry.store.checkpoint()).lanes.first?.progress.effectiveASRConsumedSampleEnd ?? 0 >= 640 })
        try await f.commit();#expect(await ACuntil { !(await f.entry.store.checkpoint()).segments.isEmpty })
        try FileManager.default.setAttributes([.posixPermissions: 0o700],ofItemAtPath: weights.path)
        for name in names { try FileManager.default.removeItem(at: weights.appendingPathComponent(name)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555],ofItemAtPath: weights.path)
        await f.stop()
        #expect(await ACuntil { await f.policy.reservedBytes == 0 && f.staging.usage.roots == 0 })
        #expect(f.registry.reservedPayloadBytes == held - LiveAttributionWorkingSet.limit)
    }
    @Test func absentOptionalTransportRetiresUnusedReservationAndKeepsActualASRRunning() async throws {
        let f = try ACCapture(optionalTransportAvailable: false);defer { Task { await f.clean() } }
        #expect(await ACuntil { await f.core.readySources == [.system] })
        #expect(await ACuntil { !f.core.attributionPublicationIsActive })
        #expect(await ACuntil { await f.policy.reservedBytes == 500 })
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.diar.staging.path).isEmpty)
        try f.feed();#expect(await ACuntil { (await f.entry.store.checkpoint()).lanes.first?.progress.effectiveASRConsumedSampleEnd ?? 0 >= 640 })
        try await f.commit();#expect(await ACuntil { !(await f.entry.store.checkpoint()).segments.isEmpty })
        await f.stop();#expect(await ACuntil { await f.policy.reservedBytes == 0 })
    }
    @Test func acceptedPausePreservesOneContextAcrossActualRegisteredResumeAndFrozenText() async throws {
        let f = try ACCapture();defer { Task { await f.clean() } }
        #expect(await ACuntil { await f.core.attributionContextID != nil && f.core.attributionContextWasAcknowledged })
        let context = try #require(await f.core.attributionContextID), old = try #require(await f.core.streamState(source: .system))
        try f.feed();#expect(await ACuntil { await f.core.attributionPosteriorCount == 2 })
        try await f.commit();#expect(await ACuntil { !(await f.entry.store.checkpoint()).annotations.isEmpty })
        let original = await f.entry.store.checkpoint()
        let frozen = await f.entry.store.snapshot(selection: .evidence(original.segments.map(\.id),includeUnaligned: true))
        f.prepared.session.pause();#expect(await ACuntil { await f.core.pausedSources.contains(.system) })
        #expect(f.core.attributionPublicationIsActive)
        f.prepared.session.resume()
        #expect(await ACuntil { let lane = await f.core.streamState(source: .system);return lane?.ready == true && lane?.scope.epochID != old.scope.epochID })
        #expect(await ACuntil { !f.prepared.ingress.isAdmissionPaused(.system) })
        try f.feed();#expect(await ACuntil { (await f.entry.store.checkpoint()).lanes.first?.progress.effectiveASRConsumedSampleEnd ?? 0 >= 640 })
        try await f.commit();#expect(await ACuntil { (await f.entry.store.checkpoint()).segments.count == 2 })
        let resumed = await f.entry.store.checkpoint()
        #expect(await f.core.attributionContextID == context)
        #expect(resumed.segments.allSatisfy { $0.diarizerContextID == context })
        #expect(frozen.segments.map(\.id) == original.segments.map(\.id) && frozen.segments[0].text == original.segments[0].text)
        #expect(await f.policy.reservedBytes == 540)
        await f.stop();#expect(await ACuntil { await f.policy.reservedBytes == 0 })
    }
    @Test func actualHeldMandatoryFailureCompletesDiscardedOptionalRegistrationAndAnnotationReceipts() async throws {
        for phase in ["registration", "annotation"] {
            let gate = ACGate(), work = ACGate()
            let f = try ACCapture(copyGate: phase == "registration" ? work : nil,
                evaluationGate: phase == "annotation" ? work : nil,publicationGate: gate,publicationPhase: phase)
            defer { Task { await gate.release();await work.release();await f.clean() } }
            #expect(await ACuntil { await f.core.readySources == [.system] })
            if phase == "annotation" {
                #expect(await ACuntil { await f.core.attributionContextID != nil && f.core.attributionContextWasAcknowledged })
                try f.feed();#expect(await ACuntil { await f.core.attributionPosteriorCount == 2 })
                try await f.commit();#expect(await ACuntil { await work.entered })
                try f.feed()
            } else {
                #expect(await ACuntil { await work.entered });try f.feed()
            }
            #expect(await ACuntil { await gate.entered });await work.release()
            #expect(await ACuntil { let entered = await gate.entered, pending = await f.core.attributionPendingPublicationCount;return entered && pending == 1 })
            let original = await f.entry.store.checkpoint()
            if phase == "registration" { #expect(!f.core.attributionContextWasAcknowledged && original.segments.isEmpty) }
            else { #expect(original.segments.count == 1 && original.annotations.isEmpty) }
            #expect(await f.policy.reservedBytes == 540)
            #expect(f.registry.reservedPayloadBytes >= LiveRecordingArtifactOwner.reservationBytes + LiveAttributionWorkingSet.limit)
            await gate.release()
            #expect(await ACuntil { let pending = await f.core.attributionPendingPublicationCount;return await f.policy.reservedBytes == 0 && pending == 0 && f.staging.usage.roots == 0 })
            #expect(f.entry.store.captureIsClosed)
            let after = await f.entry.store.checkpoint()
            #expect(after.segments == original.segments && after.annotations.isEmpty)
            #expect(await f.core.attributionWorkingBytes == 0)
            await f.stop()
        }
    }
    @Test func independentOptionalFingerprintOracleProducesAnActualOwnedSnapshot() async throws {
        let fixture = try ACAssets(), budget = LiveASRStagingBudget(), owner = UUID()
        let assets = try fixture.assets(budget)
        defer { Task { await assets.retire(owner: owner)?.value; try? FileManager.default.removeItem(at: fixture.root) } }
        #expect(assets.bind(to: owner)); try await assets.prepare(owner: owner)
        #expect(try assets.snapshot(owner: owner).fingerprint == fixture.identity.modelFingerprint)
        await assets.retire(owner: owner)?.value
        #expect(budget.usage.workers == 0 && budget.usage.roots == 0)
    }
    @Test func globalWorkingReservationDenialLeavesActualMandatoryCaptureRunning() async throws {
        let budget = LiveRecordingPayloadBudget(ownerLimit: 8)
        let first = try budget.reserve(), second = try budget.reserve()
        let auxiliary = try budget.reserveAuxiliary(bytes: 29 * 1_024 * 1_024)
        let f = try ACCapture(workingBudget: budget)
        defer { Task { await f.clean() } }
        #expect(await ACuntil { await f.core.readySources == [.system] })
        #expect(await ACuntil { !f.core.attributionPublicationIsActive })
        #expect(await ACuntil { await f.policy.reservedBytes == 500 })
        #expect(f.registry.reservedPayloadBytes == 125 * 1_024 * 1_024 + LiveManagedArtifactCatalogue.metadataBytes)
        #expect(await f.core.attributionContextID == nil)
        try f.feed();#expect(await ACuntil { (await f.entry.store.checkpoint()).lanes.first?.progress.effectiveASRConsumedSampleEnd ?? 0 >= 640 })
        try await f.commit();#expect(await ACuntil { !(await f.entry.store.checkpoint()).segments.isEmpty })
        await f.stop();await f.clean()
        withExtendedLifetime((first,second,auxiliary)) {}
    }
    @Test func microphoneCutPreservesSystemContextUntilActualSystemCut() async throws {
        let f = try ACCapture(sources: [.microphone,.system]);defer { Task { await f.clean() } }
        #expect(await ACuntil { await f.core.readySources == [.microphone,.system] })
        #expect(await ACuntil { await f.core.attributionContextID != nil })
        await f.core.abandonCurrentSource(.microphone)
        #expect(f.core.attributionPublicationIsActive)
        try f.feed();#expect(await ACuntil { await f.core.attributionPosteriorCount == 2 })
        try await f.commit();#expect(await ACuntil { !(await f.entry.store.checkpoint()).annotations.isEmpty })
        await f.core.abandonCurrentSource(.system)
        #expect(!f.core.attributionPublicationIsActive)
        #expect(await ACuntil { await f.policy.reservedBytes == 500 })
        await f.stop();#expect(await ACuntil { await f.policy.reservedBytes == 0 })
    }
    @Test func actualAutomaticWriterColdReloadPreservesUnknownContextAndOriginalText() async throws {
        let f = try ACCapture();defer { Task { await f.clean() } }
        f.registry.startPersistence(f.entry.identity)
        #expect(await ACuntil { await f.core.attributionContextID != nil })
        try f.feed();#expect(await ACuntil { await f.core.attributionPosteriorCount == 2 })
        try await f.commit();#expect(await ACuntil { !(await f.entry.store.checkpoint()).annotations.isEmpty })
        await f.stop()
        let audio = f.diar.root.appendingPathComponent("captured.wav");try Data([1,2,3]).write(to: audio)
        let metadata = RecordingMetadataPayload(recordingID: f.entry.identity.recordingID,dateISO8601: "fixture",durationSeconds: 1,
            meetingTitle: "fixture",masterFileName: audio.lastPathComponent,segmentFileNames: [],warnings: [])
        try JSONEncoder().encode(metadata).write(to: audio.deletingPathExtension().appendingPathExtension("json"))
        try f.entry.artifacts.bind(to: audio)
        #expect(await ACuntil { f.entry.artifacts.isDurable })
        let original = await f.entry.store.checkpoint()
        let cold = LiveRecordingSessionRegistry(artifactRoot: f.diar.root.appendingPathComponent("history"))
        let restored = try #require(try await cold.resolve(recordingID: f.entry.identity.recordingID,audioURL: audio))
        let checkpoint = await restored.store.checkpoint()
        #expect(checkpoint.segments == original.segments)
        #expect(checkpoint.annotations == original.annotations && !checkpoint.annotations.isEmpty)
        #expect(checkpoint.attributionCoverage == original.attributionCoverage)
        #expect(restored.store.captureIsClosed)
        #expect(restored.artifacts.admittedAudioURL == audio.standardizedFileURL)
        let bound = try #require(restored.artifacts.admittedAudioURL)
        #expect(try RecordingDeletionAuthority.canonical(bound) == RecordingDeletionAuthority.canonical(audio))
    }
    @Test func overlappingRawSnapshotAndQueuedPayloadCannotEscapeWorkingBoundOrLogicalSeal() async throws {
        let budget = LiveRecordingPayloadBudget(ownerLimit: 8)
        let working = LiveAttributionWorkingSet(try budget.reserveAuxiliary(bytes: LiveAttributionWorkingSet.limit))
        let identity = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID()), epoch = UUID(), context = UUID()
        let publication = LiveAttributionPublication(identity: identity,ownerID: UUID(),recording: .init())
        let scope = LiveLaneScope(identity: identity,source: .system,epochID: epoch), gate = ACGate()
        let window = LiveAttributionWindow(working: working,publication: publication,context: context,beforeEvaluation: { await gate.hold() },
            publish: { _,_ in .accepted },failed: { publication.seal() })
        defer { Task { await gate.release();await window.finish() } }
        func row(_ n: Int) throws -> LiveDiarizationRow {
            let first = Int64(n * 160), last = first + 160
            return try .init(streamSamples: .init(start: first,end: last),samples: .init(start: first,end: last),
                meeting: .init(startNanoseconds: first * 62_500,endNanoseconds: last * 62_500),activity: [Float](repeating: 0.7,count: 8))
        }
        let initialRows = ((LiveAttributionWorkingSet.limit - 512 * 1_024 - 64 * 1_024) /
                           (2 * LiveAttributionWorkingSet.rowBytes)) & ~1
        for n in stride(from:0,to:initialRows,by:2) { try window.append(scope: scope,rows:[row(n),row(n+1)]) }
        let segment = CommittedLiveSegment(id: .init(epochID: epoch,index: 0),source: .system,
            range: .init(samples: .init(start:0,end:Int64(initialRows * 160)),meeting: .init(startNanoseconds:0,endNanoseconds:Int64(initialRows) * 10_000_000)),text:"held",diarizerContextID:context)
        #expect(window.offer(segment));#expect(await ACuntil { await gate.entered })
        let held = working.chargedBytes
        #expect(held > LiveAttributionWorkingSet.controlBytes + 2 * initialRows * LiveAttributionWorkingSet.rowBytes)
        var capacity = false
        for n in stride(from:initialRows,to:2048,by:2) {
            do { try window.append(scope:scope,rows:[row(n),row(n+1)]) }
            catch LiveSpeakerAttributor.Failure.capacity { capacity = true;break }
        }
        #expect(capacity && working.chargedBytes <= LiveAttributionWorkingSet.limit)
        #expect(!window.offer(.init(id:.init(epochID:epoch,index:1),source:.system,range:segment.range,
            text:String(repeating:"q",count:65_000),diarizerContextID:context)))
        publication.seal();window.seal()
        #expect(working.chargedBytes >= held)
        #expect(budget.reservedBytes == LiveAttributionWorkingSet.limit)
        await gate.release();await window.finish()
        #expect(working.chargedBytes == LiveAttributionWorkingSet.controlBytes)
    }
    @Test func actualWarningCallbackAcrossRecoveryCannotReopenPendingHeldReceipt() async throws {
        for recover in [false,true] {
            let asr = try ASRAssetsFixture(), diar = try ACAssets(), staging = LiveASRStagingBudget()
            let receiptGate = ACGate(), callbackGate = ACGate(), measurement = ACMeasurement()
            let policy = LiveModelResourcePolicy(profiles:[.init(id:"pending",hardware:"fixture",modelRevision:"fixture-asr",chunkMs:1120,
                sourceCount:1,qualificationID:"model-free",asrBytes:500,attributionBytes:40,headroomBytes:100,
                concurrentChatModels:[:],backgroundWorkQualified:false,asr:ASRAssetsFixture.identity(),diarization:diar.identity)])
            let admission = LiveModelJobAdmission(policy:policy,measurement:{ await measurement.snapshot() })
            let registry = LiveRecordingSessionRegistry(artifactRoot:diar.root.appendingPathComponent("history"))
            let identity = LiveSessionIdentity(recordingID:UUID(),captureSessionID:UUID()), entry = try registry.register(identity)
            let assets = try asr.assets(budget:staging,identity:ASRAssetsFixture.identity()), optional = try diar.assets(staging), owner = UUID()
            let attribution = LiveCaptureAttributionOwner(identity:identity,ownerID:owner,assets:optional,recording:entry.validity,
                admission:admission,hooks:.init(),reserve:{ @MainActor in try registry.reserveAttributionWorking(identity) })
            let input = LiveSessionBegin(identity:identity,configuration:assets.configuration,
                epochs:[.init(id:UUID(),source:.system,engineRevision:"fixture-asr",language:"auto",meetingOriginNanoseconds:nil)],diarization:attribution.metadata)
            let ingress = LiveCaptureIngress(input:input)
            let privacy = RecordingPrivacyScope(recordingID:identity.recordingID,store:.init(gapDirectoryURL:diar.root.appendingPathComponent("gaps")),pendingRootURL:diar.root.appendingPathComponent("privacy"))
            let preparation = LiveCaptureStartPreparation(input:input,ingress:ingress,resources:policy,privacyScope:privacy,runID:UUID(),
                request:.init(profileID:"pending",hardware:"fixture",modelRevision:"fixture-asr",chunkMs:1120,sourceCount:1,
                    attributionRequested:true,asr:ASRAssetsFixture.identity(),diarization:diar.identity),cacheCheck:{ _ in },
                currentMemory:{ await measurement.snapshot() },beginReceipt:{ operation,context in
                    let receipt = await PrivacyTrace.begin(operation,in:context);await receiptGate.hold();return receipt
                },asrAssets:assets,attribution:attribution)
            let connection = MLHostConnection(binaryURL:URL(fileURLWithPath:".build/debug/dBriefMLHostStub"),supportBase:diar.root,
                environment:["STUB_MODE":"live-capture-attribution"],role:.live,liveEventLimits:.recording)
            let core = LiveCaptureSessionCoordinator(input:input,store:entry.store,transport:.live(connection),resources:policy,
                validity:entry.validity,ingress:ingress,preparation:preparation)
            try registry.install(core,for:identity);try await core.start()
            #expect(await ACuntil { await receiptGate.entered })
            #expect(await policy.reservedBytes == 540)
            let monitor = MemoryPressureMonitor()
            monitor.registerPressureHandler { level in
                let eventPressure: LiveResourceMeasurement.Pressure = level == .normal ? .normal : .warning
                registry.sealAttributionForPressure(eventPressure)
                let frozen = LiveResourceMeasurement(availableBytes:2000,pressure:eventPressure)
                if level == .warning { await callbackGate.hold() }
                await policy.measurementDidChange();await registry.applyResourcePressure(frozen,policy:policy)
            }
            await measurement.set(.warning)
            let warning = Task { await monitor.testTrigger(.warning) }
            #expect(await ACuntil { await callbackGate.entered })
            #expect(!core.attributionPublicationIsActive)
            if recover { await measurement.set(.normal);await monitor.testTrigger(.normal) }
            await callbackGate.release();await warning.value
            #expect(await ACuntil { await policy.reservedBytes == 500 })
            await receiptGate.release()
            #expect(await ACuntil { await core.readySources == [.system] })
            #expect(!core.attributionPublicationIsActive && attribution.posteriorCount == 0)
            await core.beginClosing();await core.hardwareDidClose();try await core.waitUntilClosed()
            await connection.shutdownLiveAndWaitForExit()
            #expect(await ACuntil { await policy.reservedBytes == 0 && staging.usage.roots == 0 && staging.usage.workers == 0 })
            asr.remove();try FileManager.default.removeItem(at:diar.root)
        }
    }
    @Test func exactOriginCanRegisterBehindCaptureAdvanceButForeignEpochOrGateCannot() async throws {
        let identity=LiveSessionIdentity(recordingID:UUID(),captureSessionID:UUID()),validity=RecordingDerivativeValidity()
        let store=LiveTranscriptStore(identity:identity,validity:validity)
        let epoch=LiveEpoch(id:UUID(),source:.system,engineRevision:"fixture",language:"auto",meetingOriginNanoseconds:0)
        #expect(await store.beginEpoch(owner:identity,epoch:epoch) == .accepted)
        #expect(await store.admit(.init(identity:identity,epochID:epoch.id,source:.system,sequence:0,
            payload:.progress(.init(capturedSampleEnd:1000,admittedSampleEnd:1000,consumedSampleEnd:1000)))) == .accepted)
        let gate=LiveAttributionPublication(identity:identity,ownerID:UUID(),recording:validity)
        let scope=LiveLaneScope(identity:identity,source:.system,epochID:epoch.id),context=UUID()
        #expect(await store.registerDiarizer(scope:scope,originSample:400,contextID:context,publication:gate) == .accepted)
        let segment=CommittedLiveSegment(id:.init(epochID:epoch.id,index:0),source:.system,
            range:.init(samples:.init(start:0,end:1000),meeting:.init(startNanoseconds:0,endNanoseconds:62_500_000)),text:"old prefix")
        #expect(await store.admit(.init(identity:identity,epochID:epoch.id,source:.system,sequence:1,payload:.committed(segment))) == .accepted)
        #expect(await store.registerDiarizer(scope:.init(identity:identity,source:.system,epochID:UUID()),originSample:0,contextID:UUID(),publication:gate) == .rejected(.staleEpoch))
        gate.seal()
        #expect(await store.registerDiarizer(scope:scope,originSample:400,contextID:UUID(),publication:gate) == .rejected(.closed))
    }
}
