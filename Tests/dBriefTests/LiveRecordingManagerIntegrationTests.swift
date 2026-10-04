import Foundation
import AVFoundation
import Testing
@testable import dBriefWire
@testable import dBrief

private actor ReprocessingHydrationFault {
    private var armed = false
    func arm() { armed = true }
    func check(_ stage: LiveArtifactStage) throws {
        guard armed, stage == .ownerHydration else { return }
        armed = false; throw LiveArtifactFixtureFailure.injected
    }
}

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
         richStore: TranscriptStore = .init(), payloadBudget: LiveRecordingPayloadBudget? = nil,
         artifactPersistence: Bool = true, queueFiles: QueueScheduleStore.Files = .init(),
         reprocessingStage: @escaping @Sendable (ReprocessingStore.PreparationStage) async -> Void = { _ in }) throws {
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
            liveArtifactRoot: files.root.appendingPathComponent("LiveSessions"), liveArtifactCaptureEnabled: artifactPersistence, liveArtifactStage: stage,
            livePayloadBudget: payloadBudget)
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
            recordingFinalizer: .init(resolveFFmpeg: { nil }), reprocessingStore: .init(root: files.root.appendingPathComponent("reprocessing"), preparationStage: reprocessingStage),
            queueScheduleStore: .init(url: files.root.appendingPathComponent("queue-schedule.json"), files: queueFiles),
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

    func restartedManager(captureEnabled: Bool = true, stage: @escaping @Sendable (LiveArtifactStage) async throws -> Void = { _ in }) -> (AppState, RecordingManager) {
        let recoveryRoot = files.root
        let restarted = AppState(liveArtifactRoot: files.root.appendingPathComponent("LiveSessions"), liveArtifactCaptureEnabled: captureEnabled, liveArtifactStage: stage)
        let manager = RecordingManager(appState: restarted, appSettings: settings, transcriptStore: .init(), insightsStore: .init(),
            voiceLibraryStore: .init(url: files.root.appendingPathComponent("voices.json")),
            modelPerformanceStore: .init(url: files.root.appendingPathComponent("performance.json")),
            processingJobStore: .init(rootURL: files.root.appendingPathComponent("jobs")), microsoftAuthService: .init(),
            deletionPrivacyStore: privacyStore,
            recordingFinalizer: .init(resolveFFmpeg: { nil }),
            captureSessionStore: .init(dependencies: .init(root: { recoveryRoot }, duration: { _ in 1 }, record: { _ in })),
            reprocessingStore: .init(root: files.root.appendingPathComponent("reprocessing")),
            queueScheduleStore: .init(url: files.root.appendingPathComponent("queue-schedule.json")),
            integrationDeliveryStore: .init(rootURL: files.root.appendingPathComponent("deliveries")), mlHost: ordinary)
        return (restarted, manager)
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

    private func age(_ urls: [URL]) throws {
        for url in urls { try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-30 * 86_400)], ofItemAtPath: url.path) }
    }

    private func completedRetentionJob(_ recording: Recording, audio: URL) -> PersistedProcessingJob {
        let date = Date().addingTimeInterval(-30 * 86_400)
        return .init(id: UUID(), recordingID: recording.id, createdAt: date, updatedAt: date, status: .completed,
            request: .init(transcribe: true, summary: false, actionItems: false, tags: false, titleWasUserProvided: false, autoResume: false),
            source: .init(recordingDate: recording.date, duration: 1, fileSize: 8, meetingTitle: "Saved", participants: [],
                echoSuppressionApplied: false, finalizedAudioPath: audio.path, segmentAudioPaths: []))
    }

    @Test(arguments: ["job", "delivery", "child"])
    func recordingRetentionCannotDeleteReplacedRecoveryFilesAfterIntentOrColdRestart(kind: String) async throws {
        let gate = LiveArtifactGate(stage: .retentionRemoval)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true,
            deletionFiles: .init(beforeRemoval: { try await gate.enter(.retentionRemoval) }))
        var sweep: Task<RetentionCleanupResult, Error>?
        do {
            let (recording, old, audio, chat) = try await prepareForDeletion(f, bound: true)
            let live = audio.deletingPathExtension().appendingPathExtension("live-transcript.json")
            try age([audio, chat, live])
            let job = completedRetentionJob(recording, audio: audio)
            let file: URL
            if kind == "delivery" {
                var batch = IntegrationDeliveryBatch(id: job.id, recordingID: recording.id, createdAt: job.createdAt,
                    bundle: .init(title: "Saved", createdAt: job.createdAt, durationSeconds: 1, audioFileURL: audio,
                        transcript: "Saved text", summary: nil, actionItems: [], tags: [], sentiment: nil, markdown: nil, calendarEvent: nil),
                    deliveries: [.init(id: UUID(), destination: .webhook, configurationDigest: "fixture")])
                batch.deliveries[0].status = .succeeded
                let root = f.files.root.appendingPathComponent("deliveries")
                try await IntegrationDeliveryStore(rootURL: root).save(batch); file = root.appendingPathComponent(job.id.uuidString + ".json")
            } else {
                try await f.manager.processingJobStore.save(job)
                file = f.files.root.appendingPathComponent("jobs/\(job.id.uuidString)/job.json")
            }
            let bytes = try Data(contentsOf: file)
            let task = Task { try await f.manager.runRetentionCleanup(category: .recordings, days: 7, folders: [audio.deletingLastPathComponent()]) }; sweep = task
            try await gate.waitForArrival(); #expect(!old.isValid && FileManager.default.fileExists(atPath: audio.path))
            let child = file.deletingLastPathComponent().appendingPathComponent("new-private-child.bin")
            if kind == "child" { try Data("new unrelated bytes".utf8).write(to: child) }
            else { try bytes.write(to: file, options: .atomic) }
            await gate.release()
            await #expect(throws: LiveArtifactError.wrongOwner) { _ = try await task.value }
            #expect(try Data(contentsOf: file) == bytes && FileManager.default.fileExists(atPath: audio.path))
            if kind == "child" { #expect(FileManager.default.fileExists(atPath: child.path)) }
            let (_, restarted) = f.restartedManager()
            await #expect(throws: LiveArtifactError.wrongOwner) {
                _ = try await restarted.runRetentionCleanup(category: .recordings, days: 7, folders: [audio.deletingLastPathComponent()])
            }
            #expect(try Data(contentsOf: file) == bytes && FileManager.default.fileExists(atPath: audio.path))
            await f.clean()
        } catch { sweep?.cancel(); await gate.release(); _ = try? await sweep?.value; await f.clean(); throw error }
    }

    @Test func recordingRetentionColdRetryDrainsMultipleFrozenJobsIncludingHeaderlessScratch() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true,
            deletionFiles: .init(beforeRemoval: { throw LiveArtifactFixtureFailure.injected }))
        do {
            let (recording, old, audio, chat) = try await prepareForDeletion(f, bound: true)
            try age([audio, chat, audio.deletingPathExtension().appendingPathExtension("live-transcript.json")])
            let records = [completedRetentionJob(recording, audio: audio), completedRetentionJob(recording, audio: audio)]
            for record in records { try await f.manager.processingJobStore.save(record) }
            let first = f.files.root.appendingPathComponent("jobs/\(records[0].id.uuidString)")
            let scratch = first.appendingPathComponent("original-private-scratch.bin")
            try Data("original captured scratch".utf8).write(to: scratch)
            await #expect(throws: LiveArtifactFixtureFailure.injected) {
                _ = try await f.manager.runRetentionCleanup(category: .recordings, days: 7, folders: [audio.deletingLastPathComponent()])
            }
            #expect(!old.isValid && FileManager.default.fileExists(atPath: audio.path))
            try FileManager.default.removeItem(at: first.appendingPathComponent("job.json"))
            let (_, restarted) = f.restartedManager()
            _ = try await restarted.runRetentionCleanup(category: .recordings, days: 7, folders: [audio.deletingLastPathComponent()])
            #expect(!FileManager.default.fileExists(atPath: audio.path))
            for record in records { #expect(!FileManager.default.fileExists(atPath: f.files.root.appendingPathComponent("jobs/\(record.id.uuidString)").path)) }
            #expect(!FileManager.default.fileExists(atPath: scratch.path))
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test(arguments: [false, true]) func recordingRetentionRevalidatesMasterAuthorityBeforeAnyRecoveryRemoval(metadata: Bool) async throws {
        let gate = LiveArtifactGate(stage: .retentionRemoval)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true,
            deletionFiles: .init(beforeRemoval: { try await gate.enter(.retentionRemoval) }))
        var sweep: Task<RetentionCleanupResult, Error>?
        do {
            let (recording, _, audio, chat) = try await prepareForDeletion(f, bound: true)
            try age([audio, chat, audio.deletingPathExtension().appendingPathExtension("live-transcript.json")])
            let record = completedRetentionJob(recording, audio: audio); try await f.manager.processingJobStore.save(record)
            let jobFile = f.files.root.appendingPathComponent("jobs/\(record.id.uuidString)/job.json"), bytes = try Data(contentsOf: jobFile)
            let task = Task { try await f.manager.runRetentionCleanup(category: .recordings, days: 7, folders: [audio.deletingLastPathComponent()]) }; sweep = task
            try await gate.waitForArrival()
            let replaced = metadata ? audio.deletingPathExtension().appendingPathExtension("json") : audio
            try Data(contentsOf: replaced).write(to: replaced, options: .atomic)
            await gate.release()
            await #expect(throws: LiveArtifactError.wrongOwner) { _ = try await task.value }
            #expect(try Data(contentsOf: jobFile) == bytes && FileManager.default.fileExists(atPath: audio.path))
            await f.clean()
        } catch { sweep?.cancel(); await gate.release(); _ = try? await sweep?.value; await f.clean(); throw error }
    }

    @Test(arguments: [false, true], ["chat.json", "CHAT.JSON", "LIVE-TRANSCRIPT.JSON"]) func opaqueOrphanHistoryProtectsRecoveryAndPrivateBackupsBeforeConventionalEffects(corruptMetadata: Bool, marker: String) async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech)
        do {
            let folder = f.files.root.appendingPathComponent("Recordings")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let audio = folder.appendingPathComponent("opaque.m4a"); try Data([1, 2]).write(to: audio)
            let transcript = audio.deletingPathExtension().appendingPathExtension("transcript.json")
            try JSONEncoder().encode(TranscriptionResult(text: "Original private backup")).write(to: transcript)
            let candidate = try await f.manager.reprocessingStore.prepare(audioURL: audio, configuration: Data())
            try await f.manager.reprocessingStore.stage(JSONEncoder().encode(TranscriptionResult(text: "New saved text")), suffix: "transcript.json", attemptID: candidate.id)
            try await f.manager.reprocessingStore.commit(attemptID: candidate.id)
            let backup = f.files.root.appendingPathComponent("reprocessing/\(candidate.id.uuidString)/original/transcript.json"), bytes = try Data(contentsOf: backup)
            let chat = audio.deletingPathExtension().appendingPathExtension(marker), unknown = Data(#"{"version":999,"messages":[]}"#.utf8)
            try unknown.write(to: chat)
            if corruptMetadata { try Data(#"{"version":999}"#.utf8).write(to: audio.deletingPathExtension().appendingPathExtension("json")) }
            let date = Date().addingTimeInterval(-30 * 86_400)
            var record = PersistedProcessingJob(id: UUID(), recordingID: UUID(), createdAt: date, updatedAt: date, status: .completed,
                request: .init(transcribe: true, summary: false, actionItems: false, tags: false, titleWasUserProvided: false, autoResume: false),
                source: .init(recordingDate: date, duration: 1, fileSize: 2, meetingTitle: "Saved", participants: [],
                    echoSuppressionApplied: false, finalizedAudioPath: audio.path, segmentAudioPaths: []))
            record.completedAt = date; try await f.manager.processingJobStore.save(record)
            let manifest = f.files.root.appendingPathComponent("jobs/\(record.id.uuidString)/job.json"), original = try Data(contentsOf: manifest)
            _ = try await f.manager.runRetentionCleanup(category: .transcripts, days: 0, folders: [folder])
            #expect(FileManager.default.fileExists(atPath: backup.path) && FileManager.default.fileExists(atPath: manifest.path))
            if FileManager.default.fileExists(atPath: backup.path) { #expect(try Data(contentsOf: backup) == bytes) }
            if FileManager.default.fileExists(atPath: manifest.path) { #expect(try Data(contentsOf: manifest) == original) }
            #expect(try Data(contentsOf: chat) == unknown)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test(arguments: [false, true]) func recordingRetentionPreservesAudioAndPrivacyWhileRecoveryStorageIsUnavailable(delivery: Bool) async throws {
        let gate = LiveArtifactGate(stage: .retentionRemoval)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true,
            deletionFiles: .init(beforeRemoval: { try await gate.enter(.retentionRemoval) }))
        var sweep: Task<RetentionCleanupResult, Error>?
        do {
            let (recording, _, audio, chat) = try await prepareForDeletion(f, bound: true)
            try age([audio, chat, audio.deletingPathExtension().appendingPathExtension("live-transcript.json")])
            let record = completedRetentionJob(recording, audio: audio)
            let root = f.files.root.appendingPathComponent(delivery ? "deliveries" : "jobs")
            let relative: String
            if delivery {
                var batch = IntegrationDeliveryBatch(id: record.id, recordingID: recording.id, createdAt: record.createdAt,
                    bundle: .init(title: "Saved", createdAt: record.createdAt, durationSeconds: 1, audioFileURL: audio,
                        transcript: "Saved private text", summary: nil, actionItems: [], tags: [], sentiment: nil, markdown: nil, calendarEvent: nil),
                    deliveries: [.init(id: UUID(), destination: .webhook, configurationDigest: "fixture")])
                batch.deliveries[0].status = .succeeded
                try await IntegrationDeliveryStore(rootURL: root).save(batch); relative = record.id.uuidString + ".json"
            } else {
                try await f.manager.processingJobStore.save(record); relative = record.id.uuidString + "/job.json"
            }
            let bytes = try Data(contentsOf: root.appendingPathComponent(relative))
            let receipt = PrivacyReceiptStore.sidecarURL(for: audio)
            _ = try await f.privacyStore.begin(.init(stage: .transcription, data: [.recordingAudio], destination: .local(provider: .whisper)), runID: UUID(), at: receipt)
            let privacy = try Data(contentsOf: receipt)
            let task = Task { try await f.manager.runRetentionCleanup(category: .recordings, days: 7, folders: [audio.deletingLastPathComponent()]) }; sweep = task
            try await gate.waitForArrival()
            let offline = f.files.root.appendingPathComponent("offline-recovery")
            try FileManager.default.moveItem(at: root, to: offline)
            await gate.release()
            await #expect(throws: (any Error).self) { _ = try await task.value }
            #expect(FileManager.default.fileExists(atPath: audio.path) && FileManager.default.fileExists(atPath: receipt.path))
            #expect(try Data(contentsOf: offline.appendingPathComponent(relative)) == bytes)
            if FileManager.default.fileExists(atPath: receipt.path) { #expect(try Data(contentsOf: receipt) == privacy) }
            let (_, unavailable) = f.restartedManager()
            await #expect(throws: (any Error).self) { _ = try await unavailable.runRetentionCleanup(category: .recordings, days: 7, folders: [audio.deletingLastPathComponent()]) }
            try FileManager.default.moveItem(at: offline, to: root)
            let (_, restarted) = f.restartedManager()
            _ = try await restarted.runRetentionCleanup(category: .recordings, days: 7, folders: [audio.deletingLastPathComponent()])
            #expect(!FileManager.default.fileExists(atPath: audio.path) && !FileManager.default.fileExists(atPath: receipt.path))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path))
            await f.clean()
        } catch { sweep?.cancel(); await gate.release(); _ = try? await sweep?.value; await f.clean(); throw error }
    }

    @Test func recordingRetentionSealsAdmissionBeforeIntentAndReopensAfterIntentFailure() async throws {
        let gate = LiveArtifactGate(stage: .deletionIntent), fault = LiveArtifactFault(stage: .deletionIntent)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, stage: { try await gate.enter($0); try await fault.check($0) })
        var sweep: Task<RetentionCleanupResult, Error>?
        do {
            let (recording, old, audio, chat) = try await prepareForDeletion(f, bound: true)
            let live = audio.deletingPathExtension().appendingPathExtension("live-transcript.json")
            try age([audio, chat, live]); let before = try [audio, chat, live].map { try Data(contentsOf: $0) }
            let task = Task { try await f.manager.runRetentionCleanup(category: .recordings, days: 7, folders: [audio.deletingLastPathComponent()]) }; sweep = task
            try await gate.waitForArrival()
            #expect(old.isValid && f.state.liveRecordingSessions.entry(recordingID: recording.id) == nil)
            #expect(throws: LiveArtifactError.deleted) { _ = try old.artifacts.beginChatRequest() }
            await #expect(throws: LiveRecordingSessionRegistry.Failure.unavailable) { _ = try await f.manager.prepareLiveHistoryExport(recordingID: recording.id, audioURL: audio) }
            await gate.release()
            await #expect(throws: LiveArtifactFixtureFailure.injected) { _ = try await task.value }
            #expect(old.isValid && f.state.liveRecordingSessions.entry(recordingID: recording.id) === old)
            #expect(try [audio, chat, live].map { try Data(contentsOf: $0) } == before)
            let request = try old.artifacts.beginChatRequest(); request.release()
            #expect(f.state.liveRecordingSessions.pendingReplacements.isEmpty)
            await f.clean()
        } catch { sweep?.cancel(); await gate.release(); _ = try? await sweep?.value; await f.clean(); throw error }
    }

    @Test func retentionPreflightBoundsPrivatePrivacyRootsBeforeAnyIntent() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let (_, old, audio, chat) = try await prepareForDeletion(f, bound: true)
            let live = audio.deletingPathExtension().appendingPathExtension("live-transcript.json")
            try age([audio, chat, live]); let before = try [audio, chat, live].map { try Data(contentsOf: $0) }
            let root = f.files.root.appendingPathComponent("pending"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for index in 0..<1_000 { try Data().write(to: root.appendingPathComponent("unrelated-\(index).txt")) }
            await #expect(throws: LiveArtifactError.artifactTooLarge) {
                _ = try await f.manager.runRetentionCleanup(category: .recordings, days: 7, folders: [audio.deletingLastPathComponent()])
            }
            #expect(old.isValid && f.state.liveRecordingSessions.pendingReplacements.isEmpty)
            #expect(try [audio, chat, live].map { try Data(contentsOf: $0) } == before)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func retentionRefreshKeepsQueueIntentWithoutReadingAnUnadmittedSchedule() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, queueFiles: .init(read: { _ in throw LiveArtifactFixtureFailure.injected }))
        do {
            try Data([1]).write(to: f.files.root.appendingPathComponent("queue-schedule.json"))
            let item = QueueItem(transcribe: true, summary: false, actionItems: false, tags: false)
            let audio = f.files.root.appendingPathComponent("queued.wav")
            f.manager.pendingQueueItems = [.init(audioURL: audio, item: item, fileSize: nil)]; f.state.queuedCount = 1
            let error = "Saved schedule is unreadable"; f.manager.queueLoadError = error
            await f.manager.refreshWorkQueue(boundedRetention: true)
            #expect(f.manager.queueLoadError == error && f.state.queuedCount == 1 && f.manager.pendingQueueItems.map { $0.item.id } == [item.id])
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test(arguments: [false, true]) func retentionPreservesCompletedBackupsForAnUnavailableManagedMaster(removeMetadata: Bool) async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let (recording, _, audio, _) = try await prepareForDeletion(f, bound: true)
            try JSONEncoder().encode(TranscriptionResult(text: "Original private backup")).write(to: audio.deletingPathExtension().appendingPathExtension("transcript.json"))
            let candidate = try await stageModelFreeReplacement(f, recording: recording, audio: audio, text: "Fresh saved final")
            await f.manager.refreshReprocessingAttempts(); await f.manager.resumeReprocessing(candidate.id)
            let job = try #require(f.state.processingJob); try await job.task?.value
            let backup = f.files.root.appendingPathComponent("reprocessing/\(candidate.id.uuidString)/original/transcript.json")
            let bytes = try Data(contentsOf: backup)
            #expect(try await f.manager.reprocessingStore.load(attemptID: candidate.id).status == .completed)
            try FileManager.default.removeItem(at: audio)
            if removeMetadata { try FileManager.default.removeItem(at: audio.deletingPathExtension().appendingPathExtension("json")) }
            await #expect(throws: Never.self, "Completed backup remains discoverable after source loss") {
                _ = try await f.manager.reprocessingStore.load(attemptID: candidate.id)
            }
            _ = try await f.manager.runRetentionCleanup(category: .transcripts, days: 0, folders: [audio.deletingLastPathComponent()])
            #expect(try Data(contentsOf: backup) == bytes)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test(arguments: [false, true]) func heldRetentionCleanupCannotInheritReplacedMasterOrMetadata(metadata: Bool) async throws {
        let gate = LiveArtifactGate(stage: .retentionTranscript)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, stage: { try await gate.enter($0) })
        var sweep: Task<RetentionCleanupResult, Error>?
        do {
            let (recording, old, audio, chatURL) = try await prepareForDeletion(f, bound: true)
            let live = audio.deletingPathExtension().appendingPathExtension("live-transcript.json")
            try age([live, chatURL]); let before = try [live, chatURL].map { try Data(contentsOf: $0) }
            let receipt = PrivacyReceiptStore.sidecarURL(for: audio)
            _ = try await f.privacyStore.begin(.init(stage: .transcription, data: [.recordingAudio], destination: .local(provider: .whisper)), runID: UUID(), at: receipt)
            let privacy = try Data(contentsOf: receipt)
            let task = Task { try await f.manager.runRetentionCleanup(category: .transcripts, days: 7, folders: [audio.deletingLastPathComponent()]) }; sweep = task
            try await gate.waitForArrival(); #expect(!old.isValid)
            let replaced = metadata ? audio.deletingPathExtension().appendingPathExtension("json") : audio
            try Data(contentsOf: replaced).write(to: replaced, options: .atomic)
            await gate.release()
            await #expect(throws: LiveArtifactError.wrongOwner) { _ = try await task.value }
            #expect(try [live, chatURL].map { try Data(contentsOf: $0) } == before)
            #expect(try Data(contentsOf: receipt) == privacy && FileManager.default.fileExists(atPath: audio.path))
            let (_, restarted) = f.restartedManager()
            await #expect(throws: LiveArtifactError.wrongOwner) { _ = try await restarted.prepareLiveHistory(recordingID: recording.id, audioURL: audio) }
            #expect(!old.isValid && f.state.liveRecordingSessions.pendingReplacements.count == 1)
            await f.clean()
        } catch { sweep?.cancel(); await gate.release(); _ = try? await sweep?.value; await f.clean(); throw error }
    }

    @Test func retentionProtectsAPinnedOwnerAndThenRemovesOnlyAgedConventionalDerivatives() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let (_, old, audio, chatURL) = try await prepareForDeletion(f, bound: true)
            let live = audio.deletingPathExtension().appendingPathExtension("live-transcript.json")
            let markdown = audio.deletingPathExtension().appendingPathExtension("md")
            let spoken = audio.deletingPathExtension().appendingPathExtension("spokensummary.m4a")
            try Data("Markdown, not JSON".utf8).write(to: markdown); try Data([1, 2, 3]).write(to: spoken)
            let insightsURL = audio.deletingPathExtension().appendingPathExtension("insights.json")
            try JSONEncoder().encode(RecordingInsights(summary: "", actionItems: [], tags: [], sentiment: "neutral", markdownPath: markdown.path)).write(to: insightsURL)
            try age([live, chatURL, markdown, spoken, insightsURL])
            let before = try [live, chatURL, markdown, spoken].map { try Data(contentsOf: $0) }
            let pin = old.artifacts.pin()
            let protected = try await f.manager.runRetentionCleanup(category: .transcripts, days: 7, folders: [audio.deletingLastPathComponent()])
            #expect(old.isValid && protected.historiesRetired == 0 && protected.filesDeleted == 0)
            #expect(try [live, chatURL, markdown, spoken].map { try Data(contentsOf: $0) } == before)
            pin.release()
            _ = try await f.manager.runRetentionCleanup(category: .transcripts, days: 7, folders: [audio.deletingLastPathComponent()])
            #expect(!old.isValid && FileManager.default.fileExists(atPath: audio.path))
            #expect(!FileManager.default.fileExists(atPath: markdown.path) && !FileManager.default.fileExists(atPath: spoken.path))
            #expect(!FileManager.default.fileExists(atPath: insightsURL.path))
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func sourceBeforeBindRetentionUsesStableMetadataOwnershipWithoutInventingABinding() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let (recording, old, _, chatURL) = try await prepareForDeletion(f, bound: false)
            let source = chatURL.deletingLastPathComponent().appendingPathComponent("live-transcript.json")
            try age([source, chatURL])
            let folder = f.settings.recordingFolderURL
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let audio = folder.appendingPathComponent("source-owner.wav"); try Data("model-free master".utf8).write(to: audio)
            let metadata = RecordingMetadataPayload(recordingID: recording.id, dateISO8601: "2026-10-04T00:00:00Z", durationSeconds: 1,
                meetingTitle: "Owner", masterFileName: audio.lastPathComponent, segmentFileNames: [], warnings: [])
            try JSONEncoder().encode(metadata).write(to: audio.deletingPathExtension().appendingPathExtension("json"))
            let (_, restarted) = f.restartedManager()
            let result = try await restarted.runRetentionCleanup(category: .transcripts, days: 7, folders: [folder])
            #expect(result.historiesRetired == 1)
            #expect(!FileManager.default.fileExists(atPath: source.deletingLastPathComponent().appendingPathComponent("binding.json").path))
            let retained = try await LiveSessionArtifactStore(identity: old.identity, rootURL: f.files.root.appendingPathComponent("LiveSessions")).recover()
            #expect(retained.historyRetained && retained.audioURL == nil && retained.appTranscript?.sourceUnavailable == true)
            let owner = try #require(try await restarted.prepareLiveHistory(recordingID: recording.id, audioURL: audio))
            #expect(owner.artifacts.historyRetained && FileManager.default.fileExists(atPath: audio.path))
            #expect(try JSONDecoder().decode(LiveTranscriptArtifact.self, from: Data(contentsOf: audio.deletingPathExtension().appendingPathExtension("live-transcript.json"))).sourceUnavailable == true)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test(arguments: [false, true]) func retentionPreflightRejectsOversizedOutputOrRecoveryBeforeRetiringAnyOwner(recovery: Bool) async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let (_, old, audio, chatURL) = try await prepareForDeletion(f, bound: true)
            let live = audio.deletingPathExtension().appendingPathExtension("live-transcript.json")
            try age([live, chatURL]); let before = try [live, chatURL].map { try Data(contentsOf: $0) }
            if recovery {
                let directory = f.files.root.appendingPathComponent("jobs/\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(repeating: 32, count: 128 * 1_024 + 1).write(to: directory.appendingPathComponent("job.json"))
            } else {
                for index in 0..<4_097 { try Data().write(to: audio.deletingLastPathComponent().appendingPathComponent("unrelated-\(index).txt")) }
            }
            await #expect(throws: LiveArtifactError.artifactTooLarge) {
                _ = try await f.manager.runRetentionCleanup(category: .transcripts, days: 7, folders: [audio.deletingLastPathComponent()])
            }
            #expect(old.isValid && f.state.liveRecordingSessions.pendingReplacements.isEmpty)
            #expect(try [live, chatURL].map { try Data(contentsOf: $0) } == before)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func explicitReprocessingAfterTranscriptRetentionCanPublishAFreshFinal() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let (recording, old, audio, chatURL) = try await prepareForDeletion(f, bound: true)
            let live = audio.deletingPathExtension().appendingPathExtension("live-transcript.json")
            let chat = try Data(contentsOf: chatURL); try age([live])
            _ = try await f.manager.runRetentionCleanup(category: .transcripts, days: 7, folders: [audio.deletingLastPathComponent()])
            #expect(!old.isValid)
            let candidate = try await stageModelFreeReplacement(f, recording: recording, audio: audio, text: "Fresh explicit final")
            await f.manager.refreshReprocessingAttempts(); await f.manager.resumeReprocessing(candidate.id)
            let job = try #require(f.state.processingJob); try await job.task?.value
            #expect(f.state.lastError == nil && f.state.processingJob == nil)
            let fresh = try #require(f.state.liveRecordingSessions.entry(recordingID: recording.id))
            #expect(fresh.isValid && fresh !== old)
            #expect(try fresh.artifacts.finalContext()?.segments.map(\.text) == ["Fresh explicit final"])
            #expect(try Data(contentsOf: chatURL) == chat)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func transcriptRetentionPreservesANewerConversationAndItsFrozenAnswerBasis() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let (recording, old, audio, chatURL) = try await prepareForDeletion(f, bound: true)
            let answerID = UUID(), text = "Saved answer [[dbrief:1]]"
            let context = try TranscriptContextBuilder.build(snapshot: .legacy(text: "Exact included evidence", recordingID: recording.id, speakerLabels: []),
                route: .init(engine: "fixture", endpointID: nil, provider: nil, origin: nil, model: nil),
                budget: .init(contextTokens: 8_192, outputTokens: 512, templateReserve: 256), language: .matchInput,
                question: "What?", history: [], answerID: answerID)
            try old.artifacts.saveChat(.init(messages: [.init(id: answerID, role: .assistant, content: text, basis: context.basis,
                outcome: .streaming, referenceResolution: ChatReferenceParser.resolve(text, basis: context.basis))]), urgent: true)
            try await old.artifacts.flush()
            let chatBytes = try Data(contentsOf: chatURL)
            let liveURL = audio.deletingPathExtension().appendingPathExtension("live-transcript.json")
            let revision = try JSONDecoder().decode(LiveTranscriptArtifact.self, from: Data(contentsOf: liveURL)).revision
            try age([liveURL])
            let result = try await f.manager.runRetentionCleanup(category: .transcripts, days: 7, folders: [audio.deletingLastPathComponent()])
            #expect(!old.isValid && result.historiesRetired == 1 && result.summary != "Nothing to delete.")
            #expect(try Data(contentsOf: chatURL) == chatBytes)
            let retained = try JSONDecoder().decode(LiveTranscriptArtifact.self, from: Data(contentsOf: liveURL))
            #expect(retained.sourceUnavailable == true && retained.revision == revision + 1)
            let (_, restarted) = f.restartedManager()
            _ = try await restarted.prepareLiveHistory(recordingID: recording.id, audioURL: audio)
            #expect(try Data(contentsOf: chatURL) == chatBytes)
            let snapshot = try await restarted.prepareLiveHistoryExport(recordingID: recording.id, audioURL: audio)
            let exported = try JSONDecoder().decode(LiveHistoryExport.self, from: snapshot.data)
            #expect(!exported.sourceAvailable && exported.chat?.messages.first?.basis == context.basis)
            #expect(exported.chat?.messages.first?.outcome == .streaming)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func retentionCleanupFailureRetiresThenRestartsWithoutDoubleRevisions() async throws {
        let fault = LiveArtifactFault(stage: .retentionChat)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, stage: { try await fault.check($0) })
        do {
            let (recording, old, audio, chatURL) = try await prepareForDeletion(f, bound: true)
            let liveURL = audio.deletingPathExtension().appendingPathExtension("live-transcript.json")
            try age([liveURL, chatURL])
            await #expect(throws: LiveArtifactFixtureFailure.injected) {
                _ = try await f.manager.runRetentionCleanup(category: .transcripts, days: 7, folders: [audio.deletingLastPathComponent()])
            }
            #expect(!old.isValid && FileManager.default.fileExists(atPath: audio.path))
            let rewritten = try Data(contentsOf: liveURL)
            let (_, restarted) = f.restartedManager()
            _ = try await restarted.prepareLiveHistory(recordingID: recording.id, audioURL: audio)
            #expect(try Data(contentsOf: liveURL) == rewritten)
            #expect(try JSONDecoder().decode(ChatHistory.self, from: Data(contentsOf: chatURL)).messages.isEmpty)
            let markerURL = f.files.root.appendingPathComponent("LiveSessions/\(old.identity.captureSessionID.uuidString)/retention.json")
            #expect(try JSONDecoder().decode(LiveHistoryRetention.self, from: Data(contentsOf: markerURL)).cleanupComplete)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func failedRetentionIntentKeepsTheHealthyOriginalAndExactFiles() async throws {
        let fault = LiveArtifactFault(stage: .retentionIntent)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, stage: { try await fault.check($0) })
        do {
            let (_, old, audio, chatURL) = try await prepareForDeletion(f, bound: true)
            let liveURL = audio.deletingPathExtension().appendingPathExtension("live-transcript.json")
            try age([liveURL, chatURL]); let before = try [liveURL, chatURL].map { try Data(contentsOf: $0) }
            await #expect(throws: LiveArtifactFixtureFailure.injected) {
                _ = try await f.manager.runRetentionCleanup(category: .transcripts, days: 7, folders: [audio.deletingLastPathComponent()])
            }
            #expect(old.isValid && f.state.liveRecordingSessions.entry(recordingID: old.identity.recordingID) === old)
            #expect(try [liveURL, chatURL].map { try Data(contentsOf: $0) } == before)
            #expect(f.state.liveRecordingSessions.pendingReplacements.isEmpty)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test(arguments: [false, true]) func recordingRetentionColdRetryKeepsOriginalPhysicalAuthority(replace: Bool) async throws {
        let fault = LiveArtifactFault(stage: .deletionCleanup)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, stage: { try await fault.check($0) })
        do {
            let (recording, old, audio, chatURL) = try await prepareForDeletion(f, bound: true)
            let liveURL = audio.deletingPathExtension().appendingPathExtension("live-transcript.json")
            try age([audio, chatURL, liveURL])
            await #expect(throws: LiveArtifactFixtureFailure.injected) {
                _ = try await f.manager.runRetentionCleanup(category: .recordings, days: 7, folders: [audio.deletingLastPathComponent()])
            }
            #expect(!old.isValid && FileManager.default.fileExists(atPath: audio.path))
            let original = try Data(contentsOf: audio)
            if replace { try original.write(to: audio, options: .atomic) }
            let (state, restarted) = f.restartedManager()
            if replace {
                await #expect(throws: LiveArtifactError.wrongOwner) {
                    _ = try await restarted.runRetentionCleanup(category: .recordings, days: 7, folders: [audio.deletingLastPathComponent()])
                }
                #expect(try Data(contentsOf: audio) == original && Data(contentsOf: chatURL).count > 0)
            } else {
                _ = try await restarted.runRetentionCleanup(category: .recordings, days: 7, folders: [audio.deletingLastPathComponent()])
                #expect(!FileManager.default.fileExists(atPath: audio.path) && state.liveRecordingSessions.isKnownDeleted(recordingID: recording.id))
            }
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func recordingRetentionRetriesPrivacyAfterAudioAndMetadataHaveDisappeared() async throws {
        let failure = LiveArtifactFault(stage: .deletionCleanup)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true,
            deletionFiles: .init(removeEvidence: { _,_ in try await failure.check(.deletionCleanup) }))
        do {
            let (_, old, audio, chatURL) = try await prepareForDeletion(f, bound: true)
            let liveURL = audio.deletingPathExtension().appendingPathExtension("live-transcript.json")
            let metadata = audio.deletingPathExtension().appendingPathExtension("json")
            let receipt = PrivacyReceiptStore.sidecarURL(for: audio)
            _ = try await f.privacyStore.begin(.init(stage: .transcription, data: [.recordingAudio], destination: .local(provider: .whisper)), runID: UUID(), at: receipt)
            let privacy = try Data(contentsOf: receipt)
            try age([audio, metadata, chatURL, liveURL])
            await #expect(throws: LiveArtifactFixtureFailure.injected) {
                _ = try await f.manager.runRetentionCleanup(category: .recordings, days: 7, folders: [audio.deletingLastPathComponent()])
            }
            #expect(!old.isValid && !FileManager.default.fileExists(atPath: audio.path) && !FileManager.default.fileExists(atPath: metadata.path))
            #expect(try Data(contentsOf: receipt) == privacy)
            let (state, restarted) = f.restartedManager()
            _ = try await restarted.runRetentionCleanup(category: .recordings, days: 7, folders: [audio.deletingLastPathComponent()])
            #expect(state.liveRecordingSessions.isKnownDeleted(recordingID: old.identity.recordingID) && !state.liveRecordingSessions.hasPendingDeletion(recordingID: old.identity.recordingID))
            #expect(!FileManager.default.fileExists(atPath: receipt.path))
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func transcriptRetentionRetiresTheActualGenerationWithoutDeletingAudioOrPrivacy() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let (_, entry, audio, history) = try await prepareForDeletion(f, bound: true)
            let (_, admission) = try await f.manager.processingPipeline.retentionOwnership(folders: [audio.deletingLastPathComponent()])
            let canonicalAudio = try RecordingDeletionAuthority.canonical(audio)
            try #require(!admission.inspectionFailed && admission.recordingIDs[canonicalAudio] == entry.identity.recordingID)
            try #require(admission.audio.contains(canonicalAudio))
            try #require(entry.artifacts.canExpire)
            try #require(try await f.manager.processingPipeline.retentionQueueBases(folders: [audio.deletingLastPathComponent()]).isEmpty)
            let pending = try await RecoveryLifecycle(jobs: f.manager.processingJobStore,
                deliveries: .init(rootURL: f.files.root.appendingPathComponent("deliveries"))).pendingRetentionBases()
            try #require(pending.isEmpty)
            let transcript = audio.deletingPathExtension().appendingPathExtension("live-transcript.json")
            for url in [transcript, history] {
                try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-30 * 86_400)], ofItemAtPath: url.path)
            }
            _ = try await f.manager.runRetentionCleanup(category: .transcripts, days: 7, folders: [audio.deletingLastPathComponent()])
            #expect(!entry.isValid)
            #expect(!f.state.liveRecordingSessions.isKnownDeleted(recordingID: entry.identity.recordingID))
            #expect(FileManager.default.fileExists(atPath: audio.path))
            #expect(FileManager.default.fileExists(atPath: audio.deletingPathExtension().appendingPathExtension("json").path))
            let saved = try await LiveSessionArtifactStore(identity: entry.identity, rootURL: f.files.root.appendingPathComponent("LiveSessions")).recover()
            #expect(saved.appTranscript?.sourceUnavailable == true)
            #expect(saved.appTranscript?.legacy == nil && saved.appTranscript?.finalPublication == nil)
            #expect(saved.chat?.messages.isEmpty != false)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func recordingRetentionRetiresOwnedHistoryBeforeAgedAudioDisappears() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let (_, entry, audio, history) = try await prepareForDeletion(f, bound: true)
            let transcript = audio.deletingPathExtension().appendingPathExtension("live-transcript.json")
            for url in [audio, history, transcript] {
                try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-30 * 86_400)], ofItemAtPath: url.path)
            }
            _ = try await f.manager.runRetentionCleanup(category: .recordings, days: 7, folders: [audio.deletingLastPathComponent()])
            #expect(!entry.isValid)
            #expect(f.state.liveRecordingSessions.isKnownDeleted(recordingID: entry.identity.recordingID))
            #expect(!FileManager.default.fileExists(atPath: audio.path))
            #expect(!FileManager.default.fileExists(atPath: history.path))
            #expect(!FileManager.default.fileExists(atPath: transcript.path))
            let saved = try await LiveSessionArtifactStore(identity: entry.identity, rootURL: f.files.root.appendingPathComponent("LiveSessions")).recover()
            #expect(saved.deleted)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func recordingRetentionDefersAnOldMasterWithNewerOwnedConversation() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let (_, entry, audio, history) = try await prepareForDeletion(f, bound: true)
            try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-30 * 86_400)], ofItemAtPath: audio.path)
            let original = try Data(contentsOf: history)
            _ = try await f.manager.runRetentionCleanup(category: .recordings, days: 7, folders: [audio.deletingLastPathComponent()])
            #expect(entry.isValid)
            #expect(FileManager.default.fileExists(atPath: audio.path))
            #expect(try Data(contentsOf: history) == original)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func actualReprocessingPreservesOwnedConversationAndReplacesTheOriginalProviderGeneration() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let (recording, old, audio, historyURL) = try await prepareForDeletion(f, bound: true)
            let original = TranscriptionResult(text: "Original complete result")
            let originalRich = RichTranscriptBuilder().build(from: original)
            try JSONEncoder().encode(original).write(to: audio.deletingPathExtension().appendingPathExtension("transcript.json"))
            try JSONEncoder().encode(originalRich).write(to: audio.deletingPathExtension().appendingPathExtension("richtranscript.json"))
            try old.artifacts.publishFinal(original); try old.artifacts.publishSavedFinal(originalRich)
            try await old.artifacts.flush()
            let oldFinal = try #require(try old.artifacts.finalContext())
            let historyBytes = try Data(contentsOf: historyURL)
            let chatRevision = old.artifacts.acceptedChatRevision

            var options = ReprocessingOptions(settings: f.settings, operation: .transcribe)
            options.diarizationEnabled = false; options.regenerateAI = false
            let request = ReprocessingRequest(options: options, recordingID: recording.id,
                date: recording.date, title: recording.meetingTitleDraft, duration: recording.duration,
                participants: [], calendarEvent: nil)
            let attempt = try await f.manager.reprocessingStore.prepare(audioURL: audio, configuration: JSONEncoder().encode(request))
            let replacement = TranscriptionResult(text: "Durable replacement",
                segments: [.init(start: 0, end: 1, text: "Durable replacement")])
            let rich = RichTranscriptBuilder().build(from: replacement)
            try await f.manager.reprocessingStore.stage(JSONEncoder().encode(replacement), suffix: "transcript.json", attemptID: attempt.id)
            try await f.manager.reprocessingStore.stage(JSONEncoder().encode(rich), suffix: "richtranscript.json", attemptID: attempt.id)
            try await f.manager.reprocessingStore.checkpoint(attemptID: attempt.id, status: .stopped, completedStage: "transcription")
            await f.manager.refreshReprocessingAttempts()
            #expect(old.artifacts.isDurable)
            let baseline = try await old.artifacts.writer.inspectForReprocessing(attemptID: attempt.id)
            let frozen = try RecordingDeletionAuthority(audioURL: audio, expectedRecordingID: recording.id)
            #expect(try baseline.audioURL.map(RecordingDeletionAuthority.canonical) == frozen.audioURL)
            #expect(baseline.transcriptValue?.identity == old.identity)
            await f.manager.resumeReprocessing(attempt.id)
            let job = try #require(f.state.processingJob, "Reprocessing admission: \(f.state.lastError ?? "no error")")
            await job.task?.value
            let qualified = try JSONDecoder().decode(ReprocessingRequest.self, from: await f.manager.reprocessingStore.load(attemptID: attempt.id).configuration)
            #expect(qualified.liveSessionIdentity == old.identity)
            #expect(try await f.manager.reprocessingStore.load(attemptID: attempt.id).status == .completed)
            #expect(FileManager.default.fileExists(atPath: historyURL.path))
            if FileManager.default.fileExists(atPath: historyURL.path) {
                #expect(try Data(contentsOf: historyURL) == historyBytes)
            }
            #expect(!old.isValid)
            let fresh = try #require(f.state.liveRecordingSessions.entry(recordingID: recording.id))
            #expect(fresh !== old && fresh.identity == old.identity)
            let final = try #require(try fresh.artifacts.finalContext())
            #expect(final.segments.map(\.text).joined(separator: " ") == replacement.text)
            #expect(final.source.publicationID == oldFinal.source.publicationID)
            let oldRevision = try #require(oldFinal.source.publicationRevision)
            let newRevision = try #require(final.source.publicationRevision)
            #expect(newRevision > oldRevision)
            #expect(fresh.artifacts.acceptedChatRevision == chatRevision)
            do {
                try await old.artifacts.writer.saveChat(.init(messages: [.init(role: .user, content: "Stale callback")]), revision: chatRevision + 1)
                Issue.record("The old provider writer republished after the reprocessing claim released")
            } catch is CancellationError { }
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    private func stageModelFreeReplacement(_ f: LiveManagerFixture, recording: Recording, audio: URL,
                                          text: String, identity: LiveSessionIdentity? = nil) async throws -> ReprocessingStore.Attempt {
        var options = ReprocessingOptions(settings: f.settings, operation: .transcribe)
        options.diarizationEnabled = false; options.regenerateAI = false
        var request = ReprocessingRequest(options: options, recordingID: recording.id,
            date: recording.date, title: recording.meetingTitleDraft, duration: recording.duration,
            participants: [], calendarEvent: nil)
        request.liveSessionIdentity = identity
        let attempt = try await f.manager.reprocessingStore.prepare(audioURL: audio, configuration: JSONEncoder().encode(request))
        let raw = TranscriptionResult(text: text, segments: [.init(start: 0, end: 1, text: text)])
        try await f.manager.reprocessingStore.stage(JSONEncoder().encode(raw), suffix: "transcript.json", attemptID: attempt.id)
        try await f.manager.reprocessingStore.stage(JSONEncoder().encode(RichTranscriptBuilder().build(from: raw)), suffix: "richtranscript.json", attemptID: attempt.id)
        try await f.manager.reprocessingStore.checkpoint(attemptID: attempt.id, status: .stopped, completedStage: "transcription")
        return attempt
    }

    @Test func restartReconcilesACommittedReplacementBeforeExposingItsProviderAndDoesNotRepublishOnReopen() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let (recording, old, audio, chatURL) = try await prepareForDeletion(f, bound: true)
            let chat = try Data(contentsOf: chatURL)
            let attempt = try await stageModelFreeReplacement(f, recording: recording, audio: audio, text: "Committed before crash", identity: old.identity)
            try await f.manager.reprocessingStore.commit(attemptID: attempt.id)
            #expect(try old.artifacts.finalContext() == nil)
            let (state, manager) = f.restartedManager()
            await manager.recoverReprocessingAttempts(); await manager.discoverLiveHistory()
            let fresh = try #require(try await state.liveRecordingSessions.resolve(recordingID: recording.id, audioURL: audio))
            let source = try #require(try fresh.artifacts.finalContext())
            #expect(source.segments.map(\.text) == ["Committed before crash"])
            #expect(try Data(contentsOf: chatURL) == chat)
            let transcriptURL = audio.deletingPathExtension().appendingPathExtension("live-transcript.json")
            let bytes = try Data(contentsOf: transcriptURL)
            let (nextState, nextManager) = f.restartedManager()
            await nextManager.recoverReprocessingAttempts(); await nextManager.discoverLiveHistory()
            let reopened = try #require(try await nextState.liveRecordingSessions.resolve(recordingID: recording.id, audioURL: audio))
            let same = try #require(try reopened.artifacts.finalContext())
            #expect(same.source.publicationID == source.source.publicationID)
            #expect(same.source.publicationRevision == source.source.publicationRevision)
            #expect(try Data(contentsOf: transcriptURL) == bytes)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func actualRestorePreservesNewOwnedAnswersAndClearsFinalAuthorityWhenThereWasNoPriorTranscript() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let (recording, _, audio, chatURL) = try await prepareForDeletion(f, bound: true)
            let attempt = try await stageModelFreeReplacement(f, recording: recording, audio: audio, text: "Replacement")
            await f.manager.refreshReprocessingAttempts(); await f.manager.resumeReprocessing(attempt.id)
            let job = try #require(f.state.processingJob, "\(f.state.lastError ?? "no error")"); await job.task?.value
            let current = try #require(f.state.liveRecordingSessions.entry(recordingID: recording.id))
            try current.artifacts.saveChat(.init(messages: [.init(role: .user, content: "New answer after reprocessing")]), urgent: true)
            try await current.artifacts.flush()
            let chat = try Data(contentsOf: chatURL)
            try await f.manager.restoreReprocessingResults(for: recording)
            #expect(FileManager.default.fileExists(atPath: chatURL.path))
            if FileManager.default.fileExists(atPath: chatURL.path) { #expect(try Data(contentsOf: chatURL) == chat) }
            #expect(!current.isValid)
            let restored = try #require(f.state.liveRecordingSessions.entry(recordingID: recording.id))
            #expect(try restored.artifacts.finalContext() == nil)
            #expect(try restored.artifacts.legacyContext().segments.map(\.text) == ["Preserve owned evidence"])
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func persistenceDisabledReprocessingReplacesRamGenerationWithoutCreatingLiveArtifacts() async throws {
        let f = try LiveManagerFixture(engine: .nemotron, syntheticAudio: true, artifactPersistence: false)
        do {
            let start = Task { try await f.manager.startRecording() }
            #expect(await eventually { f.probe.createEntered }); f.probe.releaseCreate(); try await start.value
            let recording = try #require(f.state.currentRecording)
            await f.manager.stopRecording(); await f.manager.skipProcessing()
            let old = try #require(f.state.liveRecordingSessions.entry(recordingID: recording.id))
            let audio = try #require(recording.finalizedAudioURL)
            #expect(!old.artifacts.persistenceStarted)
            let attempt = try await stageModelFreeReplacement(f, recording: recording, audio: audio, text: "RAM final")
            await f.manager.refreshReprocessingAttempts(); await f.manager.resumeReprocessing(attempt.id)
            let job = try #require(f.state.processingJob, "\(f.state.lastError ?? "no error")"); await job.task?.value
            #expect(!old.isValid)
            let fresh = try #require(f.state.liveRecordingSessions.entry(recordingID: recording.id), "\(f.state.lastError ?? "no error")")
            #expect(fresh !== old && fresh.identity == old.identity)
            #expect(try fresh.artifacts.finalContext()?.segments.map(\.text) == ["RAM final"])
            let before = try #require(try fresh.artifacts.finalContext())
            var edited = try await f.manager.transcriptStore.load(from: audio.deletingPathExtension().appendingPathExtension("richtranscript.json"))
            edited.segments[0].text = "Saved RAM edit"
            try await f.manager.saveEditedTranscript(edited, for: recording, expectedRevision: f.manager.reprocessingResultsRevision)
            let after = try #require(try fresh.artifacts.finalContext())
            #expect(after.segments.map(\.text) == ["Saved RAM edit"])
            #expect(after.source.publicationID == before.source.publicationID)
            #expect(after.source.publicationRevision! > before.source.publicationRevision!)
            #expect(!fresh.artifacts.persistenceStarted)
            #expect(!FileManager.default.fileExists(atPath: f.files.root.appendingPathComponent("LiveSessions").path))
            #expect(!FileManager.default.fileExists(atPath: audio.deletingPathExtension().appendingPathExtension("live-transcript.json").path))
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test(arguments: [false, true]) func historyRetryFinishesTheExactReplacementAfterPostCommitOrDiscardHydrationFails(discard: Bool) async throws {
        let fault = ReprocessingHydrationFault()
        let gate = LiveArtifactGate(stage: .ownerHydration, initiallyEnabled: false)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, stage: {
            try await fault.check($0); try await gate.enter($0)
        })
        var first: Task<LiveRecordingSessionRegistry.Entry?, any Error>?, second: Task<LiveRecordingSessionRegistry.Entry?, any Error>?
        do {
            let (recording, old, audio, chatURL) = try await prepareForDeletion(f, bound: true)
            let chat = try Data(contentsOf: chatURL)
            let attempt = try await stageModelFreeReplacement(f, recording: recording, audio: audio, text: "Retry result")
            await fault.arm()
            await f.manager.refreshReprocessingAttempts()
            if discard { await f.manager.discardReprocessing(attempt.id) }
            else {
                await f.manager.resumeReprocessing(attempt.id)
                let job = try #require(f.state.processingJob); await job.task?.value
                #expect(try await f.manager.reprocessingStore.load(attemptID: attempt.id).status == .completed)
            }
            #expect(!old.isValid)
            #expect(f.state.liveRecordingSessions.entry(recordingID: recording.id) == nil)
            #expect(try await f.manager.reprocessingStore.pendingAttempt(audioURL: audio) == nil)
            #expect(!f.manager.canLaunchProcessing(for: recording))
            let handler = f.state.liveRecordingSessions.onReplacementRetry
            var admissions = 0
            f.state.liveRecordingSessions.onReplacementRetry = { phase in
                admissions += 1; try await handler?(phase)
            }
            await gate.arm()
            first = Task { try await f.manager.prepareLiveHistory(recordingID: recording.id, audioURL: audio) }
            try await gate.waitForArrival()
            second = Task { try await f.manager.prepareLiveHistory(recordingID: recording.id, audioURL: audio) }
            #expect(await eventually { admissions == 2 })
            await gate.release()
            let retry = try #require(try await first?.value)
            let joined = try #require(try await second?.value)
            #expect(joined === retry)
            #expect(retry !== old && retry.identity == old.identity)
            if discard { #expect(try retry.artifacts.legacyContext().segments.map(\.text) == ["Preserve owned evidence"]) }
            else { #expect(try retry.artifacts.finalContext()?.segments.map(\.text) == ["Retry result"]) }
            #expect(try Data(contentsOf: chatURL) == chat)
            await f.clean()
        } catch { await gate.release(); _ = try? await first?.value; _ = try? await second?.value; await f.clean(); throw error }
    }

    @Test func cancelledActualStartKeepsTheOriginalGenerationAndCreatesNoAttemptAfterItsHeldInspectionReturns() async throws {
        let gate = LiveArtifactGate(stage: .historyLoad, initiallyEnabled: false)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, stage: { try await gate.enter($0) })
        var task: Task<Void, any Error>?
        do {
            let (recording, old, audio, chatURL) = try await prepareForDeletion(f, bound: true)
            let bytes = try Data(contentsOf: chatURL)
            let busy = Recording(id: UUID(), date: Date(), fileURL: f.files.root.appendingPathComponent("busy.m4a"),
                duration: 0, meetingTitleDraft: "Another job", finalizedAudioURL: nil)
            f.state.processingJob = ProcessingJob(recording: busy)
            var options = ReprocessingOptions(settings: f.settings, operation: .transcribe)
            options.diarizationEnabled = false; options.regenerateAI = false
            await gate.arm()
            let start = Task { try await f.manager.startReprocessing(for: recording, options: options) }; task = start
            try await gate.waitForArrival()
            #expect(old.isValid)
            #expect(f.state.liveRecordingSessions.entry(recordingID: recording.id) == nil)
            #expect(throws: (any Error).self) { _ = try old.artifacts.beginChatRequest() }
            start.cancel()
            #expect(throws: (any Error).self) { try old.artifacts.clearChat() }
            await gate.release()
            await #expect(throws: CancellationError.self) { try await start.value }
            #expect(old.isValid && f.state.liveRecordingSessions.entry(recordingID: recording.id) === old)
            #expect(try await f.manager.reprocessingStore.pendingAttempt(audioURL: audio) == nil)
            #expect(try Data(contentsOf: chatURL) == bytes)
            f.state.processingJob = nil; await f.clean()
        } catch { await gate.release(); _ = try? await task?.value; f.state.processingJob = nil; await f.clean(); throw error }
    }

    private func replaceRecordingMetadataOwner(_ audio: URL) throws -> Data {
        let url = audio.deletingPathExtension().appendingPathExtension("json")
        var metadata = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        metadata["recordingID"] = UUID().uuidString
        let bytes = try JSONSerialization.data(withJSONObject: metadata, options: .sortedKeys)
        try bytes.write(to: url, options: .atomic)
        return bytes
    }

    @Test(arguments: [false, true]) func foreignMetadataBeforeOrAfterDurablePreparationCannotReopenOrClaimTheForeignRecording(afterJournal: Bool) async throws {
        let gate = LiveArtifactGate(stage: .journalPrepared)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, reprocessingStage: { stage in
            if stage == (afterJournal ? .snapshotPrepared : .snapshotAdmission) { try? await gate.enter(.journalPrepared) }
        })
        var pending: Task<Void, any Error>?
        do {
            let (recording, old, audio, chatURL) = try await prepareForDeletion(f, bound: true)
            let chat = try Data(contentsOf: chatURL)
            let busy = Recording(id: UUID(), date: Date(), fileURL: f.files.root.appendingPathComponent("busy.m4a"), duration: 0,
                meetingTitleDraft: "Busy", finalizedAudioURL: nil)
            f.state.processingJob = ProcessingJob(recording: busy)
            var options = ReprocessingOptions(settings: f.settings, operation: .transcribe)
            options.diarizationEnabled = false; options.regenerateAI = false
            let start = Task { try await f.manager.startReprocessing(for: recording, options: options) }; pending = start
            try await gate.waitForArrival()
            let foreign = try replaceRecordingMetadataOwner(audio)
            await gate.release()
            await #expect(throws: (any Error).self) { try await start.value }
            let attempt = try await f.manager.reprocessingStore.pendingAttempt(audioURL: audio)
            #expect((attempt != nil) == afterJournal)
            if afterJournal {
                #expect(!old.isValid)
                #expect(f.state.liveRecordingSessions.entry(recordingID: recording.id) == nil)
                #expect(f.state.liveRecordingSessions.replacement(attemptID: try #require(attempt).id) != nil)
                await #expect(throws: (any Error).self) { _ = try await f.manager.prepareLiveHistory(recordingID: recording.id, audioURL: audio) }
            } else { #expect(old.isValid && f.state.liveRecordingSessions.entry(recordingID: recording.id) === old) }
            #expect(try Data(contentsOf: audio.deletingPathExtension().appendingPathExtension("json")) == foreign)
            #expect(try Data(contentsOf: chatURL) == chat)
            f.state.processingJob = nil; await f.clean()
        } catch { await gate.release(); _ = try? await pending?.value; f.state.processingJob = nil; await f.clean(); throw error }
    }

    @Test func foreignMetadataDuringPublicationAdmissionPreservesCanonicalResultsAndTheDurableCandidate() async throws {
        let gate = LiveArtifactGate(stage: .journalPrepared)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, reprocessingStage: { stage in
            if stage == .publicationAdmission { try? await gate.enter(.journalPrepared) }
        })
        var job: ProcessingJob?
        do {
            let (recording, old, audio, chatURL) = try await prepareForDeletion(f, bound: true)
            let chat = try Data(contentsOf: chatURL)
            let candidate = try await stageModelFreeReplacement(f, recording: recording, audio: audio, text: "Foreign target")
            await f.manager.refreshReprocessingAttempts(); await f.manager.resumeReprocessing(candidate.id)
            job = try #require(f.state.processingJob)
            try await gate.waitForArrival()
            let foreign = try replaceRecordingMetadataOwner(audio)
            await gate.release(); await job?.task?.value
            #expect(!old.isValid)
            #expect(f.state.liveRecordingSessions.entry(recordingID: recording.id) == nil)
            #expect(try await f.manager.reprocessingStore.load(attemptID: candidate.id).status != .completed)
            #expect(!FileManager.default.fileExists(atPath: audio.deletingPathExtension().appendingPathExtension("transcript.json").path))
            #expect(!FileManager.default.fileExists(atPath: audio.deletingPathExtension().appendingPathExtension("richtranscript.json").path))
            #expect(try Data(contentsOf: chatURL) == chat)
            #expect(try Data(contentsOf: audio.deletingPathExtension().appendingPathExtension("json")) == foreign)
            await f.clean()
        } catch { await gate.release(); await job?.task?.value; await f.clean(); throw error }
    }

    @Test func foreignMetadataAfterDurableRestorationKeepsItsJournalBarrierAndRejectsRecoveryWrites() async throws {
        let gate = LiveArtifactGate(stage: .journalPrepared)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, reprocessingStage: { stage in
            if stage == .restorationPrepared { try? await gate.enter(.journalPrepared) }
        })
        var pending: Task<Void, any Error>?
        do {
            let (recording, _, audio, chatURL) = try await prepareForDeletion(f, bound: true)
            let candidate = try await stageModelFreeReplacement(f, recording: recording, audio: audio, text: "Current result")
            await f.manager.refreshReprocessingAttempts(); await f.manager.resumeReprocessing(candidate.id)
            let job = try #require(f.state.processingJob); await job.task?.value
            let old = try #require(f.state.liveRecordingSessions.entry(recordingID: recording.id))
            let rawURL = audio.deletingPathExtension().appendingPathExtension("transcript.json")
            let raw = try Data(contentsOf: rawURL), chat = try Data(contentsOf: chatURL)
            let restore = Task { try await f.manager.restoreReprocessingResults(for: recording) }; pending = restore
            try await gate.waitForArrival()
            let foreign = try replaceRecordingMetadataOwner(audio)
            await gate.release()
            await #expect(throws: (any Error).self) { try await restore.value }
            let journal = try #require(try await f.manager.reprocessingStore.pendingAttempt(audioURL: audio))
            #expect(journal.status == .publishing)
            #expect(!old.isValid && f.state.liveRecordingSessions.entry(recordingID: recording.id) == nil)
            #expect(f.state.liveRecordingSessions.replacement(attemptID: journal.id) != nil)
            await f.manager.recoverReprocessingAttempts()
            #expect(!f.manager.reprocessingRecoveryReady)
            #expect(try Data(contentsOf: rawURL) == raw && Data(contentsOf: chatURL) == chat)
            #expect(try Data(contentsOf: audio.deletingPathExtension().appendingPathExtension("json")) == foreign)
            await f.clean()
        } catch { await gate.release(); _ = try? await pending?.value; await f.clean(); throw error }
    }

    @Test(arguments: [false, true], [false, true]) func coldResumeOrDiscardCannotTransferAStoppedManagedJournalToByteIdenticalReplacementFiles(replaceAudio: Bool, discard: Bool) async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let (recording, _, audio, chatURL) = try await prepareForDeletion(f, bound: true)
            let chat = try Data(contentsOf: chatURL)
            let busy = Recording(id: UUID(), date: Date(), fileURL: f.files.root.appendingPathComponent("busy.m4a"), duration: 0,
                meetingTitleDraft: "Busy", finalizedAudioURL: nil)
            f.state.processingJob = ProcessingJob(recording: busy)
            var options = ReprocessingOptions(settings: f.settings, operation: .transcribe)
            options.diarizationEnabled = false; options.regenerateAI = false
            try await f.manager.startReprocessing(for: recording, options: options)
            let original = try #require(try await f.manager.reprocessingStore.pendingAttempt(audioURL: audio))
            let frozen = try #require(original.authority)
            let raw = TranscriptionResult(text: "Do not transfer", segments: [.init(start: 0, end: 1, text: "Do not transfer")])
            try await f.manager.reprocessingStore.stage(JSONEncoder().encode(raw), suffix: "transcript.json", attemptID: original.id)
            try await f.manager.reprocessingStore.stage(JSONEncoder().encode(RichTranscriptBuilder().build(from: raw)), suffix: "richtranscript.json", attemptID: original.id)
            try await f.manager.reprocessingStore.checkpoint(attemptID: original.id, status: .stopped, completedStage: "transcription")
            f.state.processingJob = nil
            let replacedURL = replaceAudio ? audio : audio.deletingPathExtension().appendingPathExtension("json")
            let sameBytes = try Data(contentsOf: replacedURL); try sameBytes.write(to: replacedURL, options: .atomic)
            let (state, manager) = f.restartedManager()
            await manager.recoverReprocessingAttempts(); await manager.discoverLiveHistory()
            if discard { await manager.discardReprocessing(original.id) }
            else { await manager.resumeReprocessing(original.id); await state.processingJob?.task?.value }
            let retained = try #require(try await manager.reprocessingStore.pendingAttempt(audioURL: audio))
            // Existing Resume semantics record rejected admission as failed;
            // explicit Discard rejection leaves the stopped candidate parked.
            #expect(retained.id == original.id && retained.status == (discard ? .stopped : .failed))
            #expect(retained.authority?.audio.stamp == frozen.audio.stamp && retained.authority?.metadata.stamp == frozen.metadata.stamp)
            #expect(state.liveRecordingSessions.entry(recordingID: recording.id) == nil)
            #expect(!manager.canLaunchProcessing(for: recording))
            #expect(!FileManager.default.fileExists(atPath: audio.deletingPathExtension().appendingPathExtension("transcript.json").path))
            #expect(try Data(contentsOf: replacedURL) == sameBytes && Data(contentsOf: chatURL) == chat)
            await f.clean()
        } catch { f.state.processingJob = nil; await f.clean(); throw error }
    }

    @Test func persistenceDisabledDiscardPreservesTheOriginalSavedFinalWithoutACompletedReceiptOrCaptureArtifact() async throws {
        let f = try LiveManagerFixture(engine: .nemotron, syntheticAudio: true, artifactPersistence: false)
        do {
            let start = Task { try await f.manager.startRecording() }
            #expect(await eventually { f.probe.createEntered }); f.probe.releaseCreate(); try await start.value
            let recording = try #require(f.state.currentRecording)
            await f.manager.stopRecording(); await f.manager.skipProcessing()
            let old = try #require(f.state.liveRecordingSessions.entry(recordingID: recording.id))
            let audio = try #require(recording.finalizedAudioURL)
            let original = TranscriptionResult(text: "Original saved RAM result", segments: [.init(start: 0, end: 1, text: "Original saved RAM result")])
            let rich = RichTranscriptBuilder().build(from: original)
            try JSONEncoder().encode(original).write(to: audio.deletingPathExtension().appendingPathExtension("transcript.json"))
            let richURL = audio.deletingPathExtension().appendingPathExtension("richtranscript.json")
            let richBytes = try JSONEncoder().encode(rich); try richBytes.write(to: richURL)
            let candidate = try await stageModelFreeReplacement(f, recording: recording, audio: audio, text: "Discard this")
            await f.manager.refreshReprocessingAttempts(); await f.manager.discardReprocessing(candidate.id)
            #expect(!old.isValid)
            let fresh = try #require(f.state.liveRecordingSessions.entry(recordingID: recording.id))
            #expect(try fresh.artifacts.finalContext()?.segments.map(\.text) == ["Original saved RAM result"])
            #expect(try Data(contentsOf: richURL) == richBytes)
            #expect(!fresh.artifacts.persistenceStarted)
            #expect(!FileManager.default.fileExists(atPath: f.files.root.appendingPathComponent("LiveSessions").path))
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func actualDiscardOfAnOlderAttemptRetiresItsResidentWritersBeforeTheClaimReleases() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let (recording, old, audio, chatURL) = try await prepareForDeletion(f, bound: true)
            let bytes = try Data(contentsOf: chatURL)
            let attempt = try await stageModelFreeReplacement(f, recording: recording, audio: audio, text: "Discarded candidate")
            await f.manager.refreshReprocessingAttempts(); await f.manager.discardReprocessing(attempt.id)
            #expect(!old.isValid)
            let fresh = try #require(f.state.liveRecordingSessions.entry(recordingID: recording.id))
            #expect(fresh !== old && fresh.identity == old.identity)
            #expect(try fresh.artifacts.finalContext() == nil)
            #expect(try fresh.artifacts.legacyContext().segments.map(\.text) == ["Preserve owned evidence"])
            #expect(try Data(contentsOf: chatURL) == bytes)
            await #expect(throws: CancellationError.self) {
                try await old.artifacts.writer.saveChat(.init(messages: [.init(role: .user, content: "Old callback")]), revision: old.artifacts.acceptedChatRevision + 1)
            }
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func restartKeepsAVerifiedEditorPublicationInsteadOfRollingBackToTheReprocessingReceipt() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let (recording, _, audio, _) = try await prepareForDeletion(f, bound: true)
            let attempt = try await stageModelFreeReplacement(f, recording: recording, audio: audio, text: "Processed text")
            await f.manager.refreshReprocessingAttempts(); await f.manager.resumeReprocessing(attempt.id)
            let job = try #require(f.state.processingJob); await job.task?.value
            let current = try #require(f.state.liveRecordingSessions.entry(recordingID: recording.id))
            var edited = try await f.manager.transcriptStore.load(from: audio.deletingPathExtension().appendingPathExtension("richtranscript.json"))
            edited.segments[0].text = "Latest user edit"
            try await f.manager.saveEditedTranscript(edited, for: recording, expectedRevision: f.manager.reprocessingResultsRevision)
            try await current.artifacts.flush()
            let before = try #require(try current.artifacts.finalContext())
            let ledgerURL = audio.deletingPathExtension().appendingPathExtension("live-transcript.json"), bytes = try Data(contentsOf: ledgerURL)
            let (state, manager) = f.restartedManager()
            await manager.recoverReprocessingAttempts(); await manager.discoverLiveHistory()
            let reopened = try #require(try await state.liveRecordingSessions.resolve(recordingID: recording.id, audioURL: audio))
            let source = try #require(try reopened.artifacts.finalContext())
            #expect(source.segments.map(\.text) == ["Latest user edit"])
            #expect(source.source.publicationID == before.source.publicationID && source.source.publicationRevision == before.source.publicationRevision)
            #expect(try Data(contentsOf: ledgerURL) == bytes)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func actualColdLibraryDeleteReloadsThePersistedOwner() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let (_, entry, audio, history) = try await prepareForDeletion(f, bound: true)
            try f.state.liveRecordingSessions.retire(entry.identity)
            let (restarted, manager) = f.restartedManager()
            #expect(restarted.liveRecordingSessions.entry(recordingID: entry.identity.recordingID) == nil)
            try await manager.deleteRecording(audio)
            #expect(!FileManager.default.fileExists(atPath: audio.path))
            #expect(!FileManager.default.fileExists(atPath: history.path))
            #expect(try await LiveSessionArtifactStore(identity: entry.identity,
                rootURL: f.files.root.appendingPathComponent("LiveSessions")).recover().deleted)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test(arguments: [true, false])
    func actualRestartFinalizationReconnectsHistoryWithoutAWindowAndKeepsAudioWhenHistoryIsUnavailable(healthy: Bool) async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, realManifest: true)
        do {
            let (recording, entry, _, _) = try await prepareForDeletion(f, bound: false)
            let sourceURL = f.files.root.appendingPathComponent("LiveSessions/\(entry.identity.captureSessionID)/live-transcript.json")
            if !healthy { try Data("{\"version\":99}".utf8).write(to: sourceURL, options: .atomic) }
            let original = try Data(contentsOf: sourceURL)
            try f.state.liveRecordingSessions.retire(entry.identity)
            let (state, manager) = f.restartedManager()
            await manager.recoverReprocessingAttempts(); await manager.discoverLiveHistory()
            #expect(state.liveRecordingSessions.entry(recordingID: recording.id) == nil)
            #expect(await manager.recoverInterruptedSessions())
            let finalized = try #require(try manager.processingPipeline.findFinalizedRecording(recordingID: recording.id, in: [f.settings.recordingFolderURL]))
            #expect(FileManager.default.fileExists(atPath: finalized.audioURL.path))
            if healthy {
                let loaded = try #require(state.liveRecordingSessions.entry(recordingID: recording.id))
                #expect(loaded.artifacts.admittedAudioURL == finalized.audioURL && loaded.artifacts.isDurable)
                let bound = try LiveTranscriptArtifactCodec.decode(Data(contentsOf: finalized.audioURL.deletingPathExtension().appendingPathExtension("live-transcript.json")))
                #expect(try bound.encoded(generation: nil, limit: 3 * 1_024 * 1_024) == original)
            } else {
                #expect(state.liveRecordingSessions.entry(recordingID: recording.id) == nil)
                #expect(state.durabilityNoticeIsWarning && manager.liveHistoryRecoveryNotice != nil)
                #expect(try Data(contentsOf: sourceURL) == original)
            }
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func actualResumedProcessingPublishesTheCommittedFinalWithoutAHistoryWindow() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        do {
            let (recording, entry, audio, _) = try await prepareForDeletion(f, bound: true)
            try await f.manager.processingPipeline.saveTranscript(.init(text: "Resumed committed final", segments: [.init(start: 0, end: 1, text: "Resumed committed final")]),
                to: audio.deletingPathExtension().appendingPathExtension("transcript.json"))
            let prepared = f.manager.launchJob(recording: recording, persistedRequest: .init(transcribe: true, summary: false,
                actionItems: false, tags: false, titleWasUserProvided: true, autoResume: true)) { _ in }
            await prepared.task?.value
            try #require(prepared.persistedRecord != nil)
            f.state.processingJob = nil
            try f.state.liveRecordingSessions.retire(entry.identity)
            let (state, manager) = f.restartedManager()
            await manager.recoverReprocessingAttempts(); await manager.discoverLiveHistory()
            await manager.resumeInterruptedProcessingJob()
            let resumed = try #require(state.processingJob)
            await resumed.task?.value
            let loaded = try #require(state.liveRecordingSessions.entry(recordingID: recording.id))
            try await loaded.artifacts.flush()
            let final = try #require(try loaded.artifacts.finalContext())
            #expect(final.segments.contains { $0.text.contains("Resumed committed final") })
            #expect(try await loaded.artifacts.writer.recover().appTranscript?.finalPublication != nil)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test(arguments: [(false, false, false), (false, false, true), (false, true, false), (false, true, true),
                      (true, false, false), (true, false, true), (true, true, false), (true, true, true)])
    func actualRestartCannotFinalizeOrProcessAKnownDeletedCaptureAfterCleanupFailure(configuration: (Bool, Bool, Bool)) async throws {
        let (bound, captureEnabled, staleCatalogue) = configuration
        let fault = LiveArtifactFault(stage: .deletionCleanup)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, realManifest: !bound,
            stage: { try await fault.check($0) })
        do {
            let (recording, entry, audio, _) = try await prepareForDeletion(f, bound: bound)
            let originalAudio = try Data(contentsOf: audio)
            let (state, manager) = f.restartedManager(captureEnabled: captureEnabled)
            await manager.recoverReprocessingAttempts()
            if staleCatalogue {
                let directory = f.files.root.appendingPathComponent("LiveSessions/\(entry.identity.captureSessionID)")
                let parked = f.files.root.appendingPathComponent("parked-live-session")
                try FileManager.default.moveItem(at: directory, to: parked)
                await manager.discoverLiveHistory()
                try FileManager.default.moveItem(at: parked, to: directory)
            }
            var jobURL: URL?, originalJob: Data?
            if bound {
                let job = f.manager.launchJob(recording: recording, persistedRequest: .init(transcribe: true, summary: false,
                    actionItems: false, tags: false, titleWasUserProvided: true, autoResume: true)) { _ in }
                await job.task?.value; try #require(job.persistedRecord != nil); f.state.processingJob = nil
                jobURL = f.files.root.appendingPathComponent("jobs/\(job.id.uuidString.lowercased())/job.json")
                originalJob = try jobURL.map { try Data(contentsOf: $0) }
                await #expect(throws: (any Error).self) { try await f.manager.deleteRecording(audio) }
            } else { await f.manager.discardRecording() }
            #expect(f.state.liveRecordingSessions.hasPendingDeletion(recordingID: recording.id))
            if !staleCatalogue { await manager.discoverLiveHistory() }
            if bound {
                await manager.resumeInterruptedProcessingJob()
                await state.processingJob?.task?.value
                #expect(state.processingJob == nil && state.processingRecording?.transcription == nil)
                #expect(try Data(contentsOf: #require(jobURL)) == originalJob)
            } else {
                let manifest = try #require(recording.recoveryManifestURL), originalManifest = try Data(contentsOf: manifest)
                #expect(await manager.recoverInterruptedSessions() == false)
                #expect(try manager.processingPipeline.findFinalizedRecording(recordingID: recording.id, in: [f.settings.recordingFolderURL]) == nil)
                #expect(try Data(contentsOf: manifest) == originalManifest)
            }
            #expect(try Data(contentsOf: audio) == originalAudio)
            #expect(state.liveRecordingSessions.entry(recordingID: entry.identity.recordingID) == nil)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test(arguments: [false, true])
    func actualReprocessingAdmissionCannotBypassAKnownDeletedOwner(staleCatalogue: Bool) async throws {
        let fault = LiveArtifactFault(stage: .deletionCleanup)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, stage: { try await fault.check($0) })
        do {
            let (recording, _, audio, _) = try await prepareForDeletion(f, bound: true)
            let (state, manager) = f.restartedManager()
            await manager.recoverReprocessingAttempts()
            if staleCatalogue {
                let entry = try #require(f.state.liveRecordingSessions.entry(recordingID: recording.id))
                let directory = f.files.root.appendingPathComponent("LiveSessions/\(entry.identity.captureSessionID)")
                let parked = f.files.root.appendingPathComponent("parked-live-session")
                try FileManager.default.moveItem(at: directory, to: parked)
                await manager.discoverLiveHistory()
                try FileManager.default.moveItem(at: parked, to: directory)
            }
            await #expect(throws: (any Error).self) { try await f.manager.deleteRecording(audio) }
            if !staleCatalogue { await manager.discoverLiveHistory() }
            let attempt = UUID(); var bodyRan = false
            if !staleCatalogue { #expect(manager.canLaunchProcessing(for: recording, reprocessingAttemptID: attempt) == false) }
            let job = manager.launchJob(recording: recording, persistedRequest: .init(transcribe: true, summary: false,
                actionItems: false, tags: false, titleWasUserProvided: true, autoResume: false),
                reprocessingAttemptID: attempt) { _ in bodyRan = true }
            await job.task?.value
            #expect(!bodyRan && state.processingJob == nil)
            #expect(try await manager.processingJobStore.load(id: job.id) == nil)
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test func actualColdLibraryDeleteResumesASavedIntentWithoutReopeningHistory() async throws {
        let fault = LiveArtifactFault(stage: .deletionCleanup)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, stage: { try await fault.check($0) })
        do {
            let (_, entry, audio, history) = try await prepareForDeletion(f, bound: true)
            await #expect(throws: (any Error).self) { try await f.manager.deleteRecording(audio) }
            #expect(FileManager.default.fileExists(atPath: audio.path) && FileManager.default.fileExists(atPath: history.path))
            let (restarted, manager) = f.restartedManager()
            try await manager.deleteRecording(audio)
            #expect(restarted.liveRecordingSessions.entry(recordingID: entry.identity.recordingID) == nil)
            #expect(!FileManager.default.fileExists(atPath: audio.path) && !FileManager.default.fileExists(atPath: history.path))
            #expect(!restarted.liveRecordingSessions.hasPendingDeletion(recordingID: entry.identity.recordingID))
            await f.clean()
        } catch { await f.clean(); throw error }
    }

    @Test(arguments: [false, true])
    func actualColdDeletePreservesAForeignReplacementDuringTheHeldLoad(metadata: Bool) async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true)
        let gate = LiveArtifactGate(stage: .historyLoad)
        var deletion: Task<Bool, Never>?
        do {
            let (_, entry, audio, history) = try await prepareForDeletion(f, bound: true)
            try f.state.liveRecordingSessions.retire(entry.identity)
            let originalHistory = try Data(contentsOf: history)
            let (_, manager) = f.restartedManager(stage: { try await gate.enter($0) })
            let held = Task { do { try await manager.deleteRecording(audio); return true } catch { return false } }
            deletion = held; try await gate.waitForArrival()
            let replaced = metadata ? audio.deletingPathExtension().appendingPathExtension("json") : audio
            let foreign = metadata ? try JSONEncoder().encode(RecordingMetadataPayload(recordingID: UUID(), dateISO8601: "foreign", durationSeconds: 1,
                meetingTitle: "Foreign", masterFileName: audio.lastPathComponent, segmentFileNames: [], warnings: [])) : Data("Foreign master".utf8)
            try foreign.write(to: replaced, options: .atomic)
            await gate.release()
            #expect(await held.value == false)
            #expect(try Data(contentsOf: replaced) == foreign && Data(contentsOf: history) == originalHistory)
            await f.clean()
        } catch { await gate.release(); _ = await deletion?.value; await f.clean(); throw error }
    }

    @Test func actualProviderPreparationFindsFinalizedAudioBeforeBindingWithoutRewritingTheSource() async throws {
        let f = try LiveManagerFixture(engine: .appleSpeech)
        do {
            let identity = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
            let directory = f.settings.recordingFolderURL
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let audio = directory.appendingPathComponent("unexpected-master.wav")
            try Data("Model-free master".utf8).write(to: audio)
            try JSONEncoder().encode(RecordingMetadataPayload(recordingID: identity.recordingID, dateISO8601: "fixture", durationSeconds: 1,
                meetingTitle: "Fixture", masterFileName: audio.lastPathComponent, segmentFileNames: [], warnings: []))
                .write(to: audio.deletingPathExtension().appendingPathExtension("json"))
            let root = f.files.root.appendingPathComponent("LiveSessions")
            let source = LiveTranscriptArtifact(identity: identity, revision: 5, legacy: [.init(.init(start: 0, end: 1, text: "Recovered source"))])
            try await LiveSessionArtifactStore(identity: identity, rootURL: root).saveTranscript(source)
            let original = try Data(contentsOf: root.appendingPathComponent("\(identity.captureSessionID)/live-transcript.json"))
            let (state, manager) = f.restartedManager()
            await manager.recoverReprocessingAttempts(); await manager.discoverLiveHistory()
            let entry = try #require(try await manager.prepareLiveHistory(recordingID: identity.recordingID, audioURL: audio))
            #expect(state.liveRecordingSessions.entry(recordingID: identity.recordingID) === entry)
            #expect(entry.artifacts.admittedAudioURL == audio && entry.artifacts.acceptedRevision == 5)
            let bound = try LiveTranscriptArtifactCodec.decode(Data(contentsOf: audio.deletingPathExtension().appendingPathExtension("live-transcript.json")))
            #expect(try bound.encoded(generation: nil, limit: 3 * 1_024 * 1_024) == original)
            await f.clean()
        } catch { await f.clean(); throw error }
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

    @Test(arguments: [(false, false), (true, false), (true, true)])
    func actualLibraryRetryRetainsPendingPrivacyTargetsAfterMetadataAndSnapshotsAreGone(configuration: (Bool, Bool)) async throws {
        let (bound, restart) = configuration
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
            if restart {
                let (state, manager) = f.restartedManager()
                try await manager.deleteRecording(audio)
                #expect(state.liveRecordingSessions.entry(recordingID: recording.id) == nil && !state.liveRecordingSessions.hasPendingDeletion(recordingID: recording.id))
                f.state.liveRecordingSessions.completeDeletion(recordingID: recording.id)
            } else if bound { try await f.manager.deleteRecording(audio) } else { await f.manager.discardRecording() }
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
        let budget = LiveRecordingPayloadBudget(ownerLimit: 8)
        let f = try LiveManagerFixture(engine: .appleSpeech, syntheticAudio: true, payloadBudget: budget)
        do {
            let (_, entry, audio, _) = try await prepareForDeletion(f, bound: true)
            let registry = f.state.liveRecordingSessions
            for _ in 0..<2 { _ = try registry.registerLegacy(.init(recordingID: UUID(), captureSessionID: UUID())) }
            let inspection = try budget.reserveAuxiliary(bytes: 31 * 1_024 * 1_024)
            defer { withExtendedLifetime(inspection) {} }
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
            for _ in 0..<3 {
                _ = try f.state.liveRecordingSessions.registerLegacy(.init(recordingID: UUID(), captureSessionID: UUID()))
            }
            #expect(f.state.liveRecordingSessions.reservedPayloadBytes == 3 * LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
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
