import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Reprocessing manager integration", .serialized) @MainActor
struct ReprocessingManagerTests {
    @Test func retranscriptionProgressWaitsForModelThenShowsAnEstimateAndStopsOnFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let recording = fixture.recording()
        recording.duration = 120
        let job = ProcessingJob(recording: recording)
        job.reprocessingAttemptID = job.id
        fixture.state.processingJob = job
        fixture.state.processingSteps = [.init(name: "Loading WhisperKit model…", status: .inProgress)]
        var options = ReprocessingOptions(settings: fixture.settings, operation: .transcribe)
        options.engine = .localWhisper
        let config = try options.transcriptionSettings(settings: fixture.settings)
        let bridge = ProcessingStepProgress(appState: fixture.state, job: job, stepIndex: 0)
        defer { bridge.invalidate() }
        struct Finished: Error {}
        do {
            try await fixture.manager.withTranscriptionProgress(job: job, stepIndex: 0, settings: config) {
                #expect(job.transcriptionStartedAt == nil)
                try await Task.sleep(for: .milliseconds(1100))
                #expect(fixture.state.processingSteps[0].progress == nil)
                bridge.applyPluginState(.transcribing)
                // A slow backend emits no words yet, but still needs progress feedback.
                try await Task.sleep(for: .milliseconds(1200))
                #expect((fixture.state.processingSteps[0].progress ?? 0) > 0)
                #expect(fixture.state.processingSteps[0].detail?.contains("left") == true)
                throw Finished()
            }
        } catch { #expect(error is Finished) }
        #expect(job.transcriptionStartedAt == nil)
        fixture.state.processingSteps[0].detail = "Next phase"
        try await Task.sleep(for: .milliseconds(1100))
        #expect(fixture.state.processingSteps[0].detail == "Next phase")
    }

