import Foundation
import AVFoundation
import Testing
@testable import dBriefWire
@testable import dBrief

@MainActor private final class LiveManagerProbe {
    var createEntered = false
    var request: CaptureCoordinator.Request?
    var input: LiveSessionBegin?
    var liveSink: (@Sendable (CaptureLivePreview.Event) -> Void)?
    var previewStops = 0
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
    let capturedTrack: URL?
    let privacyStore: PrivacyReceiptStore
    private let restore: () -> Void

    init(holdCopy: Bool = false, engine: LiveTranscriptionEngine = .nemotron, syntheticAudio: Bool = false, realManifest: Bool = false,
         stage: @escaping @Sendable (LiveArtifactStage) async throws -> Void = { _ in },
         deletionFiles: ProcessingPipeline.DeletionFiles = .init(),
         richStore: TranscriptStore = .init()) throws {
        files = try ASRAssetsFixture()
        privacyStore = PrivacyReceiptStore(gapDirectoryURL: files.root.appendingPathComponent("gaps"),
            pendingDirectoryURL: files.root.appendingPathComponent("pending"))
        let captureDirectory = files.root.appendingPathComponent("CaptureSession")
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        if syntheticAudio {
            let track = captureDirectory.appendingPathComponent("capture.mic.caf")
            let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = 16_000
            let samples = try #require(buffer.floatChannelData)[0]
            for index in 0..<16_000 { samples[index] = 0 }
            let writer = AudioTrackWriter(url: track, role: .mic)
            try writer.write(buffer); writer.close(); capturedTrack = track
        } else { capturedTrack = nil }
        let settings = settings, files = files, probe = probe, copyGate = copyGate, stagingBudget = stagingBudget
        let capturedTrack = capturedTrack
        let oldLive = settings.liveTranscriptionEnabled, oldEngine = settings.liveTranscriptionEngine
        let oldLanguage = settings.nemotronLiveLanguage, oldChunk = settings.nemotronLiveChunkMs
        let oldFinal = settings.transcriptionEngine, oldMini = settings.showMiniRecordingView
        let oldProfiles = settings.profiles, oldActive = settings.activeProfileId
        let oldAutomatic = settings.automaticProfileId, oldAutomaticOwner = settings.automaticProfileRecordingID
        let oldFolder = settings.recordingFolderURL
        restore = {
            settings.liveTranscriptionEnabled = oldLive; settings.liveTranscriptionEngine = oldEngine
            settings.nemotronLiveLanguage = oldLanguage; settings.nemotronLiveChunkMs = oldChunk
            settings.transcriptionEngine = oldFinal; settings.showMiniRecordingView = oldMini
            settings.profiles = oldProfiles; settings.activeProfileId = oldActive
            settings.automaticProfileId = oldAutomatic; settings.automaticProfileRecordingID = oldAutomaticOwner
            settings.recordingFolderURL = oldFolder
        }
        let profile = MeetingProfile(name: "Model-free capture", overrides: .init(aiProcessingEnabled: false,
            transcriptionFolderPath: files.root.appendingPathComponent("Transcripts").path))
        settings.profiles = [profile]; settings.activeProfileId = profile.id
        settings.automaticProfileId = nil; settings.automaticProfileRecordingID = nil
        settings.liveTranscriptionEnabled = true; settings.liveTranscriptionEngine = engine
        settings.nemotronLiveLanguage = .auto; settings.nemotronLiveChunkMs = 1120
        settings.transcriptionEngine = .localWhisper; settings.showMiniRecordingView = false
        settings.recordingFolderURL = files.root.appendingPathComponent("Recordings")
        state = AppState(liveResourceProfiles: [.init(id: "fixture",hardware: "fixture",modelRevision: "fixture-asr",
            chunkMs: 1120,sourceCount: 1,qualificationID: "model-free",asrBytes: 500,attributionBytes: nil,headroomBytes: 100,
            concurrentChatModels: [:],backgroundWorkQualified: false,asr: ASRAssetsFixture.identity())],
            liveArtifactRoot: files.root.appendingPathComponent("LiveSessions"), liveArtifactCaptureEnabled: true, liveArtifactStage: stage)
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
        },stop: { micOutput.finish(); systemOutput.finish() },snapshot: {
            .init(tracks: capturedTrack.map { .init(systemURL: nil, micURL: $0) }, duration: capturedTrack == nil ? 0 : 1, microphoneEnabled: true)
        },
            pause: {},resume: {},switchInputDevice: { _ in },permissions: .init(microphone: { true },systemAudio: { false }))
        let persistence = CaptureCoordinator.Persistence(create: { id,date in
            await probe.holdCreate()
            if realManifest {
                try InterruptedSessionStore.write(.init(id: id, startedAt: date, state: .capturing,
                    tracks: [.init(kind: .microphone, relativePath: "capture.mic.caf")]),
                    to: captureDirectory.appendingPathComponent("session.json"))
            }
            return .init(id: id,startedAt: date,files: .init(directoryURL: captureDirectory,
                manifestURL: captureDirectory.appendingPathComponent("session.json"),captureBaseURL: captureDirectory.appendingPathComponent("capture")))
        },began: { _,_ in },failedStart: { _,_,_ in },stopped: { session,state,_ in
            .init(session: session,state: state,fileSize: capturedTrack == nil ? 0 : 64_000,duration: state.duration)
        },termination: { _ in },pauseResume: { _,_,_ in })
        manager = RecordingManager(appState: state,appSettings: settings,transcriptStore: richStore,insightsStore: .init(),
            voiceLibraryStore: .init(url: files.root.appendingPathComponent("voices.json")),
            modelPerformanceStore: .init(url: files.root.appendingPathComponent("performance.json")),
            processingJobStore: .init(rootURL: files.root.appendingPathComponent("jobs")),microsoftAuthService: .init(),
            deletionFiles: deletionFiles, deletionPrivacyStore: privacyStore,
            recordingFinalizer: .init(resolveFFmpeg: { nil }), reprocessingStore: .init(root: files.root.appendingPathComponent("reprocessing")),
            integrationDeliveryStore: .init(rootURL: files.root.appendingPathComponent("deliveries")),
            captureHardware: hardware,capturePersistence: persistence,liveFactory: factory,
            capturePreview: .init(prepare: { _ in nil }, make: {
                .init(start: { _, emit in await MainActor.run { probe.liveSink = emit } },
                    stop: { await MainActor.run { probe.previewStops += 1 } })
            }), mlHost: ordinary,
            liveSelectionProvider: { language,chunk,sources in
                .init(profileID: "fixture",hardware: "fixture",sourceDirectory: files.source,identity: ASRAssetsFixture.identity(),
                    language: language,chunkMs: chunk,sources: sources,captureQualified: true)
            })
    }
    func clean() async {
        probe.releaseCreate(); await copyGate.release()
        await manager.prepareForTermination(); await ordinary.shutdown()
        if let id = probe.request?.id, let entry = state.liveRecordingSessions.entry(recordingID: id) {
            try? await entry.artifacts.flush(); try? state.liveRecordingSessions.retire(entry.identity)
        }
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

    private func prepareForDeletion(_ f: LiveManagerFixture, bound: Bool) async throws -> (Recording, LiveRecordingSessionRegistry.Entry, URL, URL) {
        let start = Task { try await f.manager.startRecording() }
        try #require(await eventually { f.probe.createEntered }); f.probe.releaseCreate(); try await start.value
        let recording = try #require(f.state.currentRecording)
        try #require(await eventually { f.probe.liveSink != nil })
        f.probe.liveSink?(.finalized([.init(start: 0, end: 1, text: "Preserve owned evidence", speaker: "You")]))
        try #require(await eventually { !f.state.liveTranscriptSegments.isEmpty })
        await f.manager.stopRecording()
        if bound { await f.manager.skipProcessing() }
        let entry = try #require(f.state.liveRecordingSessions.entry(recordingID: recording.id))
        _ = try await entry.artifacts.loadChat()
        try entry.artifacts.saveChat(.init(messages: [.init(role: .user, content: "Preserve the conversation")]), urgent: true)
        try await entry.artifacts.flush()
        let audio = try #require(bound ? recording.finalizedAudioURL : f.capturedTrack)
        let history = bound ? audio.deletingPathExtension().appendingPathExtension("chat.json")
            : f.files.root.appendingPathComponent("LiveSessions/\(entry.identity.captureSessionID.uuidString)/chat.json")
        return (recording, entry, audio, history)
    }

    @Test(arguments: [false, true])
    func failedDeletionIntentKeepsTheActualManagerOwnerHistoryAndAudio(bound: Bool) async throws {
        let fault = LiveArtifactFault(stage: .deletionIntent)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, stage: { try await fault.check($0) })
        do {
            let (recording, entry, audio, history) = try await prepareForDeletion(f, bound: bound)
            let savedAudio = try Data(contentsOf: audio), savedHistory = try Data(contentsOf: history)
            if bound { await #expect(throws: (any Error).self) { try await f.manager.deleteRecording(audio) } }
            else { await f.manager.discardRecording() }
            #expect(f.state.liveRecordingSessions.entry(recordingID: recording.id) === entry)
            #expect(entry.isValid && !f.state.liveRecordingSessions.isRetired(recordingID: recording.id))
            #expect(FileManager.default.fileExists(atPath: audio.path))
            #expect(FileManager.default.fileExists(atPath: history.path))
            #expect(try Data(contentsOf: audio) == savedAudio)
            #expect(try Data(contentsOf: history) == savedHistory)
            if !bound { #expect(f.state.currentRecording === recording && f.state.showPostRecordingSheet) }
            #expect(try await LiveSessionArtifactStore(identity: entry.identity,
                rootURL: f.files.root.appendingPathComponent("LiveSessions")).recover().deleted == false)
            // A failed intent is directly retryable, without invalidating the
            // valid history or falsely treating it as a failed chat save.
            if bound { try await f.manager.deleteRecording(audio) } else { await f.manager.discardRecording() }
            #expect(!FileManager.default.fileExists(atPath: audio.path))
            #expect(!FileManager.default.fileExists(atPath: history.path))
            #expect(f.state.liveRecordingSessions.isRetired(recordingID: recording.id))
            #expect(!f.state.liveRecordingSessions.hasPendingDeletion(recordingID: recording.id))
            if !bound { #expect(f.state.currentRecording == nil && !f.state.showPostRecordingSheet) }
            #expect(try await LiveSessionArtifactStore(identity: entry.identity,
                rootURL: f.files.root.appendingPathComponent("LiveSessions")).recover().deleted)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test(arguments: [false, true])
    func verifiedIntentRetiresTheActualManagerOwnerBeforeHeldCleanupAndRetry(bound: Bool) async throws {
        let gate = LiveArtifactGate(stage: .deletionCleanup), fault = LiveArtifactFault(stage: .deletionCleanup)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, stage: {
            try await gate.enter($0); try await fault.check($0)
        })
        var heldDeletion: Task<Bool, Never>?
        do {
            let (recording, entry, audio, history) = try await prepareForDeletion(f, bound: bound)
            let audioBytes = try Data(contentsOf: audio), historyBytes = try Data(contentsOf: history)
            let unrelated = f.files.root.appendingPathComponent("unrelated.m4a")
            try Data([8, 9]).write(to: unrelated)
            let deletion = Task { () -> Bool in
                if bound { do { try await f.manager.deleteRecording(audio); return true } catch { return false } }
                await f.manager.discardRecording(); return !f.state.showPostRecordingSheet
            }
            heldDeletion = deletion
            try await gate.waitForArrival()
            #expect(!entry.isValid && f.state.liveRecordingSessions.isRetired(recordingID: recording.id))
            #expect(f.state.liveRecordingSessions.entry(recordingID: recording.id) == nil)
            #expect(f.state.liveRecordingSessions.hasPendingDeletion(recordingID: recording.id))
            #expect(try Data(contentsOf: audio) == audioBytes && Data(contentsOf: history) == historyBytes)
            #expect(throws: (any Error).self) { try entry.artifacts.saveChat(.init(messages: []), urgent: true) }
            deletion.cancel(); await gate.release()
            #expect(await deletion.value == false)
            #expect(try Data(contentsOf: audio) == audioBytes)
            #expect(f.state.liveRecordingSessions.hasPendingDeletion(recordingID: recording.id))
            if !bound { #expect(f.state.currentRecording === recording && f.state.showPostRecordingSheet) }
            if bound { try await f.manager.deleteRecording(audio) } else { await f.manager.discardRecording() }
            #expect(!FileManager.default.fileExists(atPath: audio.path) && !FileManager.default.fileExists(atPath: history.path))
            #expect(!f.state.liveRecordingSessions.hasPendingDeletion(recordingID: recording.id))
            #expect(try Data(contentsOf: unrelated) == Data([8, 9]))
            #expect(try await LiveSessionArtifactStore(identity: entry.identity,
                rootURL: f.files.root.appendingPathComponent("LiveSessions")).recover().deleted)
            await f.clean()
        } catch { await gate.release(); _ = await heldDeletion?.value; await f.clean(); throw error }
    }

    @Test(arguments: ["master", "metadata", "snapshot"])
    func actualLibraryDeletionRejectsAForeignOwnerAtThePhysicalRemovalBoundary(replace: String) async throws {
        let gate = LiveArtifactGate(stage: .deletionCleanup)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true,
            deletionFiles: .init(beforeRemoval: { try await gate.enter(.deletionCleanup) }))
        var heldDeletion: Task<Bool, Never>?
        do {
            let (recording, _, audio, history) = try await prepareForDeletion(f, bound: true)
            let date = Date()
            let job = PersistedProcessingJob(id: UUID(), recordingID: recording.id, createdAt: date, updatedAt: date, status: .completed,
                request: .init(transcribe: true, summary: false, actionItems: false, tags: false, titleWasUserProvided: false, autoResume: false),
                source: .init(recordingDate: date, duration: 1, fileSize: 3, meetingTitle: "Fixture", participants: [],
                    echoSuppressionApplied: false, finalizedAudioPath: audio.path, segmentAudioPaths: []))
            try await f.manager.processingJobStore.save(job)
            let deletion = Task { do { try await f.manager.deleteRecording(audio); return true } catch { return false } }
            heldDeletion = deletion
            try await gate.waitForArrival()
            #expect(f.state.liveRecordingSessions.hasPendingDeletion(recordingID: recording.id))
            #expect(!FileManager.default.fileExists(atPath: history.path))
            let replacedURL = replace == "snapshot" ? f.files.root.appendingPathComponent("jobs/\(job.id.uuidString.lowercased())/job.json")
                : replace == "metadata" ? audio.deletingPathExtension().appendingPathExtension("json") : audio
            let replacement: Data
            if replace != "master" {
                var metadata = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: replacedURL)) as? [String: Any])
                metadata["recordingID"] = UUID().uuidString
                replacement = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            } else { replacement = Data("A different recording at the same name".utf8) }
            try replacement.write(to: replacedURL, options: .atomic)
            await gate.release(); #expect(await deletion.value == false)
            #expect(try Data(contentsOf: replacedURL) == replacement)
            await #expect(throws: (any Error).self) { try await f.manager.deleteRecording(audio) }
            #expect(try Data(contentsOf: replacedURL) == replacement)
            #expect(try await f.manager.processingJobStore.load(id: job.id) != nil)
            #expect(f.state.liveRecordingSessions.hasPendingDeletion(recordingID: recording.id))
            await f.clean()
        } catch { await gate.release(); _ = await heldDeletion?.value; await f.clean(); throw error }
    }

    @Test(arguments: [false, true])
    func actualLibraryRetryRetainsPendingPrivacyTargetsAfterMetadataAndSnapshotsAreGone(bound: Bool) async throws {
        let fault = LiveArtifactFault(stage: .deletionCleanup)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, realManifest: !bound,
            deletionFiles: .init(removeEvidence: { store, ticket in
                try await fault.check(.deletionCleanup); try await store.removeEvidence(afterDeletion: ticket)
            }))
        do {
            let (recording, _, audio, _) = try await prepareForDeletion(f, bound: bound)
            let scope = RecordingPrivacyScope(recordingID: recording.id, store: f.privacyStore,
                pendingRootURL: f.files.root.appendingPathComponent("pending"))
            let operation = PrivacyOperation(stage: .transcription, data: [.recordingAudio], destination: .local(provider: .whisper))
            let token = await PrivacyTrace.begin(operation, in: await scope.context())
            if !bound { recording.privacyScope = scope }
            let date = Date()
            let job = PersistedProcessingJob(id: UUID(), recordingID: recording.id, createdAt: date, updatedAt: date, status: .completed,
                request: .init(transcribe: true, summary: false, actionItems: false, tags: false, titleWasUserProvided: false, autoResume: false),
                source: .init(recordingDate: date, duration: 1, fileSize: 3, meetingTitle: "Fixture", participants: [],
                    echoSuppressionApplied: false, finalizedAudioPath: bound ? audio.path : nil, segmentAudioPaths: []))
            if bound { try await f.manager.processingJobStore.save(job) }
            if bound { await #expect(throws: (any Error).self) { try await f.manager.deleteRecording(audio) } }
            else { await f.manager.discardRecording(); #expect(f.state.showPostRecordingSheet) }
            #expect(!FileManager.default.fileExists(atPath: audio.path))
            #expect(!FileManager.default.fileExists(atPath: audio.deletingPathExtension().appendingPathExtension("json").path))
            #expect(FileManager.default.fileExists(atPath: scope.pendingReceiptURL.path))
            #expect(f.state.liveRecordingSessions.hasPendingDeletion(recordingID: recording.id))
            if bound { #expect(try await f.manager.processingJobStore.load(id: job.id) == nil) }
            if bound { try await f.manager.deleteRecording(audio) } else { await f.manager.discardRecording() }
            #expect(!f.state.liveRecordingSessions.hasPendingDeletion(recordingID: recording.id))
            #expect(!FileManager.default.fileExists(atPath: scope.pendingReceiptURL.path))
            await PrivacyTrace.finish(token, outcome: .succeeded)
            #expect(!FileManager.default.fileExists(atPath: scope.pendingReceiptURL.path))
            #expect(try await f.privacyStore.begin(operation, runID: UUID(), at: scope.pendingReceiptURL) == nil)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    private func prepareFinalForEdits(_ f: LiveManagerFixture) async throws -> (Recording, LiveRecordingSessionRegistry.Entry) {
        let start = Task { try await f.manager.startRecording() }
        try #require(await eventually { f.probe.createEntered }); f.probe.releaseCreate(); try await start.value
        await f.manager.stopRecording(); await f.manager.skipProcessing()
        let recording = try #require(f.state.currentRecording), audio = try #require(recording.finalizedAudioURL)
        let richURL = try #require(recording.transcriptSidecarURL)
        try await f.manager.processingPipeline.saveTranscript(.init(text: "Original", segments: [.init(start: 0, end: 1, text: "Original")]),
            to: audio.deletingPathExtension().appendingPathExtension("transcript.json"))
        let job = f.manager.launchJob(recording: recording, persistedRequest: .init(transcribe: true, summary: false,
            actionItems: false, tags: false, titleWasUserProvided: true, autoResume: false)) { job in
            await f.manager.processRecording(job: job, transcribe: true, summary: false, actionItems: false, tags: false, stopBeforeIntegrations: true)
        }
        await job.task?.value
        #expect(recording.transcriptSidecarURL?.standardizedFileURL.path == richURL.standardizedFileURL.path)
        let entry = try #require(f.state.liveRecordingSessions.entry(recordingID: recording.id))
        try await entry.artifacts.flush()
        return (recording, entry)
    }

    @Test func failedUnboundDeleteAllowsTheActualManagerToSkipAndBindItsHealthyOwner() async throws {
        let fault = LiveArtifactFault(stage: .deletionIntent)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, stage: { try await fault.check($0) })
        do {
            let (recording, entry, _, _) = try await prepareForDeletion(f, bound: false)
            await f.manager.discardRecording()
            #expect(f.state.currentRecording === recording && f.state.showPostRecordingSheet && entry.isValid)
            await f.manager.skipProcessing()
            #expect(!f.state.showPostRecordingSheet)
            let audio = try #require(recording.finalizedAudioURL)
            #expect(FileManager.default.fileExists(atPath: audio.path))
            #expect(f.state.liveRecordingSessions.entry(recordingID: recording.id) === entry && entry.isValid)
            try await entry.artifacts.flush()
            #expect(await entry.artifacts.writer.status().audioURL != nil)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test(arguments: ["metadata", "unrelatedDelivery"])
    func oversizedDeletionInputsPreserveTheActualManagerOwnerAndFilesBeforeIntent(kind: String) async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let (recording, entry, audio, history) = try await prepareForDeletion(f, bound: true)
            let audioBytes = try Data(contentsOf: audio), historyBytes = try Data(contentsOf: history)
            let largeURL: URL
            if kind == "metadata" {
                largeURL = audio.deletingPathExtension().appendingPathExtension("json")
                var value = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: largeURL)) as? [String: Any])
                value["participants"] = [String](repeating: "", count: 20_000)
                let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                #expect(bytes.count < 65_536)
                try bytes.write(to: largeURL, options: .atomic)
            } else {
                let batch = IntegrationDeliveryBatch(id: UUID(), recordingID: UUID(), createdAt: Date(),
                    bundle: .init(title: "Unrelated", createdAt: Date(), durationSeconds: 60,
                        audioFileURL: f.files.root.appendingPathComponent("unrelated.m4a"), transcript: "Transcript", summary: "Summary",
                        actionItems: [], tags: [], sentiment: nil, markdown: String(repeating: "x", count: 2 * 1_024 * 1_024), calendarEvent: nil),
                    deliveries: [])
                let directory = f.files.root.appendingPathComponent("deliveries")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                largeURL = directory.appendingPathComponent(batch.id.uuidString.lowercased() + ".json")
                try JSONEncoder().encode(batch).write(to: largeURL)
            }
            let original = try Data(contentsOf: largeURL)
            await #expect(throws: LiveArtifactError.artifactTooLarge) { try await f.manager.deleteRecording(audio) }
            #expect(entry.isValid && f.state.liveRecordingSessions.entry(recordingID: recording.id) === entry)
            #expect(!f.state.liveRecordingSessions.hasPendingDeletion(recordingID: recording.id))
            #expect(try Data(contentsOf: largeURL) == original)
            #expect(try Data(contentsOf: audio) == audioBytes && Data(contentsOf: history) == historyBytes)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func actualDeleteSealsAHeldEditorBeforeFreezingFilesAndWaitingForIntent() async throws {
        let editGate = LiveArtifactGate(stage: .sourceTranscript, initiallyEnabled: false)
        let intentGate = LiveArtifactGate(stage: .deletionIntent)
        let store = TranscriptStore(beforeOwnedSave: { try? await editGate.enter(.sourceTranscript) })
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true,
            stage: { try await intentGate.enter($0) }, richStore: store)
        var heldEdit: Task<Void, any Error>?, heldDeletion: Task<Void, any Error>?
        do {
            let (recording, entry) = try await prepareFinalForEdits(f)
            let audio = try #require(recording.finalizedAudioURL), richURL = try #require(recording.transcriptSidecarURL)
            let original = try Data(contentsOf: richURL)
            var edit = try await store.load(from: richURL); edit.segments[0].text = "Held old edit"
            let value = edit, revision = f.manager.reprocessingResultsRevision
            await editGate.arm()
            let save = Task { try await f.manager.saveEditedTranscript(value, for: recording, expectedRevision: revision) }; heldEdit = save
            try await editGate.waitForArrival()
            let deletion = Task { try await f.manager.deleteRecording(audio) }; heldDeletion = deletion
            try await intentGate.waitForArrival()
            #expect(entry.isValid && !f.state.liveRecordingSessions.isRetired(recordingID: recording.id))
            await editGate.release()
            await #expect(throws: CancellationError.self) { try await save.value }
            #expect(try Data(contentsOf: richURL) == original)
            await intentGate.release(); try await deletion.value
            #expect(!FileManager.default.fileExists(atPath: audio.path) && !FileManager.default.fileExists(atPath: richURL.path))
            #expect(!f.state.liveRecordingSessions.hasPendingDeletion(recordingID: recording.id))
            await f.clean()
        } catch {
            await editGate.release(); await intentGate.release()
            _ = try? await heldEdit?.value; _ = try? await heldDeletion?.value
            await f.clean(); throw error
        }
    }

    @Test func actualManagerDeletionSaturationKeepsSnapshotsAndTheHealthyOwner() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let (recording, entry, audio, history) = try await prepareForDeletion(f, bound: true)
            let date = Date()
            var ids: [UUID] = []
            for _ in 0..<129 {
                let job = PersistedProcessingJob(id: UUID(), recordingID: recording.id, createdAt: date, updatedAt: date, status: .completed,
                    request: .init(transcribe: true, summary: false, actionItems: false, tags: false, titleWasUserProvided: false, autoResume: false),
                    source: .init(recordingDate: date, duration: 1, fileSize: 3, meetingTitle: "Fixture", participants: [],
                        echoSuppressionApplied: false, finalizedAudioPath: audio.path, segmentAudioPaths: []))
                try await f.manager.processingJobStore.save(job); ids.append(job.id)
            }
            await #expect(throws: LiveArtifactError.artifactTooLarge) { try await f.manager.deleteRecording(audio) }
            #expect(entry.isValid && f.state.liveRecordingSessions.entry(recordingID: recording.id) === entry)
            #expect(FileManager.default.fileExists(atPath: audio.path) && FileManager.default.fileExists(atPath: history.path))
            for id in ids { #expect(try await f.manager.processingJobStore.load(id: id) != nil) }
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func actualOwnedDeleteUsesItsLeaseAtCapacityWhileLegacyDefersBeforeInspection() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let (_, entry, audio, _) = try await prepareForDeletion(f, bound: true)
            let registry = f.state.liveRecordingSessions
            for _ in 0..<3 { _ = try registry.registerLegacy(.init(recordingID: UUID(), captureSessionID: UUID())) }
            #expect(registry.reservedPayloadBytes == 128 * 1_024 * 1_024)
            let legacy = f.files.root.appendingPathComponent("legacy.m4a")
            try Data([1]).write(to: legacy)
            // An unsafe header would fail differently if inspection preceded
            // admission; it must never be opened at aggregate capacity.
            let metadata = legacy.deletingPathExtension().appendingPathExtension("json")
            try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: audio)
            await #expect(throws: LiveRecordingSessionRegistry.Failure.capacity) { try await f.manager.deleteRecording(legacy) }
            #expect(FileManager.default.fileExists(atPath: legacy.path) && entry.isValid)
            try await f.manager.deleteRecording(audio)
            #expect(!FileManager.default.fileExists(atPath: audio.path))
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func actualDeleteRetryKeepsItsOriginalReceiptWhenTheRequestedDirectoryAliasChanges() async throws {
        let fault = LiveArtifactFault(stage: .deletionCleanup)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true,
            deletionFiles: .init(beforeRemoval: { try await fault.check(.deletionCleanup) }))
        do {
            let (_, _, audio, _) = try await prepareForDeletion(f, bound: true)
            let alias = f.files.root.appendingPathComponent("library-alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: audio.deletingLastPathComponent())
            let requested = alias.appendingPathComponent(audio.lastPathComponent)
            await #expect(throws: LiveArtifactFixtureFailure.injected) { try await f.manager.deleteRecording(requested) }
            let otherDirectory = f.files.root.appendingPathComponent("other-library")
            try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
            let foreign = otherDirectory.appendingPathComponent(audio.lastPathComponent), bytes = Data("Foreign recording".utf8)
            try bytes.write(to: foreign)
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: otherDirectory)
            try await f.manager.deleteRecording(requested)
            #expect(!FileManager.default.fileExists(atPath: audio.path))
            #expect(try Data(contentsOf: foreign) == bytes)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func reprocessingAdmissionForAnotherRecordingDoesNotRetireAHealthyPreparationWrite() async throws {
        let gate = LiveArtifactGate(stage: .sourceTranscript)
        let store = TranscriptStore(beforeOwnedSave: { try? await gate.enter(.sourceTranscript) })
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, richStore: store)
        var job: ProcessingJob?
        do {
            let start = Task { try await f.manager.startRecording() }
            try #require(await eventually { f.probe.createEntered }); f.probe.releaseCreate(); try await start.value
            await f.manager.stopRecording(); await f.manager.skipProcessing()
            let recording = try #require(f.state.currentRecording), audio = try #require(recording.finalizedAudioURL)
            try await f.manager.processingPipeline.saveTranscript(.init(text: "Healthy preparation", segments: [.init(start: 0, end: 1, text: "Healthy preparation")]),
                to: audio.deletingPathExtension().appendingPathExtension("transcript.json"))
            let processing = f.manager.launchJob(recording: recording, persistedRequest: .init(transcribe: true, summary: false,
                actionItems: false, tags: false, titleWasUserProvided: true, autoResume: false)) { job in
                    await f.manager.processRecording(job: job, transcribe: true, summary: false, actionItems: false, tags: false, stopBeforeIntegrations: true)
                }; job = processing
            try await gate.waitForArrival()
            // This is the synchronous hook used when admitting B while A is
            // processing; B's queued work cannot own A's rich generation.
            f.manager.reprocessingAdmissionBusy = true
            f.manager.reprocessingAdmissionBusy = false
            await gate.release(); await processing.task?.value
            #expect(processing.persistedRecord?.checkpoint.hasCompleted(.diarized) == true)
            let entry = try #require(f.state.liveRecordingSessions.entry(recordingID: recording.id))
            #expect(try entry.artifacts.finalContext()?.segments.map(\.text) == ["Healthy preparation"])
            try await entry.artifacts.flush(); await f.clean()
        } catch { await gate.release(); await job?.task?.value; await f.clean(); throw error }
    }

    @Test func delayedEarlierVerifiedEditCannotPublishOverANewerVerifiedEdit() async throws {
        let gate = LiveArtifactGate(stage: .sourceTranscript, initiallyEnabled: false)
        let store = TranscriptStore(afterOwnedSave: { try? await gate.enter(.sourceTranscript) })
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, richStore: store)
        var earlier: Task<Void, any Error>?
        do {
            let (recording, entry) = try await prepareFinalForEdits(f), url = try #require(recording.transcriptSidecarURL)
            var first = try await store.load(from: url); first.segments[0].text = "Earlier saved edit"
            var second = first; second.segments[0].text = "Latest saved edit"
            let a = first, b = second, revision = f.manager.reprocessingResultsRevision
            await gate.arm()
            let task = Task { try await f.manager.saveEditedTranscript(a, for: recording, expectedRevision: revision) }; earlier = task
            try await gate.waitForArrival()
            try await f.manager.saveEditedTranscript(b, for: recording, expectedRevision: revision)
            await gate.release()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.load(from: url) == b)
            #expect(try entry.artifacts.finalContext()?.segments.map(\.text) == ["Latest saved edit"])
            try await entry.artifacts.flush()
            #expect(try await LiveSessionArtifactStore(identity: entry.identity,
                rootURL: f.files.root.appendingPathComponent("LiveSessions")).recover().appTranscript?.finalContext()?.segments.map(\.text) == ["Latest saved edit"])
            await f.clean()
        } catch { await gate.release(); _ = try? await earlier?.value; await f.clean(); throw error }
    }

    @Test(arguments: ["admission", "chatRetirement", "recovery", "revision"])
    func anEditHeldBeforePhysicalWriteCannotOverwriteReplacementAfterItsClaimReleases(boundary: String) async throws {
        let gate = LiveArtifactGate(stage: .sourceTranscript, initiallyEnabled: false)
        let store = TranscriptStore(beforeOwnedSave: { try? await gate.enter(.sourceTranscript) })
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, richStore: store)
        var edit: Task<Void, any Error>?
        do {
            let (recording, _) = try await prepareFinalForEdits(f), url = try #require(recording.transcriptSidecarURL)
            var old = try await store.load(from: url); old.segments[0].text = "Stale editor preview"
            var replacement = old; replacement.segments[0].text = "Replacement result"
            let stale = old, revision = f.manager.reprocessingResultsRevision, audio = try #require(recording.finalizedAudioURL)
            await gate.arm()
            let task = Task { try await f.manager.saveEditedTranscript(stale, for: recording, expectedRevision: revision) }; edit = task
            try await gate.waitForArrival()
            switch boundary {
            case "admission": f.manager.reprocessingAdmissionBusy = true
            case "chatRetirement": f.manager.invalidateReprocessingChat(audio)
            case "recovery": f.manager.reprocessingRecoveryReady = false
            default: f.manager.reprocessingResultsRevision += 1
            }
            let attempt = UUID()
            try RecordingResultMutation.claim(audioURL: audio, attemptID: attempt)
            do {
                try RecordingResultMutation.withTransaction { try JSONEncoder().encode(replacement).write(to: url, options: .atomic) }
            } catch { RecordingResultMutation.release(audioURL: audio, attemptID: attempt); throw error }
            RecordingResultMutation.release(audioURL: audio, attemptID: attempt)
            f.manager.reprocessingAdmissionBusy = false; f.manager.reprocessingRecoveryReady = true
            await gate.release()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.load(from: url) == replacement)
            await f.clean()
        } catch { await gate.release(); _ = try? await edit?.value; await f.clean(); throw error }
    }

    @Test func actualManagerPublishesOnlyCommittedFinalTextAndKeepsItAfterSpeakerFailureWithoutAWindow() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let start = Task { try await f.manager.startRecording() }
            try #require(await eventually { f.probe.createEntered }); f.probe.releaseCreate(); try await start.value
            try #require(await eventually { f.probe.liveSink != nil })
            f.probe.liveSink?(.finalized([.init(start: 0, end: 1, text: "Original live evidence")]))
            try #require(await eventually { f.state.liveTranscriptSegments.count == 1 })
            await f.manager.stopRecording(); await f.manager.skipProcessing()
            let recording = try #require(f.state.currentRecording)
            let entry = try #require(f.state.liveRecordingSessions.entry(recordingID: recording.id))
            let provider = TranscriptContextProvider.recording(recordingID: recording.id, registry: f.state.liveRecordingSessions,
                legacy: { .legacy(text: "", recordingID: recording.id, speakerLabels: []) })
            let original = provider.freeze()
            let audio = try #require(recording.finalizedAudioURL)
            let rawURL = audio.deletingPathExtension().appendingPathExtension("transcript.json")
            let result = TranscriptionResult(text: "Complete saved text without segment timestamps", segments: [])
            try await f.manager.processingPipeline.saveTranscript(result, to: rawURL)
            try Data("corrupt rich sidecar".utf8).write(to: try #require(recording.transcriptSidecarURL))
            let job = f.manager.launchJob(recording: recording, persistedRequest: .init(transcribe: true, summary: false,
                actionItems: false, tags: false, titleWasUserProvided: true, autoResume: false)) { job in
                await f.manager.processRecording(job: job, transcribe: true, summary: false, actionItems: false, tags: false,
                    stopBeforeIntegrations: true)
            }
            await job.task?.value
            let saved = try #require(try await f.manager.processingJobStore.load(id: job.id))
            #expect(saved.checkpoint.hasCompleted(.transcribed) && saved.failureStage == .diarization)
            let final = try await provider.freeze().snapshot()
            #expect(final.source.version == .final && final.source.scope == .completeFinal)
            #expect(final.source.publicationID != nil && final.source.publicationRevision == 1)
            #expect(final.segments.map(\.text) == [result.text])
            #expect(final.segments.first?.meeting == nil && final.segments.first?.finalPlayback == nil)
            #expect(try await original.snapshot().segments.map(\.text) == ["Original live evidence"])
            try await entry.artifacts.flush()
            let restored = try await LiveSessionArtifactStore(identity: entry.identity,
                rootURL: f.files.root.appendingPathComponent("LiveSessions")).recover()
            #expect(restored.appTranscript?.finalContext() == final && restored.audioURL == audio.standardizedFileURL)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func actualManagerPublishesExactSavedRichIDsAndReviewedNamesWithoutAWindow() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let start = Task { try await f.manager.startRecording() }
            try #require(await eventually { f.probe.createEntered }); f.probe.releaseCreate(); try await start.value
            await f.manager.stopRecording(); await f.manager.skipProcessing()
            let recording = try #require(f.state.currentRecording), audio = try #require(recording.finalizedAudioURL)
            let raw = TranscriptionResult(text: "Saved complete transcript", segments: [.init(start: 0, end: 1,
                text: "Saved complete transcript", speaker: "speaker")])
            try await f.manager.processingPipeline.saveTranscript(raw, to: audio.deletingPathExtension().appendingPathExtension("transcript.json"))
            let segment = RichSegment(start: 0, end: 1, text: "User-edited saved text", originalText: raw.text, speakerId: "speaker")
            let rich = RichTranscript(segments: [segment], speakerLabels: [.init(id: "speaker", displayName: "Reviewed name")])
            try await f.manager.transcriptStore.save(rich, to: try #require(recording.transcriptSidecarURL))
            let job = f.manager.launchJob(recording: recording, persistedRequest: .init(transcribe: true, summary: false,
                actionItems: false, tags: false, titleWasUserProvided: true, autoResume: false)) { job in
                await f.manager.processRecording(job: job, transcribe: true, summary: false, actionItems: false, tags: false,
                    stopBeforeIntegrations: true)
            }
            await job.task?.value
            let entry = try #require(f.state.liveRecordingSessions.entry(recordingID: recording.id))
            try await entry.artifacts.flush()
            let final = try await TranscriptContextProvider.recording(recordingID: recording.id, registry: f.state.liveRecordingSessions,
                legacy: { .legacy(text: "", recordingID: recording.id, speakerLabels: []) }).freeze().snapshot()
            #expect(final.source.version == .final && final.source.publicationRevision == 2)
            #expect(final.segments.first?.id == segment.id.uuidString.lowercased() && final.segments.first?.text == segment.text)
            #expect(final.source.speakerLegend == rich.speakerLabels && final.segments.first?.finalPlayback == .init(start: 0, end: 1))
            let restored = try await LiveSessionArtifactStore(identity: entry.identity,
                rootURL: f.files.root.appendingPathComponent("LiveSessions")).recover()
            #expect(restored.appTranscript?.finalContext() == final)
            let provider = TranscriptContextProvider.recording(recordingID: recording.id, registry: f.state.liveRecordingSessions,
                legacy: { .legacy(text: "", recordingID: recording.id, speakerLabels: []) })
            let oldAnswer = provider.freeze()
            var edited = rich
            edited.segments[0].text = "Durably corrected text"
            edited.speakerLabels[0].displayName = "Corrected name"
            try await f.manager.saveEditedTranscript(edited, for: recording, expectedRevision: f.manager.reprocessingResultsRevision)
            let updated = try await provider.freeze().snapshot()
            #expect(updated.source.publicationID == final.source.publicationID && updated.source.publicationRevision == 3)
            #expect(updated.segments.first?.id == segment.id.uuidString.lowercased() && updated.segments.first?.text == edited.segments[0].text)
            #expect(updated.source.speakerLegend == edited.speakerLabels)
            #expect(try await oldAnswer.snapshot() == final)
            try await entry.artifacts.flush()
            #expect(try await LiveSessionArtifactStore(identity: entry.identity,
                rootURL: f.files.root.appendingPathComponent("LiveSessions")).recover().appTranscript?.finalContext() == updated)
            // Failed and superseded view saves cannot publish their previews.
            let sidecar = try #require(recording.transcriptSidecarURL)
            try FileManager.default.removeItem(at: sidecar)
            try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
            edited.speakerLabels[0].displayName = "Unsaved preview"
            let failedEdit = edited
            await #expect(throws: (any Error).self) {
                try await f.manager.saveEditedTranscript(failedEdit, for: recording, expectedRevision: f.manager.reprocessingResultsRevision)
            }
            await #expect(throws: CancellationError.self) {
                try await f.manager.saveEditedTranscript(failedEdit, for: recording, expectedRevision: f.manager.reprocessingResultsRevision - 1)
            }
            #expect(try await provider.freeze().snapshot() == updated)
            try FileManager.default.removeItem(at: sidecar)
            try await f.manager.transcriptStore.save(rich, to: sidecar)
            try f.state.liveRecordingSessions.retire(entry.identity)
            await #expect(throws: CancellationError.self) {
                try await f.manager.saveEditedTranscript(failedEdit, for: recording, expectedRevision: f.manager.reprocessingResultsRevision)
            }
            #expect(try await f.manager.transcriptStore.load(from: sidecar) == rich)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func actualManagerAdoptsFinalAudioAndBindsWithoutAWindowOrJoiningHeldTranscriptIO() async throws {
        let gate = LiveArtifactGate(stage: .sourceTranscript)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, stage: { try await gate.enter($0) })
        do {
            let start = Task { try await f.manager.startRecording() }
            try #require(await eventually { f.probe.createEntered }); f.probe.releaseCreate(); try await start.value
            try #require(await eventually { f.probe.liveSink != nil })
            f.probe.liveSink?(.finalized([.init(start: 0, end: 1, text: "Owned before finalization")]))
            try #require(await eventually { f.state.liveTranscriptSegments.count == 1 })
            await f.manager.stopRecording()
            let recording = try #require(f.state.currentRecording)
            let entry = try #require(f.state.liveRecordingSessions.entry(recordingID: recording.id))
            try await gate.waitForArrival()
            #expect(f.state.showPostRecordingSheet && !entry.artifacts.isDurable)
            await f.manager.skipProcessing()
            let audio = try #require(recording.finalizedAudioURL)
            #expect(recording.fileURL == audio && FileManager.default.fileExists(atPath: audio.path))
            let metadata = try JSONDecoder().decode(RecordingMetadataPayload.self,
                from: Data(contentsOf: try #require(recording.metadataURL)))
            #expect(metadata.recordingID == recording.id)
            #expect(!entry.artifacts.isDurable)
            await gate.release(); try await entry.artifacts.flush()
            let restart = LiveSessionArtifactStore(identity: entry.identity, rootURL: f.files.root.appendingPathComponent("LiveSessions"))
            let recovered = try await restart.recover()
            #expect(recovered.audioURL == audio.standardizedFileURL)
            #expect(recovered.appTranscript?.captureClosed == true)
            #expect(recovered.appTranscript?.legacy?.first?.text == "Owned before finalization")
            let source = f.files.root.appendingPathComponent("LiveSessions").appendingPathComponent(entry.identity.captureSessionID.uuidString)
            #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent("live-transcript.json").path))
            await f.clean()
        } catch { await gate.release(); await f.clean(); throw error }
    }

    @Test func actualManagerClosesNativeCheckpointWithoutJoiningHeldDiskIOOrOpeningAWindow() async throws {
        let gate = LiveArtifactGate(stage: .sourceTranscript)
        let f = try LiveManagerFixture(stage: { try await gate.enter($0) })
        do {
            let start = Task { try await f.manager.startRecording() }
            try #require(await eventually { f.probe.createEntered }); f.probe.releaseCreate(); try await start.value
            let input = try #require(f.probe.input), entry = try #require(f.state.liveRecordingSessions.entry(identity: input.identity))
            try await gate.waitForArrival()
            let stop = Task { await f.manager.prepareForTermination() }
            try #require(await eventually { f.state.recordingState == .idle })
            #expect(entry.captureClosed && !entry.artifacts.isDurable)
            await stop.value
            await gate.release(); try await entry.artifacts.flush()
            let restart = LiveSessionArtifactStore(identity: input.identity, rootURL: f.files.root.appendingPathComponent("LiveSessions"))
            let value = try #require(try await restart.recover().appTranscript)
            #expect(value.identity == input.identity && value.captureClosed && value.native != nil && value.legacy == nil)
            #expect(await entry.store.projection().isClosed)
            await f.clean()
        } catch { await gate.release(); await f.clean(); throw error }
    }

    @Test func actualManagerRetainsAppleCaptionsThroughStopWithoutAWindow() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech)
        do {
            let start = Task { try await f.manager.startRecording() }
            try #require(await eventually { f.probe.createEntered }); f.probe.releaseCreate(); try await start.value
            try #require(await eventually { f.probe.liveSink != nil })
            let request = try #require(f.probe.request)
            let segment = LiveTranscriptSegment(start: 0, end: 1, text: "Apple evidence owned by recording", speaker: "You")
            f.probe.liveSink?(.finalized([segment]))
            try #require(await eventually { f.state.liveTranscriptSegments.count == 1 })
            await f.manager.prepareForTermination()
            let entry = try #require(f.state.liveRecordingSessions.entry(recordingID: request.id))
            try await entry.artifacts.flush()
            f.state.liveTranscriptSegments = [] // A new view/capture cannot own the only retained copy.
            let context = try await TranscriptContextProvider.recording(recordingID: request.id, registry: f.state.liveRecordingSessions,
                legacy: { .legacy(text: "", recordingID: request.id, speakerLabels: []) }).freeze().snapshot()
            #expect(context.segments.first?.id == segment.id.uuidString.lowercased())
            #expect(context.segments.first?.text == segment.text && context.segments.first?.finalPlayback == nil)
            let restart = LiveSessionArtifactStore(identity: entry.identity, rootURL: f.files.root.appendingPathComponent("LiveSessions"))
            #expect(try await restart.recover().appTranscript?.legacy?.first?.id == segment.id)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func actualManagerDefersSaturatedDerivativeOwnershipBeforeHardwareAndKeepsAudioRunning() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech)
        do {
            for _ in 0..<4 {
                _ = try f.state.liveRecordingSessions.registerLegacy(.init(recordingID: UUID(), captureSessionID: UUID()))
            }
            #expect(f.state.liveRecordingSessions.reservedPayloadBytes == 128 * 1_024 * 1_024)
            let start = Task { try await f.manager.startRecording() }
            try #require(await eventually { f.probe.createEntered }); f.probe.releaseCreate(); try await start.value
            #expect(f.state.recordingState == .recording && f.probe.request != nil)
            #expect(f.probe.liveSink == nil && !f.state.isLiveTranscribing)
            #expect(f.state.durabilityNoticeIsWarning)
            let request = try #require(f.probe.request)
            #expect(f.state.liveRecordingSessions.entry(recordingID: request.id) == nil)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func actualAppleProducerRetiresAtHistoryLimitWhileAudioContinuesAndLateCaptionsAreRefused() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech)
        do {
            let start = Task { try await f.manager.startRecording() }
            try #require(await eventually { f.probe.createEntered }); f.probe.releaseCreate(); try await start.value
            try #require(await eventually { f.probe.liveSink != nil })
            let sink = try #require(f.probe.liveSink)
            sink(.finalized([.init(start: 0, end: 1, text: "Accepted")]))
            try #require(await eventually { f.state.liveTranscriptSegments.count == 1 })
            sink(.finalized((0..<4).map { .init(start: Double($0), end: Double($0 + 1), text: String(repeating: "x", count: 65_536)) }))
            try #require(await eventually { f.probe.previewStops > 0 })
            #expect(f.state.recordingState == .recording && !f.state.isLiveTranscribing)
            sink(.finalized([.init(start: 1, end: 2, text: "Late")]))
            await Task.yield()
            #expect(f.state.liveTranscriptSegments.map(\.text) == ["Accepted"])
            let request = try #require(f.probe.request)
            let entry = try #require(f.state.liveRecordingSessions.entry(recordingID: request.id))
            #expect(try entry.artifacts.legacyContext().segments.map(\.text) == ["Accepted"])
            #expect(entry.artifacts.failure == nil && f.state.durabilityNotice?.contains("history limit") == true)
            try await entry.artifacts.flush()
            let restored = try await LiveSessionArtifactStore(identity: entry.identity, rootURL: f.files.root.appendingPathComponent("LiveSessions")).recover()
            #expect(restored.appTranscript?.legacy?.map(\.text) == ["Accepted"])
            await f.clean()
        } catch { await f.clean(); throw error }
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
