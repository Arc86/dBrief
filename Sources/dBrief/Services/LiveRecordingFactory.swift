import Foundation
import dBriefWire

enum LiveTranscriptionEngine: String, Codable, CaseIterable, Sendable { case appleSpeech, nemotron }

/// Qualified selection is frozen on the recording request, before persistence.
/// Production currently has no eligible selections; model-free tests inject one.
struct LiveNemotronSelection: Sendable {
    let profileID: String
    let hardware: String
    let sourceDirectory: URL
    let identity: LiveASRIdentity
    let language: LiveASRConfiguration.Language
    let chunkMs: Int
    let sources: [LiveSource]
    let captureQualified: Bool
    var vad: LiveVADConfiguration? = nil
}

@MainActor struct LiveRecordingFactory {
    let registry: LiveRecordingSessionRegistry
    let admission: LiveModelJobAdmission
    let beforeAdmission: @Sendable () async -> Void
    let makeTransport: @MainActor @Sendable (LiveSessionBegin) -> LiveASRTransport
    let makeASRAssets: @MainActor @Sendable (LiveNemotronSelection) throws -> LiveASRModelAssets
    init(registry: LiveRecordingSessionRegistry,admission: LiveModelJobAdmission,
         beforeAdmission: @escaping @Sendable () async -> Void = {},
         makeTransport: (@MainActor @Sendable (LiveSessionBegin) -> LiveASRTransport)? = nil,
         makeASRAssets: (@MainActor @Sendable (LiveNemotronSelection) throws -> LiveASRModelAssets)? = nil) {
        self.registry = registry; self.admission = admission; self.beforeAdmission = beforeAdmission
        self.makeTransport = makeTransport ?? { _ in
            .live(MLHostConnection(binaryURL: MLHostLocator.binaryURL(),supportBase: MLHostLocator.supportBase(),role: .live,
                liveEventLimits: .recording))
        }
        self.makeASRAssets = makeASRAssets ?? { selection in
            try .init(sourceDirectory: selection.sourceDirectory,identity: selection.identity,
                language: selection.language,chunkMs: selection.chunkMs)
        }
    }

    var derivative: CaptureLiveDerivative {
        .init(prepare: { request in prepare(request) },make: { _,_ in nil })
    }
    func prepare(_ request: CaptureCoordinator.Request) -> CaptureLiveDerivative.Prepared? {
        guard request.liveTranscription, request.liveEngine == .nemotron,
              let selected = request.nemotronSelection, selected.captureQualified,
              selected.identity.isSupported, (1...2).contains(selected.sources.count),
              Set(selected.sources).count == selected.sources.count, selected.sources.allSatisfy(\.isCaptureSource),
              selected.language.rawValue == (request.language.isEmpty ? "auto" : request.language),
              let scope = request.privacyScope, scope.recordingID == request.id,
              registry.entry(recordingID: request.id) == nil else { return nil }
        let identity = LiveSessionIdentity(recordingID: request.id,captureSessionID: request.captureSessionID)
        var entry: LiveRecordingSessionRegistry.Entry?
        do {
            let asr = try makeASRAssets(selected)
            guard asr.configuration.identity == selected.identity, asr.configuration.language == selected.language,
                  asr.configuration.chunkMs == selected.chunkMs else { return nil }
            let vad = try selected.vad.map { try LiveVADAssetPreparation(source: $0) }
            let input = LiveSessionBegin(identity: identity,configuration: asr.configuration,epochs: selected.sources.map {
                .init(id: UUID(),source: $0,engineRevision: selected.identity.modelRevision,
                    language: selected.language.rawValue,meetingOriginNanoseconds: nil)
            },vad: vad?.configuration)
            guard input.isValid else { return nil }
            let ingress = LiveCaptureIngress(input: input)
            let resourceRequest = LiveResourceRequest(profileID: selected.profileID,hardware: selected.hardware,
                modelRevision: selected.identity.modelRevision,chunkMs: selected.chunkMs,sourceCount: selected.sources.count,
                attributionRequested: false,vad: input.vad,asr: selected.identity)
            let beforeAdmission = beforeAdmission
            let preparation = LiveCaptureStartPreparation(input: input,ingress: ingress,resources: admission.policy,
                privacyScope: scope,runID: UUID(),request: resourceRequest,cacheCheck: { _ in await beforeAdmission() },
                currentMemory: admission.measurement,asrAssets: asr,vadAssets: vad)
            let registered = try registry.register(identity); entry = registered
            let core = LiveCaptureSessionCoordinator(input: input,store: registered.store,transport: makeTransport(input),
                resources: admission.policy,validity: registered.validity,ingress: ingress,epochHistoryLimit: 64,
                publicationByteLimit: 2 * 1_024 * 1_024,preparation: preparation)
            let streams = try LiveCaptureStreamSession(input: input,ingress: ingress,coordinator: core)
            try registry.install(core,for: identity)
            let adapter = streams.derivativeSession(), registry = registry
            let session = CaptureLiveDerivative.Session(identity: identity,register: adapter.register,
                beginClosing: adapter.beginClosing,hardwareDidClose: {
                    await adapter.hardwareDidClose()
                    await MainActor.run { try? registry.captureDidClose(identity) }
                },expire: adapter.expire,pause: adapter.pause,resume: adapter.resume,
                inputDeviceChanged: adapter.inputDeviceChanged,ingress: ingress,registerPrepared: adapter.registerPrepared)
            return .init(ingress: ingress,session: session)
        } catch {
            if entry != nil { try? registry.retire(identity) }
            return nil
        }
    }
}
