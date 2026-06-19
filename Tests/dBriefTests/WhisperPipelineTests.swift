import Foundation
import dBriefWire
import Testing
@testable import dBrief

struct WhisperPipelineTests {
    @Test
    func normalizeMeetingTitleFallsBackAndSanitizes() {
        let empty = RecordingFinalizer.normalizeMeetingTitle("   ", fallback: nil)
        #expect(empty == "meeting")

        let sanitized = RecordingFinalizer.normalizeMeetingTitle("Q1 Review / Team", fallback: nil)
        #expect(sanitized == "Q1-Review-Team")
    }

    @Test
    @MainActor
    func totalTrackFileSizeSumsExistingTrackFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dbrief-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let systemURL = root.appendingPathComponent("a.system.caf")
        let micURL = root.appendingPathComponent("a.mic.caf")
        try Data(count: 1000).write(to: systemURL)
        try Data(count: 2500).write(to: micURL)

        // Both tracks present → sizes summed.
        #expect(RecordingManager.totalTrackFileSize(CapturedTracks(systemURL: systemURL, micURL: micURL)) == 3500)

        // A missing track contributes 0 rather than failing the whole read.
        let missing = root.appendingPathComponent("gone.caf")
        #expect(RecordingManager.totalTrackFileSize(CapturedTracks(systemURL: missing, micURL: micURL)) == 2500)

