import Foundation

enum CalendarSource: String, Codable, CaseIterable, Sendable {
    case disabled
    case iCal
    case outlook
    /// Meetings fetched through the user's Claude CLI connector, cached
    /// locally by `CalendarCLIService`. Independent of the AI-analysis engine.
    case claudeCLI
}
