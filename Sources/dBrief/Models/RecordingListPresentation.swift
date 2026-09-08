import Foundation

/// Presentation only: never changes the persisted filename or queue identity.
enum RecordingListPresentation {
    static func title(filenameStem: String, generatedTitle: String? = nil) -> String {
        if let generated = generatedTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !generated.isEmpty {
            return generated
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
