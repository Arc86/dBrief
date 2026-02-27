import Foundation

struct QueueItem: Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    var transcribe: Bool
    var summary: Bool
    var actionItems: Bool
    var tags: Bool
}
