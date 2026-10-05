import Foundation
import Testing
import dBriefWire
@testable import dBrief

@MainActor @Suite struct LiveTranscriptionSettingsTests {
    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let name = "dbrief-live-settings-" + UUID().uuidString
        return (try #require(UserDefaults(suiteName: name)), name)
    }
    @Test func absentLivePreferencesMigrateActualEffectiveLanguageAndKeepAppleAndLabelsOff() throws {
        let (defaults, name) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(liveDefaults: defaults)
        #expect(!settings.liveTranscriptionEnabled)
        #expect(settings.liveTranscriptionEngine == .appleSpeech)
        #expect(!settings.liveSpeakerLabelsEnabled)
        #expect(settings.nemotronLiveLanguage == .auto && settings.nemotronLiveChunkMs == 1120)
        #expect(settings.appleLiveLanguage == settings.effectiveTranscriptionLanguage)
        #expect(defaults.string(forKey: AppSettings.Keys.appleLiveLanguage) == settings.effectiveTranscriptionLanguage)
    }
    @Test func migrationUsesExactEffectiveProfileLanguageOnceAndDoesNotRewriteUnknownSavedChoice() throws {
        let (defaults, name) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        let profile = MeetingProfile(name: "Dutch live migration", overrides: .init(transcriptionLanguage: "nl"))
        let effective = try #require(profile.overrides.transcriptionLanguage)
        #expect(LiveTranscriptionPreferences.migrateAppleLanguage(in: defaults, legacyEffectiveLanguage: effective) == "nl")
        #expect(LiveTranscriptionPreferences.migrateAppleLanguage(in: defaults, legacyEffectiveLanguage: "en") == "nl")
        #expect(defaults.string(forKey: AppSettings.Keys.appleLiveLanguage) == "nl")
        defaults.set("unavailable-saved-locale", forKey: AppSettings.Keys.appleLiveLanguage)
        #expect(LiveTranscriptionPreferences.migrateAppleLanguage(in: defaults, legacyEffectiveLanguage: "en") == "unavailable-saved-locale")
        #expect(AppSettings(liveDefaults: defaults).appleLiveLanguage == "unavailable-saved-locale")
    }
    @Test func liveGroupSettersStayInInjectedDomainAndColdInitializationKeepsEveryChoice() throws {
        let (defaults, name) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        let keys = [AppSettings.Keys.liveTranscriptionEnabled, AppSettings.Keys.liveTranscriptionEngine,
                    AppSettings.Keys.appleLiveLanguage, AppSettings.Keys.nemotronLiveLanguage,
                    AppSettings.Keys.nemotronLiveChunkMs, AppSettings.Keys.liveSpeakerLabelsEnabled]
        let standard = keys.map { UserDefaults.standard.object(forKey: $0).map { String(describing: $0) } }
        let settings = AppSettings(liveDefaults: defaults)
        let finalEngine = settings.transcriptionEngine, finalLanguage = settings.effectiveTranscriptionLanguage
        settings.liveTranscriptionEnabled = true; settings.liveTranscriptionEngine = .nemotron
        settings.appleLiveLanguage = "nl"; settings.nemotronLiveLanguage = .en
        settings.nemotronLiveChunkMs = 560; settings.liveSpeakerLabelsEnabled = true
        #expect(settings.transcriptionEngine == finalEngine && settings.effectiveTranscriptionLanguage == finalLanguage)
        #expect(keys.map { UserDefaults.standard.object(forKey: $0).map { String(describing: $0) } } == standard)
        let cold = AppSettings(liveDefaults: defaults)
        #expect(cold.liveTranscriptionEnabled && cold.liveTranscriptionEngine == .nemotron)
        #expect(cold.appleLiveLanguage == "nl" && cold.nemotronLiveLanguage == .en)
        #expect(cold.nemotronLiveChunkMs == 560 && cold.liveSpeakerLabelsEnabled)
        let frozen = cold.liveTranscriptionPreferences
        cold.nemotronLiveLanguage = .nl; cold.nemotronLiveChunkMs = 2240; cold.liveSpeakerLabelsEnabled = false
        #expect(frozen.language == "en" && frozen.chunkMs == 560 && frozen.speakerLabels)
        cold.liveTranscriptionEngine = .appleSpeech
        #expect(cold.liveTranscriptionPreferences.language == "nl" && !cold.liveTranscriptionPreferences.speakerLabels)
    }
    @Test func malformedEngineLanguageAndChunkKeepExistingFallbackAndPermissionDefault() throws {
        let (defaults, name) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: AppSettings.Keys.liveTranscriptionEnabled)
        defaults.set("foreign", forKey: AppSettings.Keys.liveTranscriptionEngine)
        defaults.set("foreign", forKey: AppSettings.Keys.nemotronLiveLanguage)
        defaults.set(1, forKey: AppSettings.Keys.nemotronLiveChunkMs)
        let settings = AppSettings(liveDefaults: defaults)
        #expect(settings.liveTranscriptionEnabled && settings.liveTranscriptionEngine == .appleSpeech)
        #expect(settings.nemotronLiveLanguage == .auto && settings.nemotronLiveChunkMs == 1120)
        #expect(!settings.liveSpeakerLabelsEnabled)
        #expect(!CaptureCoordinator.Request(id: UUID(), startedAt: Date()).liveSpeakerLabelsEnabled)
    }
    @Test func catalogueNeverPromotesNativeCandidatesAndUnavailableRequestsCanBeWithdrawn() {
        let rows = LiveTranscriptionCatalogue.engines
        #expect(rows.map(\.engine) == [.appleSpeech, .nemotron])
        #expect(rows[0].canSelect && rows[0].availability == .managedAtStart)
        #expect(!rows[1].canSelect && rows[1].availability == .validationPending)
        #expect(!LiveTranscriptionCatalogue.canEnableSpeakerLabels)
        #expect(!LiveTranscriptionCatalogue.allowsLabelChange(current: false, requested: true))
        #expect(LiveTranscriptionCatalogue.allowsLabelChange(current: true, requested: false))
        #expect(LiveTranscriptionCatalogue.allowsLabelChange(current: true, requested: true))
    }

    @MainActor private final class Probe {
        var entered = false, request: CaptureCoordinator.Request?, selection: (String, Int, [LiveSource])?
        var hardwareStops = 0, previewStarts = 0
        private var waiter: CheckedContinuation<Void, Never>?
        func holdCreate() async { entered = true; await withCheckedContinuation { waiter = $0 } }
        func release() { waiter?.resume(); waiter = nil }
    }
    @Test func actualManagerFreezesRequestedNativeLanguageChunkAndLabelsBeforeHeldCaptureStart() async throws {
        let (defaults, name) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        let root = URL(fileURLWithPath: "/private/tmp/live-settings-manager-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(liveDefaults: defaults), state = AppState(liveArtifactRoot: root.appendingPathComponent("history"))
        settings.liveTranscriptionEnabled = true; settings.liveTranscriptionEngine = .nemotron
        settings.nemotronLiveLanguage = .nl; settings.nemotronLiveChunkMs = 560; settings.liveSpeakerLabelsEnabled = true
        let originalFinal = settings.effectiveTranscriptionLanguage, originalFinalEngine = settings.transcriptionEngine
        let probe = Probe()
        let (mic, micOut) = AsyncStream<LiveAudioBuffer>.makeStream()
        let (system, systemOut) = AsyncStream<LiveAudioBuffer>.makeStream()
        let ordinary = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"), supportBase: root,
            environment: ["STUB_MODE": "echo"])
        let persistence = CaptureCoordinator.Persistence(create: { id, date in
            await probe.holdCreate()
            return .init(id: id, startedAt: date, files: .init(directoryURL: root,
                manifestURL: root.appendingPathComponent("session.json"), captureBaseURL: root.appendingPathComponent("capture")))
        }, began: { _, _ in }, failedStart: { _, _, _ in }, stopped: { session, state, _ in
            .init(session: session, state: state, fileSize: 0, duration: state.duration)
        }, termination: { _ in }, pauseResume: { _, _, _ in })
        let hardware = CaptureCoordinator.Hardware(start: { request, _ in
            probe.request = request; return .init(mic: mic, system: system)
        }, stop: { probe.hardwareStops += 1; micOut.finish(); systemOut.finish() },
           snapshot: { .init(microphoneEnabled: true, systemAudioEnabled: true) }, pause: {}, resume: {}, switchInputDevice: { _ in },
           permissions: .init(microphone: { true }, systemAudio: { true }))
        let manager = RecordingManager(appState: state, appSettings: settings, transcriptStore: .init(), insightsStore: .init(),
            voiceLibraryStore: .init(url: root.appendingPathComponent("voices.json")),
            modelPerformanceStore: .init(url: root.appendingPathComponent("performance.json")),
            processingJobStore: .init(rootURL: root.appendingPathComponent("jobs")), microsoftAuthService: .init(),
            reprocessingStore: .init(root: root.appendingPathComponent("reprocessing")),
            queueScheduleStore: .init(url: root.appendingPathComponent("schedule.json")),
            integrationDeliveryStore: .init(rootURL: root.appendingPathComponent("deliveries")),
            captureHardware: hardware, capturePersistence: persistence,
            capturePreview: .init(prepare: { _ in nil }, make: {
                .init(start: { _, _ in await MainActor.run { probe.previewStarts += 1 } }, stop: {})
            }), mlHost: ordinary, liveSelectionProvider: { language, chunk, sources in
                probe.selection = (language.rawValue, chunk, sources); return nil
            })
        let start = Task { try await manager.startRecording() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !probe.entered && ContinuousClock.now < deadline { await Task.yield() }
        #expect(probe.entered)
        settings.liveTranscriptionEnabled = false; settings.liveTranscriptionEngine = .appleSpeech
        settings.nemotronLiveLanguage = .en; settings.nemotronLiveChunkMs = 2240; settings.liveSpeakerLabelsEnabled = false
        probe.release(); try await start.value
        let request = try #require(probe.request), selection = try #require(probe.selection)
        #expect(request.liveTranscription && request.liveEngine == .nemotron && request.language == "nl")
        #expect(request.liveSpeakerLabelsEnabled && request.nemotronSelection == nil)
        #expect(selection.0 == "nl" && selection.1 == 560 && selection.2 == [.microphone, .system])
        #expect(probe.previewStarts == 0 && !state.isLiveTranscribing)
        #expect(settings.effectiveTranscriptionLanguage == originalFinal && settings.transcriptionEngine == originalFinalEngine)
        await manager.prepareForTermination(); await ordinary.shutdown()
        #expect(probe.hardwareStops == 1)
    }
}
