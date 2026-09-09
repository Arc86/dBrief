import Foundation
import dBriefWire

/// The router installs a request-owned sink. Nested actors inherit it without
/// consulting the global progress channel or a mutable "current request" ID.
enum MLPrivacyTrace {
    @TaskLocal static var sink: (@Sendable (MLPrivacyEvent) -> Void)?
    struct Token: Sendable {
        let id: UUID
        let sink: @Sendable (MLPrivacyEvent) -> Void
    }
    static func begin(_ operation: MLPrivacyOperation) -> Token? {
        guard let sink else { return nil }
        let token = Token(id: UUID(), sink: sink)
        sink(.started(id: token.id, operation: operation))
        return token
    }
    static func finish(_ token: Token?, outcome: MLPrivacyOutcome) {
        guard let token else { return }
        token.sink(.finished(id: token.id, outcome: outcome))
    }
    static func perform<T>(_ operation: MLPrivacyOperation,
                           isolation: isolated (any Actor)? = #isolation,
                           body: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let token = begin(operation)
        do {
            let result = try await body()
            finish(token, outcome: .succeeded)
            return result
        } catch {
            finish(token, outcome: outcome(for: error))
            throw error
        }
    }
    static func outcome(for error: Error) -> MLPrivacyOutcome {
        error is CancellationError || (error as? URLError)?.code == .cancelled ? .cancelled : .failed
    }
}
