import Foundation

/// Successful workflow completion, distinct from recording time, user edits,
/// and mutable recovery-journal timestamps.
struct ProcessingCompletionStamp: Codable, Equatable, Sendable {
    let jobID: UUID
    let completedAt: Date
}
