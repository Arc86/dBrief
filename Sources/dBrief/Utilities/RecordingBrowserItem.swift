import Foundation

/// A recording surfaced in the transcript browser sidebar. Keyed by its audio
/// file `url` so selection stays stable across reloads (unlike a random UUID).
struct RecordingBrowserItem: Identifiable, Hashable, Codable, Sendable {
    var id: URL { url }
    let url: URL
    /// Base filename stem, e.g. `2026-06-04_2229_meeting-title`.
    let name: String
    let date: Date
    let size: Int64
    let duration: TimeInterval
    let hasTranscript: Bool
    let hasRichTranscript: Bool
    /// AI-generated title persisted to the metadata sidecar after post-processing.
    /// Preferred over the filename-derived title when present. See #71.
    var generatedTitle: String? = nil
    /// People known to have been in this meeting — the confirmed participants followed by the
    /// matched calendar event's attendees, de-duped. Restored from the metadata sidecar so the
    /// transcript viewer can offer them when assigning speakers.
    var meetingNames: [String] = []
    var libraryStatus: LibraryRecordingStatus? = nil

    /// Human title: the AI-generated title when present, else the meeting-title
    /// segment of the filename, else a date-based "Meeting …" label (dB2 look).
    var title: String {
        if let generated = generatedTitle?.trimmingCharacters(in: .whitespaces), !generated.isEmpty {
            return generated
        }
        return Self.titleFromFileName(name) ?? "Meeting \(Self.titleDateFormatter.string(from: date))"
    }

    /// The meeting title in a `YYYY-MM-DD_HHMM_title` file name, if it has one.
    static func titleFromFileName(_ name: String) -> String? {
        let parts = name.split(separator: "_", maxSplits: 2)
        guard parts.count == 3 else { return nil }
        let raw = String(parts[2]).replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, raw.lowercased() != "meeting" else { return nil }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    static func displayTitle(forAudioName name: String) -> String { titleFromFileName(name) ?? name }

    var formattedDuration: String {
        RecordingListPresentation.duration(duration)
    }

    /// Indexed rows include durable job state; legacy callers retain the
    /// transcript-existence fallback.
    var statusText: String {
        if let libraryStatus { return libraryStatus.title }
        return (hasRichTranscript || hasTranscript) ? "Done" : ""
    }

    private static let titleDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd jmm") // follows the 12/24-hour setting
        return f
    }()
}
