import Foundation

/// A recording surfaced in the transcript browser sidebar. Keyed by its audio
/// file `url` so selection stays stable across reloads (unlike a random UUID).
struct RecordingBrowserItem: Identifiable, Hashable, Sendable {
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

    /// Human title: the AI-generated title when present, else the meeting-title
    /// segment of the filename, else a date-based "Meeting …" label (dB2 look).
    var title: String {
        if let generated = generatedTitle?.trimmingCharacters(in: .whitespaces), !generated.isEmpty {
            return generated
        }
        let parts = name.split(separator: "_", maxSplits: 2)
        if parts.count == 3 {
            let raw = String(parts[2]).replacingOccurrences(of: "-", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if !raw.isEmpty, raw.lowercased() != "meeting" {
                return raw.prefix(1).uppercased() + raw.dropFirst()
            }
        }
        return "Meeting \(Self.titleDateFormatter.string(from: date))"
    }

    var formattedDuration: String {
        guard duration > 0 else { return "" }
        let total = Int(duration)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// We have no persisted "Failed" state on disk, so status is derived from
    /// whether a transcript exists.
    var statusText: String {
        (hasRichTranscript || hasTranscript) ? "Done" : ""
    }

    private static let titleDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()
}

/// Scans the recordings folder and builds `RecordingBrowserItem`s. Wraps
/// `RecordingDiscovery` and the per-file metadata/sidecar checks so the
/// transcript browser has a single source of truth for the recordings list.
enum RecordingBrowserStore {
    private static let segmentSuffix = try! NSRegularExpression(pattern: "_part\\d+$")

    static func load(in folder: URL, limit: Int? = nil) -> [RecordingBrowserItem] {
        let all = RecordingDiscovery.discover(in: folder).filter { entry in
            let stem = entry.url.deletingPathExtension().lastPathComponent
            let range = NSRange(stem.startIndex..., in: stem)
            return segmentSuffix.firstMatch(in: stem, range: range) == nil
        }
        let limited = limit.map { Array(all.prefix($0)) } ?? all
        return limited.map { entry in
            let base = entry.url.deletingPathExtension()
            let hasTranscript = FileManager.default.fileExists(
                atPath: base.appendingPathExtension("transcript.json").path)
            let hasRich = FileManager.default.fileExists(
                atPath: base.appendingPathExtension("richtranscript.json").path)

            var duration: TimeInterval = 0
            var generatedTitle: String?
            let metaURL = base.appendingPathExtension("json")
            if let data = try? Data(contentsOf: metaURL),
               let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Key must match RecordingMetadataPayload's encoded field name.
                if let d = meta["durationSeconds"] as? TimeInterval {
                    duration = d
                }
                generatedTitle = meta["generatedTitle"] as? String
            }

            return RecordingBrowserItem(
                url: entry.url,
                name: base.lastPathComponent,
                date: entry.createdAt,
                size: entry.size,
                duration: duration,
                hasTranscript: hasTranscript,
                hasRichTranscript: hasRich,
                generatedTitle: generatedTitle
            )
        }
    }
}
