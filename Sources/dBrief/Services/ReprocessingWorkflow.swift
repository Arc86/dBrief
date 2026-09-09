import Foundation

/// Runs only the requested replacement stages. All side effects, including
/// checkpoint persistence and publication, stay behind the owning adapters.
enum ReprocessingWorkflow {
    enum Stage: String, Codable, Sendable, Hashable {
        case transcription, speakers, analysis
    }
    enum Result: Sendable, Equatable { case completed, held }

    static func run(
        stages: [Stage], completed: Set<Stage>,
        execute: @Sendable (Stage) async throws -> Result,
        checkpoint: @Sendable (Stage) async throws -> Void,
        publish: @Sendable () async throws -> Void,
        validate: @Sendable () async throws -> Void = {}
    ) async throws -> Result {
        for stage in stages where !completed.contains(stage) {
            try Task.checkCancellation()
            try await validate()
            let result = try await execute(stage)
            try Task.checkCancellation()
            try await validate()
            guard result == .completed else { return .held }
            try await checkpoint(stage)
        }
        try Task.checkCancellation()
        try await validate()
        try await publish()
        return .completed
    }
}
