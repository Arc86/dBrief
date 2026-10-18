import Foundation

/// Read-only presentation data. An empty history never establishes where earlier
/// processing ran. Multiple locations can survive an interrupted finalization.
struct PrivacyReceiptSnapshot: Equatable, Sendable {
    var attempts: [PrivacyAttempt] = []
    var hasReceipt = false
    var hasGaps = false
    var hasUnreadableReceipt = false
    var omittedAttempts = 0

    var heading: String {
        if hasUnreadableReceipt || hasGaps { return String(localized: "Partial evidence") }
        if !hasReceipt || attempts.isEmpty { return String(localized: "Evidence unavailable") }
        return String(localized: "Recorded attempts")
    }
}
