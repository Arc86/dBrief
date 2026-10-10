import Foundation

extension TimeInterval {
    /// `m:ss`, or `h:mm:ss` from an hour. Negative and non-finite values read as `0:00`.
    var formattedDuration: String {
        let total = isFinite ? Int(Swift.min(Swift.max(0, self), Double(Int.max) / 2)) : 0
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
