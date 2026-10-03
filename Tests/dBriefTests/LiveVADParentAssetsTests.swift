import Foundation
import Testing
@testable import dBriefWire
@testable import dBrief

private struct ParentVADFixture {
    static let fingerprint = "31f96f6d309c03de46967788ec8fe00e2e2fc6a7afe576218711e475e99e3337"
    let root = URL(fileURLWithPath: "/private/tmp/vad-parent-\(UUID())",isDirectory: true)
    let source: LiveVADConfiguration
    init() throws {
        let directory = root.appendingPathComponent("source.mlmodelc")
        let files: [String:Data] = ["metadata.json": Data("{}".utf8), "model.mil": Data("fixture".utf8),
            "coremldata.bin": Data("core".utf8), "analytics/coremldata.bin": Data("analytics".utf8), "weights/weight.bin": Data([1,2,3])]
        for (name,data) in files {
            let file = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),withIntermediateDirectories: true)
            try data.write(to: file)
        }
        source = .init(identity: .init(modelRevision: "silero-vad-unified-256ms-v6.2.1",modelFingerprint: Self.fingerprint,
            runtimeRevision: LiveASRIdentity.currentRuntimeRevision),modelPath: directory.path)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite(.serialized) struct LiveVADParentAssetsTests {
    private func startPreparation(asr: LiveASRModelAssets,vad: LiveVADAssetPreparation,resources: LiveModelResourcePolicy)
        -> (LiveCaptureStartPreparation,LiveSessionBegin,UUID) {
        let input = LiveSessionBegin(identity: .init(recordingID: UUID(),captureSessionID: UUID()),configuration: asr.configuration,
            epochs: [.init(id: UUID(),source: .microphone,engineRevision: "fixture-asr",language: "auto",meetingOriginNanoseconds: nil)],
            vad: vad.configuration)
        let scope = RecordingPrivacyScope(recordingID: input.identity.recordingID)
        let prep = LiveCaptureStartPreparation(input: input,ingress: .init(input: input),resources: resources,
            privacyScope: scope,runID: UUID(),request: .init(profileID: "parent-vad",hardware: "fixture",modelRevision: "fixture-asr",
                chunkMs: 1120,sourceCount: 1,attributionRequested: false,vad: vad.configuration,asr: asr.configuration.identity),
            cacheCheck: { _ in },currentMemory: { .init(availableBytes: 2000,pressure: .normal) },context: { scope,run in
                .init(receiptURL: scope.pendingReceiptURL,store: scope.store,runID: run,recordingID: scope.recordingID)
            },beginReceipt: { _,_ in nil },asrAssets: asr,vadAssets: vad)
        return (prep,input,UUID())
    }
    private func resources(vad: LiveVADConfiguration) -> LiveModelResourcePolicy {
        .init(profiles: [.init(id: "parent-vad",hardware: "fixture",modelRevision: "fixture-asr",chunkMs: 1120,sourceCount: 1,
            qualificationID: "model-free",asrBytes: 500,attributionBytes: nil,headroomBytes: 100,concurrentChatModels: [:],
            backgroundWorkQualified: false,vad: vad.identity,vadBytes: 120,asr: ASRAssetsFixture.identity())])
    }

    @Test func optionalCopyFailurePreservesHealthyASRAndTheFrozenUnavailableVADIdentity() async throws {
        let f = try ParentVADFixture(), a = try ASRAssetsFixture(); defer { f.remove(); a.remove() }
        let bad = LiveVADConfiguration(identity: .init(modelRevision: f.source.identity.modelRevision,
            modelFingerprint: String(repeating: "b",count: 64),runtimeRevision: LiveASRIdentity.currentRuntimeRevision),modelPath: f.source.modelPath)
        let budget = LiveASRStagingBudget(), vad = try LiveVADAssetPreparation(source: bad,budget: budget), asr = try a.assets()
        let resources = resources(vad: vad.configuration), (prep,input,owner) = startPreparation(asr: asr,vad: vad,resources: resources)
        try #require(prep.bind(to: owner))
        let prepared = try await prep.prepare(owner: owner)
        #expect(prepared.input == input && prepared.input.vad?.identity == bad.identity)
        #expect(prepared.input.vad?.modelPath != bad.modelPath)
        #expect(FileManager.default.fileExists(atPath: prepared.input.configuration.modelDirectory))
        #expect(!FileManager.default.fileExists(atPath: vad.configuration.modelPath))
        #expect(await resources.reservedBytes == 620)
        #expect(budget.usage.roots == 0 && FileManager.default.fileExists(atPath: bad.modelPath))
        try await prep.validatePreparedStart(prepared,owner: owner)
        await prep.complete(.failed,owner: owner)?.value
        #expect(await asrEventually { a.staged.isEmpty })
        #expect(await resources.reservedBytes == 0)
    }

    @Test func cancellationOfAHeldVADCopyRetainsItsWorkerUntilActualReturnAndCannotDegradeIntoStart() async throws {
        let f = try ParentVADFixture(), a = try ASRAssetsFixture(); defer { f.remove(); a.remove() }
        let gate = ASRCopyGate(), budget = LiveASRStagingBudget()
        let vad = try LiveVADAssetPreparation(source: f.source,budget: budget,probe: { point,_ in
            if point == .afterCreateDirectory { await gate.hold() }
        })
        let resources = resources(vad: vad.configuration), (prep,_,owner) = startPreparation(asr: try a.assets(),vad: vad,resources: resources)
        try #require(prep.bind(to: owner))
        let worker = Task { try await prep.prepare(owner: owner) }
        guard await asrEventually({ await gate.entered }) else {
            worker.cancel(); await gate.release(); _ = try? await worker.value
            Issue.record("VAD copy did not reach its held operation"); return
        }
        worker.cancel(); await prep.complete(.cancelled,owner: owner)?.value
        #expect(budget.usage.workers == 1)
        #expect(await resources.reservedBytes == 0)
        await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await worker.value }
        #expect(budget.usage.workers == 0 && budget.usage.roots == 0)
        #expect(FileManager.default.fileExists(atPath: f.source.modelPath))
        #expect(!FileManager.default.fileExists(atPath: vad.configuration.modelPath))
    }

    @Test func futurePathIsFrozenAndHelperOpeningCannotDeleteParentAssets() async throws {
        let f = try ParentVADFixture(); defer { f.remove() }
        let budget = LiveASRStagingBudget(), assets = try LiveVADAssetPreparation(source: f.source,budget: budget), owner = UUID(), frozen = assets.configuration
        try #require(frozen != f.source && frozen.identity == f.source.identity && frozen.isValid)
        #expect(!FileManager.default.fileExists(atPath: frozen.modelPath))
        try #require(assets.bind(to: owner))
        try await assets.prepare(owner: owner)
        #expect(assets.configuration == frozen)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: f.source.modelPath))
        func reopenAndDrop() throws {
            let helper = try LiveVADModelAssets.openReadOnly(frozen)
            #expect(try helper.readMetadata() == Data("{}".utf8))
            #expect(try helper.modelDirectory.path == frozen.modelPath)
        }
        try reopenAndDrop()
        #expect(FileManager.default.fileExists(atPath: frozen.modelPath))
        #expect(budget.usage.roots == 1)
        await assets.retire(owner: owner)?.value
        #expect(!FileManager.default.fileExists(atPath: frozen.modelPath))
        #expect(budget.usage.roots == 0)
    }

    @Test func failedPreparationAndForeignRetirementDoNotRemoveCallerCache() async throws {
        let f = try ParentVADFixture(); defer { f.remove() }
        let wrong = LiveVADConfiguration(identity: .init(modelRevision: f.source.identity.modelRevision,
            modelFingerprint: String(repeating: "b",count: 64),runtimeRevision: LiveASRIdentity.currentRuntimeRevision),modelPath: f.source.modelPath)
        let budget = LiveASRStagingBudget(), assets = try LiveVADAssetPreparation(source: wrong,budget: budget), owner = UUID()
        try #require(assets.bind(to: owner))
        #expect(assets.retire(owner: UUID()) == nil)
        await #expect(throws: LiveVADAssetError.fingerprintMismatch) { try await assets.prepare(owner: owner) }
        await assets.retire(owner: owner)?.value
        #expect(FileManager.default.fileExists(atPath: f.source.modelPath))
        #expect(budget.usage.roots == 0 && budget.usage.workers == 0)
    }

    @Test func selectedConfiguredVADCannotUseAnUnownedStartPreparation() async throws {
        let f = try ParentVADFixture(); defer { f.remove() }
        let identity = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
        let input = LiveSessionBegin(identity: identity,configuration: .init(language: .auto,modelDirectory: "/unused"),
            epochs: [.init(id: UUID(),source: .microphone,engineRevision: "asr",language: "auto",meetingOriginNanoseconds: nil)],vad: f.source)
        let ingress = LiveCaptureIngress(input: input)
        let prep = LiveCaptureStartPreparation(input: input,ingress: ingress,resources: .init(),
            privacyScope: .init(recordingID: identity.recordingID),runID: UUID(),request: .init(profileID: "none",hardware: "test",
                modelRevision: "asr",chunkMs: 1120,sourceCount: 1,attributionRequested: false,vad: f.source),
            cacheCheck: { _ in },currentMemory: { .init(availableBytes: 0,pressure: .critical) })
        #expect(!prep.bind(to: UUID()))
    }
}
