import Foundation
import dBriefWire

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
    /// Calendar event matched to this recording (best of `calendarCandidates`, or the user's
    /// pick from the override picker), used to pre-fill fields and AI context.
    /// Not persisted to disk — only valid for the current session's processing run.
    var calendarEvent: CalendarEvent?
    /// All calendar events that plausibly match this recording's span, ranked best-first by
    /// `CalendarMatcher`. Drives the override picker in the post-recording sheet.
    /// Not persisted to disk — session-only.
    var calendarCandidates: [CalendarEvent] = []
    /// The in-flight calendar lookup started at recording stop. The processing pipeline awaits
    /// it before reading `calendarEvent`, so a fast user clicking Process can't race the lookup
    /// (especially the Outlook network round-trip) and lose calendar title/participants/AI context.
    /// Session-only; never persisted.
    @ObservationIgnored var calendarLookupTask: Task<Void, Never>?
    var capturedTracks: CapturedTracks?
    /// Whether echo cancellation should be applied when finalizing this recording's
    /// mic track. Captured at recording *start* (user setting AND a real speaker→mic
    /// echo path existing) so the offline sidechain duck matches the route at the
    /// time of recording, even if the user later unplugs their headphones.
    /// Session-only; never persisted to disk.
    var echoSuppressionApplied: Bool = true
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

    var insightsSidecarURL: URL? {
        finalizedAudioURL?.deletingPathExtension()
            .appendingPathExtension("insights.json")
    }

    var chatSidecarURL: URL? {
        finalizedAudioURL?.deletingPathExtension()
            .appendingPathExtension("chat.json")
    }
}
