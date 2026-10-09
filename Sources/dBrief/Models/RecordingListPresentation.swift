import Foundation

/// Presentation only: never changes the persisted filename or queue identity.
enum RecordingListPresentation {
    static func title(filenameStem: String, generatedTitle: String? = nil) -> String {
        if let generated = generatedTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !generated.isEmpty {
            return withoutLeadingDate(generated)
        }
        let parts = filenameStem.split(separator: "_", maxSplits: 2)
        // Strip only our YYYY-MM-DD_HHMM_ prefix, not arbitrary imported names.
        if parts.count == 3,
           parts[0].range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
           parts[1].range(of: #"^\d{4}$"#, options: .regularExpression) != nil {
            return String(parts[2]).replacingOccurrences(of: "-", with: " ")
        }
        return filenameStem
    }

    /// Lists already show each recording's date, so a title that opens with one
    /// ("2026-10-08 - Team sync", often from a calendar event) drops it.
    static func withoutLeadingDate(_ title: String) -> String {
        guard let range = title.range(of: #"^\d{4}-\d{2}-\d{2}[\s\-–—:|·_]*"#, options: .regularExpression) else {
            return title
        }
        let rest = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? title : rest
    }

    /// Row duration: empty when unknown or under a second, h:mm:ss from an hour.
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 1 else { return "" }
        return seconds.formattedDuration
    }

    /// The Queue & Recovery section only earns its space when it has something
    /// to show or do: queued or failed work, a paused queue, or a load error.
    static func showsQueueSection(pending: Int, recovery: Int, reprocessing: Int, paused: Bool, hasError: Bool) -> Bool {
        pending + recovery + reprocessing > 0 || paused || hasError
    }

    static func queueSummary(pending: Int, recovery: Int, paused: Bool, processing: Bool, hasError: Bool) -> String {
        var parts = [String]()
        if paused { parts.append("Paused") }
        if processing { parts.append("Processing") }
        if pending > 0 { parts.append("\(pending) queued") }
        if recovery > 0 { parts.append("\(recovery) need attention") }
        if hasError { parts.append("Couldn’t refresh") }
        return parts.isEmpty ? "No pending work" : parts.joined(separator: " · ")
    }
}