    @Test("Completed stages publish without their former endpoints", arguments: [false, true])
    func resumesCompletedStagesWithoutResolvingEndpoints(changed: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let settings = fixture.settings
        let previousTranscriptionEndpoints = settings.transcriptionEndpoints
        let previousAIEndpoints = settings.aiEndpoints
        defer {
            settings.transcriptionEndpoints = previousTranscriptionEndpoints
            settings.aiEndpoints = previousAIEndpoints
        }
        let transcriptionEndpoint = Endpoint(name: "Saved transcription", baseURL: "http://127.0.0.1:1", modelName: "saved-asr")
        let aiEndpoint = Endpoint(name: "Saved analysis", baseURL: "http://127.0.0.1:1", modelName: "saved-ai")
        var options = ReprocessingOptions(settings: settings, operation: .transcribe)
        options.engine = .remoteEndpoint
        options.aiEngine = .remoteEndpoint
        options.transcriptionEndpoint = transcriptionEndpoint
        options.aiEndpoint = aiEndpoint
        options.diarizationEnabled = false
        options.regenerateAI = true
        options.vocabulary = []
        if changed {
            var changedTranscription = transcriptionEndpoint
            changedTranscription.modelName = "replacement-asr"
            var changedAI = aiEndpoint
            changedAI.modelName = "replacement-ai"
            settings.transcriptionEndpoints = [changedTranscription]
            settings.aiEndpoints = [changedAI]
        } else {
            settings.transcriptionEndpoints = []
            settings.aiEndpoints = []
        }
        // A mistaken stage replay fails configuration validation before any
        // provider can be contacted. Publication needs neither endpoint.
        #expect(throws: ReprocessingOptions.ConfigurationError.self) { try options.transcriptionSettings(settings: settings) }
        #expect(throws: ReprocessingOptions.ConfigurationError.self) { try options.analysisConfiguration(settings: settings) }

        let recording = fixture.recording()
        let source = try Data(contentsOf: fixture.audio)
        let oldRaw = TranscriptionResult(text: "Original transcript")
        try JSONEncoder().encode(oldRaw).write(to: fixture.sidecar("transcript.json"))
        let note = Data("An independently edited exported note".utf8)
        try note.write(to: fixture.sidecar("md"))
        let request = ReprocessingRequest(options: options, recordingID: recording.id,
            date: recording.date, title: recording.meetingTitleDraft, duration: recording.duration,
            participants: [], calendarEvent: nil)
        let attempt = try await fixture.store.prepare(audioURL: fixture.audio,
            configuration: JSONEncoder().encode(request))
        let candidate = TranscriptionResult(text: "Replacement transcript",
            segments: [.init(start: 0, end: 2, text: "Replacement transcript")], modelName: "saved-asr")
        let rich = RichTranscriptBuilder().build(from: candidate)
        let insights = RecordingInsights(summary: "Replacement summary", actionItems: ["Follow up"], tags: ["replacement"],
            sentiment: "Neutral", generatedTitle: nil, markdownPath: nil)
        try await fixture.store.stage(JSONEncoder().encode(candidate), suffix: "transcript.json", attemptID: attempt.id)
        try await fixture.store.stage(JSONEncoder().encode(rich), suffix: "richtranscript.json", attemptID: attempt.id)
        try await fixture.store.stage(JSONEncoder().encode(insights), suffix: "insights.json", attemptID: attempt.id)
        try await fixture.store.checkpoint(attemptID: attempt.id, status: .ready, completedStage: "transcription")
        try await fixture.store.checkpoint(attemptID: attempt.id, status: .stopped, completedStage: "analysis")
        fixture.manager.reprocessingAttempts = [try await fixture.store.load(attemptID: attempt.id)]
        #expect(!fixture.manager.canLaunchProcessing(for: recording))

        // A different recording's runtime match must survive this isolated run.
        let automaticOwner = UUID()
        settings.routeAutomatically(to: fixture.automaticProfile.id, for: automaticOwner)
        let baseline = settings.activeProfileId
        let revision = fixture.manager.reprocessingResultsRevision
        await fixture.manager.resumeReprocessing(attempt.id)
        let job = try #require(fixture.state.processingJob)
        #expect(job.id == attempt.id)
        #expect(job.reprocessingAttemptID == attempt.id)
        #expect(job.recording !== recording)
        #expect(job.recording.id == recording.id)
        job.recording.privacyScope = RecordingPrivacyScope(recordingID: recording.id,
            store: fixture.privacyStore, pendingRootURL: fixture.root.appendingPathComponent("privacy-pending"))
        await job.task?.value

        #expect(fixture.state.processingJob == nil)
        #expect(fixture.state.lastError == nil)
        #expect(fixture.manager.reprocessingResultsRevision == revision + 1)
        #expect(try await fixture.store.load(attemptID: attempt.id).status == .completed)
        #expect(try await fixture.store.pendingAttempt(audioURL: fixture.audio) == nil)
        #expect(settings.activeProfileId == baseline)
        #expect(settings.automaticProfileId == fixture.automaticProfile.id)
        #expect(settings.automaticProfileRecordingID == automaticOwner)
        #expect(try Data(contentsOf: fixture.audio) == source)
        #expect(try Data(contentsOf: fixture.sidecar("md")) == note)
        let published = try JSONDecoder().decode(TranscriptionResult.self, from: Data(contentsOf: fixture.sidecar("transcript.json")))
        #expect(published.text == candidate.text && published.modelName == "saved-asr")
        let publishedInsights = try JSONDecoder().decode(RecordingInsights.self, from: Data(contentsOf: fixture.sidecar("insights.json")))
        #expect(publishedInsights.summary == "Replacement summary")
        #expect(publishedInsights.markdownPath == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.sidecar("queue.json").path))
        #expect(await fixture.jobs.discover().jobs.isEmpty)
        #expect(try await fixture.deliveries.discover().isEmpty)
        #expect(fixture.manager.pendingQueueItems.isEmpty)
        #expect(fixture.manager.recoveryQueueEntries.isEmpty)
        #expect(fixture.manager.canLaunchProcessing(for: recording))
    }

