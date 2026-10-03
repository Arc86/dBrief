import Foundation

/// The app freezes the future path synchronously and retains deletion authority.
/// The helper only reopens that path read-only; no second native-process copy.
package final class LiveVADAssetPreparation: @unchecked Sendable {
    private let lock = NSLock()
    private var owner: UUID?
    private var used = false
    private var retired = false
    private var unavailable = false
    private var assets: LiveVADModelAssets?
    private let source: LiveVADConfiguration
    private let budget: LiveASRStagingBudget
    private let staging: URL?
    private let probe: LiveVADModelAssets.Probe?
    package let configuration: LiveVADConfiguration

    package convenience init(source: LiveVADConfiguration) throws {
        try self.init(source: source,budget: .shared,testingStagingDirectory: nil,probe: nil)
    }
    package init(source: LiveVADConfiguration,budget: LiveASRStagingBudget,testingStagingDirectory: URL? = nil,
                 probe: LiveVADModelAssets.Probe? = nil) throws {
        self.source = source; self.budget = budget; staging = testingStagingDirectory; self.probe = probe
        configuration = try LiveVADModelAssets.futureConfiguration(source: source,testingStagingDirectory: testingStagingDirectory)
    }
    package func bind(to value: UUID) -> Bool {
        lock.withLock {
            guard !used, !retired, owner == nil || owner == value else { return false }
            owner = value; return true
        }
    }
    package func prepare(owner value: UUID) async throws {
        let accepted = lock.withLock {
            guard owner == value, !used, !retired else { return false }
            used = true; return true
        }
        guard accepted else { throw LiveVADAssetError.invalidAsset }
        let work = Task.detached { [self] in
            let result = try await LiveVADModelAssets.prepare(source,testingStagingDirectory: staging,probe: probe,
                destination: configuration,budget: budget)
            try Task.checkCancellation()
            let accepted = lock.withLock {
                guard owner == value, !retired else { return false }
                assets = result; return true
            }
            guard accepted else { throw CancellationError() }
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    package func markUnavailable(owner value: UUID) {
        lock.withLock { if owner == value, !retired, assets == nil { unavailable = true } }
    }
    package func validate(owner value: UUID) throws {
        let result = lock.withLock { () -> (Bool,LiveVADModelAssets?) in
            guard owner == value, !retired, used else { return (false,nil) }
            return (unavailable,assets)
        }
        if result.0 { return }
        guard let assets = result.1 else { throw LiveVADAssetError.invalidAsset }
        _ = try assets.modelDirectory
    }
    @discardableResult package func retire(owner value: UUID) -> Task<Void,Never>? {
        let result = lock.withLock { () -> LiveVADModelAssets? in
            guard owner == value else { return nil }
            retired = true; let result = assets; assets = nil; return result
        }
        guard let result else { return nil }
        // Destruction/copy cleanup remains independent of capture's terminal task.
        return Task.detached { withExtendedLifetime(result) {} }
    }
}
