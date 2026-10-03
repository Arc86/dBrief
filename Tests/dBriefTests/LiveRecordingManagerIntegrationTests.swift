import Foundation
import Testing
@testable import dBriefWire
@testable import dBrief

@MainActor private final class LiveManagerProbe {
    var createEntered = false
    var request: CaptureCoordinator.Request?
    var input: LiveSessionBegin?
    private var createWaiter: CheckedContinuation<Void,Never>?
    func holdCreate() async { createEntered = true; await withCheckedContinuation { createWaiter = $0 } }
    func releaseCreate() { createWaiter?.resume(); createWaiter = nil }
}

@MainActor private final class LiveManagerFixture {
    let files: ASRAssetsFixture
    let settings = AppSettings()
    let state: AppState
    let manager: RecordingManager
    let ordinary: MLHostConnection
    let probe = LiveManagerProbe()
    let copyGate = ASRCopyGate()
    let stagingBudget = LiveASRStagingBudget()
    private let restore: () -> Void

    init(holdCopy: Bool = false) throws {
        files = try ASRAssetsFixture()
        let settings = settings, files = files, probe = probe, copyGate = copyGate, stagingBudget = stagingBudget
        let oldLive = settings.liveTranscriptionEnabled, oldEngine = settings.liveTranscriptionEngine
        let oldLanguage = settings.nemotronLiveLanguage, oldChunk = settings.nemotronLiveChunkMs
        let oldFinal = settings.transcriptionEngine, oldMini = settings.showMiniRecordingView
        let oldProfiles = settings.profiles, oldActive = settings.activeProfileId
        let oldAutomatic = settings.automaticProfileId, oldAutomaticOwner = settings.automaticProfileRecordingID
        restore = {
            settings.liveTranscriptionEnabled = oldLive; settings.liveTranscriptionEngine = oldEngine
            settings.nemotronLiveLanguage = oldLanguage; settings.nemotronLiveChunkMs = oldChunk
            settings.transcriptionEngine = oldFinal; settings.showMiniRecordingView = oldMini
            settings.profiles = oldProfiles; settings.activeProfileId = oldActive
            settings.automaticProfileId = oldAutomatic; settings.automaticProfileRecordingID = oldAutomaticOwner
        }
        let profile = MeetingProfile(name: "Model-free capture")
        settings.profiles = [profile]; settings.activeProfileId = profile.id
        settings.automaticProfileId = nil; settings.automaticProfileRecordingID = nil
        settings.liveTranscriptionEnabled = true; settings.liveTranscriptionEngine = .nemotron
        settings.nemotronLiveLanguage = .auto; settings.nemotronLiveChunkMs = 1120
        settings.transcriptionEngine = .localWhisper; settings.showMiniRecordingView = false
        state = AppState(liveResourceProfiles: [.init(id: "fixture",hardware: "fixture",modelRevision: "fixture-asr",
            chunkMs: 1120,sourceCount: 1,qualificationID: "model-free",asrBytes: 500,attributionBytes: nil,headroomBytes: 100,
            concurrentChatModels: [:],backgroundWorkQualified: false,asr: ASRAssetsFixture.identity())])
        let state = state
        let admission = LiveModelJobAdmission(policy: state.liveModelResources,measurement: { .init(availableBytes: 2000,pressure: .normal) })
        ordinary = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),supportBase: files.root,
            environment: ["STUB_MODE":"echo"],resourceAdmission: admission)
        let ordinary = ordinary
        let factory = LiveRecordingFactory(registry: state.liveRecordingSessions,admission: admission,
            beforeAdmission: { await ordinary.prepareForLiveCapture() },makeTransport: { input in
                probe.input = input
                return .live(MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
                    supportBase: files.root,environment: ["STUB_MODE":"live-normal"],role: .live))
            },makeASRAssets: { selection in
                try files.assets(budget: stagingBudget,probe: { point,_ in if holdCopy, point == .afterCreateDirectory { await copyGate.hold() } },
                    identity: selection.identity)
            })
        let (mic,micOutput) = AsyncStream<LiveAudioBuffer>.makeStream(), (system,systemOutput) = AsyncStream<LiveAudioBuffer>.makeStream()
        let hardware = CaptureCoordinator.Hardware(start: { request,_ in
            probe.request = request; return .init(mic: mic,system: system)
        },stop: { micOutput.finish(); systemOutput.finish() },snapshot: { .init(microphoneEnabled: true) },
            pause: {},resume: {},switchInputDevice: { _ in },permissions: .init(microphone: { true },systemAudio: { false }))
        let persistence = CaptureCoordinator.Persistence(create: { id,date in
            await probe.holdCreate()
            return .init(id: id,startedAt: date,files: .init(directoryURL: files.root,
                manifestURL: files.root.appendingPathComponent("session.json"),captureBaseURL: files.root.appendingPathComponent("capture")))
        },began: { _,_ in },failedStart: { _,_,_ in },stopped: { session,state,_ in
            .init(session: session,state: state,fileSize: 0,duration: 0)
        },termination: { _ in },pauseResume: { _,_,_ in })
        manager = RecordingManager(appState: state,appSettings: settings,transcriptStore: .init(),insightsStore: .init(),
            voiceLibraryStore: .init(url: files.root.appendingPathComponent("voices.json")),
            modelPerformanceStore: .init(url: files.root.appendingPathComponent("performance.json")),
            processingJobStore: .init(rootURL: files.root.appendingPathComponent("jobs")),microsoftAuthService: .init(),
            captureHardware: hardware,capturePersistence: persistence,liveFactory: factory,mlHost: ordinary,
            liveSelectionProvider: { language,chunk,sources in
                .init(profileID: "fixture",hardware: "fixture",sourceDirectory: files.source,identity: ASRAssetsFixture.identity(),
                    language: language,chunkMs: chunk,sources: sources,captureQualified: true)
            })
    }
    func clean() async {
        probe.releaseCreate(); await copyGate.release()
        await manager.prepareForTermination(); await ordinary.shutdown()
        await ordinary.prepareForLiveCapture()
        let end = ContinuousClock.now.advanced(by: TestTiming.asyncDeadline)
        while ContinuousClock.now < end {
            let usage = stagingBudget.usage
            if await state.liveModelResources.reservedBytes == 0, usage.workers == 0, usage.roots == 0, files.staged.isEmpty {
                restore(); files.remove(); return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        restore()
        Issue.record("Fixture retirement did not finish; its staging files were preserved for diagnosis")
    }
}

@MainActor @Suite(.serialized) struct LiveRecordingManagerIntegrationTests {
    private func withFixture(holdCopy: Bool = false,_ body: (LiveManagerFixture) async throws -> Void) async throws {
        let fixture = try LiveManagerFixture(holdCopy: holdCopy)
        do { try await body(fixture); await fixture.clean() }
        catch { await fixture.clean(); throw error }
    }
    private func eventually(_ condition: @escaping @MainActor () async -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: TestTiming.asyncDeadline)
        while ContinuousClock.now < end { if await condition() { return true }; try? await Task.sleep(for: .milliseconds(2)) }
        return await condition()
    }

    @Test func actualManagerFreezesSelectionBeforePersistenceAndStartsTheExistingLiveHelper() async throws {
        try await withFixture { f in
        let start = Task { try await f.manager.startRecording() }
        try #require(await eventually { f.probe.createEntered })
        f.settings.liveTranscriptionEngine = .appleSpeech; f.settings.nemotronLiveLanguage = .nl
        f.settings.nemotronLiveChunkMs = 2240; f.settings.transcriptionEngine = .appleSpeech
        f.probe.releaseCreate(); try await start.value
        let request = try #require(f.probe.request), input = try #require(f.probe.input)
        #expect(request.liveEngine == .nemotron && request.language == "auto")
        #expect(request.nemotronSelection?.sources == [.microphone] && request.nemotronSelection?.chunkMs == 1120)
        #expect(request.prewarmWhisper == nil)
        #expect(request.liveIngress?.input == input && input.identity.recordingID == f.state.currentRecording?.id)
        let entry = try #require(f.state.liveRecordingSessions.entry(identity: input.identity))
        #expect(await eventually { await entry.coordinator?.readySources == Set([.microphone]) })
        #expect(FileManager.default.fileExists(atPath: input.configuration.modelDirectory))
        #expect(input.configuration.modelDirectory != f.files.source.path)
        await f.manager.prepareForTermination()
        #expect(entry.captureClosed)
        #expect(await entry.store.projection().isClosed)
        #expect(await eventually { await f.state.liveModelResources.reservedBytes == 0 })
        #expect(await eventually { f.files.staged.isEmpty })
        #expect(f.state.currentRecording?.id == input.identity.recordingID)
        await f.ordinary.shutdown()
        }
    }

    @Test func heldLiveCopyStartsAudioWithoutAutomaticWhisperCompetitionAndStopDoesNotJoinIt() async throws {
        try await withFixture(holdCopy: true) { f in
        let start = Task { try await f.manager.startRecording() }
        try #require(await eventually { f.probe.createEntered })
        f.probe.releaseCreate(); try await start.value
        try #require(await eventually { await f.copyGate.entered })
        let request = try #require(f.probe.request), input = try #require(f.probe.input)
        #expect(f.state.recordingState == .recording)
        #expect(request.prewarmWhisper == nil)
        #expect(await f.state.liveModelResources.jobCount == 0)
        await f.manager.prepareForTermination()
        #expect(f.state.recordingState == .idle)
        #expect(f.state.liveRecordingSessions.entry(identity: input.identity)?.captureClosed == true)
        await f.copyGate.release()
        #expect(await eventually { f.files.staged.isEmpty })
        await f.ordinary.shutdown()
        }
    }
}