    @Test func stoppedAttemptBlocksOrdinaryProcessingUntilExplicitDiscard() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let recording = fixture.recording()
        let attempt = try await fixture.store.prepare(audioURL: fixture.audio, configuration: Data())
        try await fixture.store.checkpoint(attemptID: attempt.id, status: .stopped)
        await fixture.manager.refreshReprocessingAttempts()
        #expect(fixture.state.processingJob == nil)
        #expect(!fixture.manager.canLaunchProcessing(for: recording))
        #expect(fixture.manager.canLaunchProcessing(for: recording, reprocessingAttemptID: attempt.id))
        #expect(!fixture.manager.canLaunchProcessing(for: fixture.recording()))
        let alias = fixture.root.appendingPathComponent("alias.m4a")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.audio)
        let aliasedRecording = Recording(fileURL: alias, finalizedAudioURL: alias)
        #expect(!fixture.manager.canLaunchProcessing(for: aliasedRecording))
        await fixture.manager.discardReprocessing(attempt.id)
        #expect(fixture.manager.canLaunchProcessing(for: recording))
        #expect(try Data(contentsOf: fixture.audio) == Data([0, 1, 2, 3]))
        #expect(!FileManager.default.fileExists(atPath: fixture.sidecar("queue.json").path))
    }

    @Test func linkedCalendarSurvivesReopeningAndIsFrozenForReprocessing() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = RecordingMetadataPayload(dateISO8601: ISO8601DateFormatter().string(from: date),
            durationSeconds: 60, meetingTitle: "Custom title", masterFileName: fixture.audio.lastPathComponent,
            segmentFileNames: [], warnings: [], participants: ["Alex"])
        try JSONEncoder().encode(payload).write(to: fixture.sidecar("json"))
        let event = CalendarEvent(title: "Planning", attendees: [.init(name: "Sam", email: nil)],
            body: "Next quarter", startDate: date, endDate: date.addingTimeInterval(60))
        let recording = fixture.recording()
        let revision = fixture.manager.calendarContextRevision
        try await fixture.manager.linkCalendar(event, to: recording, updateTitle: false, updateParticipants: false)
        #expect(fixture.manager.calendarContextRevision == revision + 1)
        // An unrelated active job keeps the new attempt queued without running an engine.
        fixture.state.processingJob = ProcessingJob(recording: Recording(fileURL: fixture.root.appendingPathComponent("other.wav")))
        let reopened = fixture.recording()
        #expect(reopened.calendarEvent == nil)
        var options = ReprocessingOptions(settings: fixture.settings, operation: .transcribe)
        options.engine = .appleSpeech
        options.spokenLanguage = ""
        options.vocabulary = []
        options.regenerateAI = false
        options.diarizationEnabled = false
        try await fixture.manager.startReprocessing(for: reopened, options: options)
        let attempt = try #require(fixture.manager.reprocessingAttempts.first)
        let request = try JSONDecoder().decode(ReprocessingRequest.self, from: attempt.configuration)
        #expect(request.calendarEvent == event)
        #expect(request.date == date && request.duration == 60)
        #expect(request.title == "Custom title" && request.participants == ["Alex"])
        await #expect(throws: ReprocessingError.self) {
            try await fixture.manager.linkCalendar(event, to: reopened, updateTitle: true, updateParticipants: true)
        }
        fixture.state.processingJob = nil
    }

    @MainActor private final class Fixture {
        let root: URL
        let audio: URL
        let settings: AppSettings
        let state: AppState
        let store: ReprocessingStore
        let jobs: ProcessingJobStore
        let deliveries: IntegrationDeliveryStore
        let privacyStore: PrivacyReceiptStore
        let automaticProfile: MeetingProfile
        let manager: RecordingManager
        private let oldFolder: URL
        private let oldProfiles: [MeetingProfile]
        private let oldActiveProfile: UUID
        private let oldAutomaticProfile: UUID?
        private let oldAutomaticOwner: UUID?

        init() throws {
            let settings = AppSettings()
            let state = AppState()
            self.settings = settings
            self.state = state
            root = FileManager.default.temporaryDirectory.appendingPathComponent("reprocessing-manager-\(UUID())").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            audio = root.appendingPathComponent("meeting.m4a")
            try Data([0, 1, 2, 3]).write(to: audio)
            oldFolder = settings.recordingFolderURL
            oldProfiles = settings.profiles
            oldActiveProfile = settings.activeProfileId
            oldAutomaticProfile = settings.automaticProfileId
            oldAutomaticOwner = settings.automaticProfileRecordingID
            let baseline = MeetingProfile(name: "Test baseline")
            automaticProfile = MeetingProfile(name: "Test automatic")
            settings.recordingFolderURL = root
            settings.profiles = [baseline, automaticProfile]
            settings.setActiveProfile(baseline.id)
            store = ReprocessingStore(root: root.appendingPathComponent("attempts"))
            jobs = ProcessingJobStore(rootURL: root.appendingPathComponent("jobs"))
            deliveries = IntegrationDeliveryStore(rootURL: root.appendingPathComponent("deliveries"))
            privacyStore = PrivacyReceiptStore(gapDirectoryURL: root.appendingPathComponent("privacy-gaps"),
                pendingDirectoryURL: root.appendingPathComponent("privacy-pending"))
            manager = RecordingManager(appState: state, appSettings: settings,
                transcriptStore: TranscriptStore(), insightsStore: InsightsStore(),
                voiceLibraryStore: VoiceLibraryStore(url: root.appendingPathComponent("voices.json")),
                modelPerformanceStore: ModelPerformanceStore(url: root.appendingPathComponent("performance.json")),
                processingJobStore: jobs, microsoftAuthService: MicrosoftAuthService(), reprocessingStore: store,
                queueScheduleStore: QueueScheduleStore(url: root.appendingPathComponent("schedule.json")),
                integrationDeliveryStore: deliveries)
            manager.reprocessingRecoveryReady = true
        }

        func recording() -> Recording {
            Recording(fileURL: audio, duration: 2, meetingTitleDraft: "Test meeting", finalizedAudioURL: audio)
        }

        func sidecar(_ suffix: String) -> URL { audio.deletingPathExtension().appendingPathExtension(suffix) }

        func clean() {
            settings.recordingFolderURL = oldFolder
            settings.profiles = oldProfiles
            settings.activeProfileId = oldActiveProfile
            settings.automaticProfileId = oldAutomaticProfile
            settings.automaticProfileRecordingID = oldAutomaticOwner
            try? FileManager.default.removeItem(at: root)
        }
    }
}
