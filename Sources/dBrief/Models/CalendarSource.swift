import Foundation

enum CalendarSource: String, Codable, CaseIterable, Sendable {
    case disabled
    case iCal
    case outlook
}
