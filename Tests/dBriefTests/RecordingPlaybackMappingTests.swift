import Foundation
import Testing
@testable import dBrief

@Suite struct RecordingPlaybackMappingTests {
    @Test func copiedTrackHasIdentityCoordinatesOnlyForItsActualRole() {
        let frames = LiveAudioFrameRange(startFrame: 300, frameCount: 100, sampleRate: 16000)
        let mapping = RecordingPlaybackMapping.rawTrackCopy(.system)
        #expect(mapping.masterFrames(for: .system, savedTrack: frames) == frames)
        #expect(mapping.masterFrames(for: .mic, savedTrack: frames) == nil)
        for range in [LiveAudioFrameRange(startFrame: -1, frameCount: 100, sampleRate: 16000),
                      .init(startFrame: Int64.max, frameCount: 1, sampleRate: 16000),
                      .init(startFrame: 0, frameCount: 100, sampleRate: .infinity)] {
            #expect(mapping.masterFrames(for: .system, savedTrack: range) == nil)
        }
    }

    @Test func encodedOutputListsActualInputsButCannotClaimCalibratedMasterRanges() {
        let mapping = RecordingPlaybackMapping.encodedAAC(CapturedTracks(systemURL: nil, micURL: URL(fileURLWithPath: "/private/mic.caf")))
        #expect(mapping.sourceRoles == [.mic])
        #expect(mapping.masterFrames(for: .mic, savedTrack: .init(startFrame: 0, frameCount: 100, sampleRate: 16000)) == nil)
    }

    @Test func playbackMappingRoundTripsAndLegacyMetadataRemainsUnknown() throws {
        let legacy = RecordingMetadataPayload(dateISO8601: "2026-10-02", durationSeconds: 1, meetingTitle: "Fixture",
            masterFileName: "master.m4a", segmentFileNames: [], warnings: [])
        let oldBytes = try JSONEncoder().encode(legacy)
        #expect(try JSONDecoder().decode(RecordingMetadataPayload.self, from: oldBytes).playbackMapping == nil)
        let mapped = RecordingMetadataPayload(dateISO8601: "2026-10-02", durationSeconds: 1, meetingTitle: "Fixture",
            masterFileName: "master.m4a", segmentFileNames: [], warnings: [], playbackMapping: .rawTrackCopy(.system))
        let reloaded = try JSONDecoder().decode(RecordingMetadataPayload.self, from: JSONEncoder().encode(mapped))
        #expect(reloaded.playbackMapping == .rawTrackCopy(.system))
    }

    @Test @MainActor func fallbackFinalizationPersistsTheTrackActuallyCopied() async throws {
        let files = FileManager.default, root = files.temporaryDirectory.appendingPathComponent("mapping-finalizer-\(UUID())")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let mic = root.appendingPathComponent("mic.caf"), system = root.appendingPathComponent("system.caf")
        try Data(repeating: 1, count: 128).write(to: mic)
        let sourceBytes = Data(repeating: 2, count: 5000)
        try sourceBytes.write(to: system)
        // A missing ffmpeg takes the unchanged byte-for-byte fallback. Resolution
        // is injected so this test does not depend on the developer's PATH.
        let recording = Recording(date: Date(), fileURL: system, meetingTitleDraft: "Mapping fixture")
        recording.duration = 0.1
        let result = try await RecordingFinalizer(resolveFFmpeg: { nil }).finalize(tracks: .init(systemURL: system, micURL: mic),
            snapshot: .init(recording: recording), baseFolder: root.appendingPathComponent("Recordings"), segmentationEnabled: false)
        #expect(result.playbackMapping == .rawTrackCopy(.system))
        #expect(try Data(contentsOf: result.masterAudioURL) == sourceBytes)
        let metadata = try JSONDecoder().decode(RecordingMetadataPayload.self, from: Data(contentsOf: result.metadataURL))
        #expect(metadata.playbackMapping == result.playbackMapping)
        #expect(!files.fileExists(atPath: system.path))
    }

    @Test func fallbackReturnsTheSelectedRole() async throws {
        let files = FileManager.default, root = files.temporaryDirectory.appendingPathComponent("mapping-role-\(UUID())")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let mic = root.appendingPathComponent("mic.caf"), system = root.appendingPathComponent("system.caf")
        try Data(repeating: 1, count: 128).write(to: mic)
        try Data(repeating: 2, count: 5000).write(to: system)
        #expect(try await RecordingFinalizer().fallbackPromoteTrack(tracks: .init(systemURL: system, micURL: mic),
            targetURL: root.appendingPathComponent("master.m4a")) == .system)
    }

    @Test func metadataEditsPreservePlaybackMapping() async throws {
        let files = FileManager.default, root = files.temporaryDirectory.appendingPathComponent("mapping-edit-\(UUID())")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let audio = root.appendingPathComponent("master.m4a"), metadata = root.appendingPathComponent("master.json")
        let payload = RecordingMetadataPayload(dateISO8601: "2026-10-02", durationSeconds: 1, meetingTitle: "Fixture",
            masterFileName: "master.m4a", segmentFileNames: [], warnings: [], playbackMapping: .rawTrackCopy(.mic))
        let store = RecordingMetadataStore()
        try await store.create(payload, at: metadata)
        try await store.update(.generatedTitle("Updated"), audioURL: audio)
        let updated = try #require(await store.load(audioURL: audio))
        #expect(updated.generatedTitle == "Updated" && updated.playbackMapping == .rawTrackCopy(.mic))
    }
}
