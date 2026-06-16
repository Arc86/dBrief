import Foundation
import Testing
@testable import dBrief

/// Covers the title-sync fix (#71): the AI-generated title is persisted to the
/// metadata `.json` sidecar and preferred by the transcript browser over the
/// (draft) filename-derived title.
struct TitleSyncTests {
    // MARK: - Metadata sidecar

    @Test
    func metadataPayloadRoundTripPreservesGeneratedTitle() throws {
        let payload = RecordingMetadataPayload(
            dateISO8601: "2026-06-16T10:00:00Z",
            durationSeconds: 600,
            meetingTitle: "meeting",
            masterFileName: "2026-06-16_1000_meeting.m4a",
            segmentFileNames: [],
            warnings: [],
            generatedTitle: "Q3 Roadmap Planning"
        )

        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(RecordingMetadataPayload.self, from: encoded)
        #expect(decoded == payload)
        #expect(decoded.generatedTitle == "Q3 Roadmap Planning")
    }

    @Test
    func metadataPayloadDecodesLegacyFileWithoutGeneratedTitle() throws {
        // A sidecar written before this field existed must still decode (title nil).
        let legacy = """
        {
          "dateISO8601": "2026-06-15T20:34:55Z",
          "durationSeconds": 28.8,
          "masterFileName": "2026-06-15_2234_Selah-vrij!-Studiedag-Kineo_2.m4a",
          "meetingTitle": "Selah-vrij!-Studiedag-Kineo",
          "segmentFileNames": [],
          "warnings": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(RecordingMetadataPayload.self, from: legacy)
        #expect(decoded.generatedTitle == nil)
        #expect(decoded.meetingTitle == "Selah-vrij!-Studiedag-Kineo")
    }

    @Test
    func generatedTitleOmittedFromJSONWhenNil() throws {
        let payload = RecordingMetadataPayload(
            dateISO8601: "2026-06-16T10:00:00Z",
            durationSeconds: 600,
            meetingTitle: "meeting",
            masterFileName: "2026-06-16_1000_meeting.m4a",
            segmentFileNames: [],
            warnings: []
        )
        let json = String(data: try JSONEncoder().encode(payload), encoding: .utf8)!
        #expect(!json.contains("generatedTitle"))
    }

    /// The transcript browser and menu-bar history read duration from the metadata
    /// sidecar by dictionary key. That key must match the payload's encoded field
    /// name (`durationSeconds`) — a mismatch silently zeros every duration.
    @Test
    func metadataSidecarEncodesDurationUnderReaderKey() throws {
        let payload = RecordingMetadataPayload(
            dateISO8601: "2026-06-16T10:00:00Z",
            durationSeconds: 28.8,
            meetingTitle: "meeting",
            masterFileName: "2026-06-16_1000_meeting.m4a",
            segmentFileNames: [],
            warnings: []
        )

        // Parse exactly as RecordingBrowserStore / RecordingHistoryView do.
        let data = try JSONEncoder().encode(payload)
        let meta = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(meta["durationSeconds"] as? TimeInterval == 28.8)
        #expect(meta["duration"] == nil) // the old, buggy reader key must not exist
    }

    // MARK: - Browser title preference

    private func makeItem(name: String, generatedTitle: String?) -> RecordingBrowserItem {
        RecordingBrowserItem(
            url: URL(fileURLWithPath: "/tmp/\(name).m4a"),
            name: name,
            date: Date(timeIntervalSince1970: 0),
            size: 0,
            duration: 0,
            hasTranscript: false,
            hasRichTranscript: false,
            generatedTitle: generatedTitle
        )
    }

    @Test
    func titlePrefersGeneratedTitleOverFilename() {
        let item = makeItem(name: "2026-06-16_1000_old-draft-name", generatedTitle: "Customer Onboarding Sync")
        #expect(item.title == "Customer Onboarding Sync")
    }

    @Test
    func titleFallsBackToFilenameWhenGeneratedTitleNil() {
        let item = makeItem(name: "2026-06-16_1000_old-draft-name", generatedTitle: nil)
        #expect(item.title == "Old draft name")
    }

    @Test
    func titleFallsBackToFilenameWhenGeneratedTitleEmpty() {
        let item = makeItem(name: "2026-06-16_1000_old-draft-name", generatedTitle: "   ")
        #expect(item.title == "Old draft name")
    }
}
