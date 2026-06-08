import Foundation

@MainActor
@Observable
final class Recording: Identifiable {
    let id: UUID
    let date: Date
    var fileURL: URL
    var duration: TimeInterval
    var fileSize: Int64
    var transcription: TranscriptionResult?
    var summary: String?
    var actionItems: [String]?
    var tags: [String]?
    var sentiment: String?
    var generatedTitle: String?
    var associatedApp: String?
    var obsidianFolderRelativePath: String?
    var meetingTitleDraft: String
    /// Participant names entered by the user, mapped to diarization speakers in order of first appearance.
    var participants: [String] = []
    /// Calendar event matched at record-start time, used to pre-fill fields and AI context.
    /// Not persisted to disk — only valid for the current session's processing run.
    var calendarEvent: CalendarEvent?
    var capturedTracks: CapturedTracks?
    /// Pre-encoded audio (e.g. a YouTube/yt-dlp download) awaiting relocation into the
    /// recordings folder during finalization. Session-only; never persisted to disk.
    var importSourceURL: URL?
    var finalizedAudioURL: URL?
    var segmentAudioURLs: [URL]
    var metadataURL: URL?
    var transcriptURL: URL?
    var finalizationWarnings: [String]
    var richTranscript: RichTranscript?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        fileURL: URL,
        duration: TimeInterval = 0,
        fileSize: Int64 = 0,
        associatedApp: String? = nil,
        meetingTitleDraft: String = "meeting",
        finalizedAudioURL: URL? = nil,
        segmentAudioURLs: [URL] = [],
        metadataURL: URL? = nil,
        transcriptURL: URL? = nil,
        finalizationWarnings: [String] = []
    ) {
        self.id = id
        self.date = date
        self.fileURL = fileURL
        self.duration = duration
        self.fileSize = fileSize
        self.associatedApp = associatedApp
        self.meetingTitleDraft = meetingTitleDraft
        self.finalizedAudioURL = finalizedAudioURL
        self.segmentAudioURLs = segmentAudioURLs
        self.metadataURL = metadataURL
        self.transcriptURL = transcriptURL
        self.finalizationWarnings = finalizationWarnings
    }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var fileName: String {
        fileURL.deletingPathExtension().lastPathComponent
    }

    var transcriptSidecarURL: URL? {
        finalizedAudioURL?.deletingPathExtension()
            .appendingPathExtension("richtranscript.json")
    }
}