        // No tracks → 0.
        #expect(RecordingManager.totalTrackFileSize(nil) == 0)
    }

    @Test
    func baseFileNameUsesExpectedFormat() {
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: "2026-02-13T14:45:00Z")!
        let base = RecordingFinalizer.baseFileName(date: date, title: "team sync")
        #expect(base.hasPrefix("2026-02-13_"))
        #expect(base.contains("_team-sync"))
    }

    @Test
    func uniqueFileURLAddsDeterministicSuffix() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dbrief-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let first = root.appendingPathComponent("2026-02-13_1445_meeting.m4a")
        try Data("x".utf8).write(to: first)

        let unique = try RecordingFinalizer.uniqueFileURL(
            folder: root,
            baseName: "2026-02-13_1445_meeting",
            fileExtension: "m4a",
            fileManager: fm
        )
        #expect(unique.lastPathComponent == "2026-02-13_1445_meeting_2.m4a")
    }

    @Test
    func metadataPayloadRoundTripWithSegments() throws {
        let payload = RecordingMetadataPayload(
            dateISO8601: "2026-02-13T14:45:00Z",
            durationSeconds: 3900,
            meetingTitle: "team-sync",
            masterFileName: "2026-02-13_1445_team-sync.m4a",
            segmentFileNames: [
                "2026-02-13_1445_team-sync_part01.m4a",
                "2026-02-13_1445_team-sync_part02.m4a",
            ],
            warnings: ["Segmentation produced no output files."]
        )

        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(RecordingMetadataPayload.self, from: encoded)
        #expect(decoded == payload)
    }

    @Test
    func mergeSegmentTranscriptionsAppliesOffsets() {
        let pieces = [
            RecordingManager.SegmentTranscriptionPiece(
                offsetSeconds: 0,
                text: "first segment",
                segments: [
                    .init(start: 0, end: 3, text: "hello")
                ]
            ),
            RecordingManager.SegmentTranscriptionPiece(
                offsetSeconds: 1800,
                text: "second segment",
                segments: [
                    .init(start: 1, end: 4, text: "world")
                ]
            ),
        ]

        let merged = RecordingManager.mergeSegmentTranscriptions(pieces)
        #expect(merged.text == "first segment second segment")
        #expect(merged.segments.count == 2)
        #expect(merged.segments[0].start == 0)
        #expect(merged.segments[1].start == 1801)
        #expect(merged.segments[1].end == 1804)
    }

    @Test
    func flacContentTypeMappingsAreCorrect() {
        #expect(TranscriptionService.contentType(forExtension: "flac") == "audio/flac")
        #expect(TranscriptionService.contentType(forExtension: "m4a") == "audio/m4a")
        #expect(WebhookPayloadBuilder.contentType(for: URL(fileURLWithPath: "/tmp/a.flac")) == "audio/flac")
    }

    @Test
    func transcriptionResultRoundTripsToJSON() throws {
        let original = TranscriptionResult(
            text: "Hello world. This is a test.",
            segments: [
                .init(start: 0.0, end: 1.5, text: "Hello world."),
                .init(start: 1.5, end: 3.0, text: "This is a test."),
            ],
            language: "en",
            warnings: ["Low confidence on segment 2"]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptionResult.self, from: data)

        #expect(decoded.text == original.text)
        #expect(decoded.segments.count == 2)
        #expect(decoded.segments[0].start == 0.0)
        #expect(decoded.segments[0].end == 1.5)
        #expect(decoded.segments[0].text == "Hello world.")
        #expect(decoded.segments[1].start == 1.5)
        #expect(decoded.segments[1].text == "This is a test.")
        #expect(decoded.language == "en")
        #expect(decoded.warnings == ["Low confidence on segment 2"])
    }

    @Test
    func queueItemRoundTripsToJSON() throws {
        let original = QueueItem(
            transcribe: true,
            summary: true,
            actionItems: false,
            tags: true
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(QueueItem.self, from: data)

        #expect(decoded.transcribe == true)
        #expect(decoded.summary == true)
        #expect(decoded.actionItems == false)
        #expect(decoded.tags == true)
    }

    @Test
    @MainActor
    func importExistingAudioRelocatesIntoDatedFolderWithMetadata() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dbrief-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // A pre-encoded download sitting in a scratch directory (mirrors yt-dlp output).
        let downloadDir = root.appendingPathComponent("download", isDirectory: true)
        try fm.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        let source = downloadDir.appendingPathComponent("audio.m4a")
        try Data("fake-audio".utf8).write(to: source)

        let recordsFolder = root.appendingPathComponent("Recordings", isDirectory: true)
        let date = ISO8601DateFormatter().date(from: "2026-02-13T14:45:00Z")!
        let recording = Recording(date: date, fileURL: source, meetingTitleDraft: "My Video")

        let finalizer = RecordingFinalizer()
        let result = try await finalizer.importExistingAudio(
            sourceURL: source,
            recording: recording,
            baseFolder: recordsFolder,
            segmentationEnabled: false
        )

        // Master audio is relocated into the dated recordings folder with the standard name.
        #expect(result.masterAudioURL.path.contains("/2026/02/"))
        #expect(result.masterAudioURL.lastPathComponent.contains("My-Video"))
        #expect(result.masterAudioURL.pathExtension == "m4a")
        #expect(fm.fileExists(atPath: result.masterAudioURL.path))
        // The scratch source is consumed, not left behind.
        #expect(!fm.fileExists(atPath: source.path))
        // A metadata sidecar is written so discovery/history can read it.
        #expect(fm.fileExists(atPath: result.metadataURL.path))
        #expect(result.metadataURL.pathExtension == "json")
    }

    @Test
    func recordingDiscoveryFindsNestedFlacAndLegacyM4A() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dbrief-discovery-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("2026/02", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let flacURL = nested.appendingPathComponent("2026-02-13_1445_sync.m4a")
        let m4aURL = root.appendingPathComponent("legacy.m4a")
        let txtURL = nested.appendingPathComponent("ignore.txt")
        try Data("a".utf8).write(to: flacURL)
        try Data("b".utf8).write(to: m4aURL)
        try Data("c".utf8).write(to: txtURL)

        let found = RecordingDiscovery.discover(in: root, fileManager: fm)
        let names = Set(found.map { $0.url.lastPathComponent })
        #expect(names.contains("2026-02-13_1445_sync.m4a"))
        #expect(names.contains("legacy.m4a"))
        #expect(!names.contains("ignore.txt"))
    }

    @Test("mergeSegmentTranscriptions reconciles speakers, embeddings, and count")
    func mergeForwardsSpeakerData() {
        // Part 1: Speaker 1 at t=0..1. Part 2: Speaker 1 (same voiceprint) at t=0..1.
        let seg1 = TranscriptionResult.Segment(
            start: 0, end: 1, text: "hello",
            words: [.init(word: "hello", start: 0, end: 1, probability: 1, speaker: "Speaker 1")],
            speaker: "Speaker 1")
        let seg2 = TranscriptionResult.Segment(
            start: 0, end: 1, text: "again",
            words: [.init(word: "again", start: 0, end: 1, probability: 1, speaker: "Speaker 1")],
            speaker: "Speaker 1")
        let p1 = RecordingManager.SegmentTranscriptionPiece(
            offsetSeconds: 0, text: "hello", segments: [seg1], speakerEmbeddings: ["Speaker 1": [1, 0]])
        let p2 = RecordingManager.SegmentTranscriptionPiece(
            offsetSeconds: 100, text: "again", segments: [seg2], speakerEmbeddings: ["Speaker 1": [0.98, 0.2]])

        let merged = RecordingManager.mergeSegmentTranscriptions([p1, p2])

        // Speakers survive the merge and are unified to one global.
        #expect(merged.segments.count == 2)
        #expect(merged.segments[0].speaker == "Speaker 1")
        #expect(merged.segments[1].speaker == "Speaker 1")
        #expect(merged.segments[1].words?.first?.speaker == "Speaker 1")
        // Offset still applied.
        #expect(merged.segments[1].start == 100)
        // Embeddings + count forwarded.
        #expect(merged.speakerCount == 1)
        #expect(merged.speakerEmbeddings?["Speaker 1"]?.count == 2)
    }
}
