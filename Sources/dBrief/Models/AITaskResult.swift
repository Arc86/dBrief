import Foundation

struct AITaskResult: Sendable {
    var summary: String?
    var actionItems: [String]?
    var tags: [String]?
    var sentiment: String?
}
