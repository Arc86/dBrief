import Foundation

/// A loaded driver exists before its serial session prepares. Both that session
/// and the late-preparation owner join this single actual shutdown, including
/// cancellation before the session factory is entered.
actor LiveDiarizationDriverOwnership: LiveDiarizationDriving {
    private var driver: (any LiveDiarizationDriving)?
    private var closing = false
    private var shutdownTask: Task<Void, Never>?
    init(_ driver: any LiveDiarizationDriving) { self.driver = driver }
    func append(_ samples: [Float]) async throws -> [LiveDiarizationChunk] {
        guard !closing, let driver else { throw LiveDiarizationNativeError.inactive }; return try await driver.append(samples)
    }
    func finish() async throws -> [LiveDiarizationChunk] {
        guard !closing, let driver else { throw LiveDiarizationNativeError.inactive }; return try await driver.finish()
    }
    func shutdown() async {
        let task: Task<Void, Never>
        if let existing = shutdownTask { task = existing }
        else {
            guard let driver else { return }; closing = true
            task = Task { await driver.shutdown(); withExtendedLifetime(driver) {} }; shutdownTask = task
        }
        await task.value; driver = nil; shutdownTask = nil
    }
}
