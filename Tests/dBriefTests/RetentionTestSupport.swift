import Foundation
@testable import dBrief

func writeRetentionOwner(for audio: URL, segments: [String] = [], markdown: URL? = nil) throws {
    let metadata = RecordingMetadataPayload(recordingID: UUID(), dateISO8601: "2026-01-01T00:00:00Z", durationSeconds: 1,
        meetingTitle: "Meeting", masterFileName: audio.lastPathComponent, segmentFileNames: segments, warnings: [])
    try JSONEncoder().encode(metadata).write(to: audio.deletingPathExtension().appendingPathExtension("json"))
    if let markdown {
        let insights = RecordingInsights(summary: "", actionItems: [], tags: [], sentiment: "neutral", markdownPath: markdown.path)
        try JSONEncoder().encode(insights).write(to: audio.deletingPathExtension().appendingPathExtension("insights.json"))
    }
}
