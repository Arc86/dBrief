import Foundation
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

        let first = root.appendingPathComponent("2026-02-13_1445_meeting.flac")
        try Data("x".utf8).write(to: first)

        let unique = try RecordingFinalizer.uniqueFileURL(
            folder: root,
            baseName: "2026-02-13_1445_meeting",
            fileExtension: "flac",
            fileManager: fm
        )
        #expect(unique.lastPathComponent == "2026-02-13_1445_meeting_2.flac")
    }

    @Test
    func metadataPayloadRoundTripWithSegments() throws {
        let payload = RecordingMetadataPayload(
            dateISO8601: "2026-02-13T14:45:00Z",
            durationSeconds: 3900,
            meetingTitle: "team-sync",
            masterFileName: "2026-02-13_1445_team-sync.flac",
            segmentFileNames: [
                "2026-02-13_1445_team-sync_part01.flac",
                "2026-02-13_1445_team-sync_part02.flac",
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
    func recordingDiscoveryFindsNestedFlacAndLegacyM4A() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dbrief-discovery-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("2026/02", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let flacURL = nested.appendingPathComponent("2026-02-13_1445_sync.flac")
        let m4aURL = root.appendingPathComponent("legacy.m4a")
        let txtURL = nested.appendingPathComponent("ignore.txt")
        try Data("a".utf8).write(to: flacURL)
        try Data("b".utf8).write(to: m4aURL)
        try Data("c".utf8).write(to: txtURL)

        let found = RecordingDiscovery.discover(in: root, fileManager: fm)
        let names = Set(found.map { $0.url.lastPathComponent })
        #expect(names.contains("2026-02-13_1445_sync.flac"))
        #expect(names.contains("legacy.m4a"))
        #expect(!names.contains("ignore.txt"))
    }
}
