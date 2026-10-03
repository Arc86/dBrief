import Foundation
import Testing
import dBriefWire
@testable import dBrief

@MainActor @Suite struct LiveRecordingFactoryTests {
    @MainActor private final class Probe {
        var appleStarts = 0, hardwareStarts = 0, unavailable = false
        func appleStarted() { appleStarts += 1 }
    }
    @Test func selectedUnavailableNemotronDoesNotStartAppleWhileCaptureSucceeds() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/factory-capture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureSessionStore(dependencies: .init(root: { root },record: { _ in }))
        let probe = Probe()
        let (mic,micOut) = AsyncStream<LiveAudioBuffer>.makeStream()
        let (system,systemOut) = AsyncStream<LiveAudioBuffer>.makeStream()
        let coordinator = CaptureCoordinator(hardware: .init(start: { _,_ in
            probe.hardwareStarts += 1; return .init(mic: mic,system: system)
        },stop: { micOut.finish(); systemOut.finish() },snapshot: { .init(microphoneEnabled: true,systemAudioEnabled: false) },
            pause: {},resume: {},switchInputDevice: { _ in }),persistence: .live(store),
            preview: .init(prepare: { _ in nil },make: { .init(start: { _,_ in await probe.appleStarted() },stop: {}) }),
            onEvent: { event in
                if case .status(_,let message) = event, message == "Live transcription unavailable" { probe.unavailable = true }
            })
        var request = CaptureCoordinator.Request(id: UUID(),startedAt: Date(),liveTranscription: true)
        request.liveEngine = .nemotron
        try await coordinator.start(request)
        await Task.yield()
        #expect(probe.hardwareStarts == 1 && probe.appleStarts == 0 && probe.unavailable)
        await coordinator.stop()
    }

    @Test func qualifiedFactoryFreezesFuturePathAndInstallsAnExactRecordingOwner() async throws {
        let files = try ASRAssetsFixture(); defer { files.remove() }
        let registry = LiveRecordingSessionRegistry(), resources = LiveModelResourcePolicy()
        let factory = LiveRecordingFactory(registry: registry,admission: .init(policy: resources,measurement: {
            .init(availableBytes: 2000,pressure: .normal)
        }))
        let id = UUID()
        var request = CaptureCoordinator.Request(id: id,startedAt: Date(),liveTranscription: true,language: "auto",
            privacyScope: .init(recordingID: id))
        request.liveEngine = .nemotron
        request.nemotronSelection = .init(profileID: "fixture",hardware: "fixture",sourceDirectory: files.source,
            identity: ASRAssetsFixture.identity(),language: .auto,chunkMs: 1120,sources: [.microphone],captureQualified: true)
        let prepared = try #require(factory.prepare(request))
        #expect(prepared.ingress.input.identity.recordingID == id)
        #expect(prepared.ingress.input.identity.captureSessionID == request.captureSessionID)
        #expect(prepared.ingress.input.configuration.modelDirectory != files.source.path)
        #expect(!FileManager.default.fileExists(atPath: prepared.ingress.input.configuration.modelDirectory))
        let entry = try #require(registry.entry(recordingID: id))
        #expect(entry.coordinator != nil && entry.identity == prepared.session.identity)
        prepared.session.expire()
        #expect(registry.entry(recordingID: id) === entry)
        try registry.retire(entry.identity)
    }

    @Test func unqualifiedOrForeignLanguageSelectionCannotCreateARegistryOwner() async throws {
        let files = try ASRAssetsFixture(); defer { files.remove() }
        let registry = LiveRecordingSessionRegistry()
        let factory = LiveRecordingFactory(registry: registry,admission: .init(policy: .init(),measurement: {
            .init(availableBytes: 2000,pressure: .normal)
        }))
        let id = UUID()
        var request = CaptureCoordinator.Request(id: id,startedAt: Date(),liveTranscription: true,language: "nl",privacyScope: .init(recordingID: id))
        request.liveEngine = .nemotron
        request.nemotronSelection = .init(profileID: "fixture",hardware: "fixture",sourceDirectory: files.source,
            identity: ASRAssetsFixture.identity(),language: .auto,chunkMs: 1120,sources: [.microphone],captureQualified: true)
        #expect(factory.prepare(request) == nil && registry.entry(recordingID: id) == nil)
    }
}
