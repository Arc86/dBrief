import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Model download coordination") @MainActor
struct ModelDownloadCoordinatorTests {
    private func coordinator(_ backend: DownloadBackend, streams: DownloadStreams) -> ModelDownloadCoordinator {
        .init(dependencies: .init(stateStream: { _ in streams.subscribe() }, download: { try await backend.download($0) },
            purge: { try await backend.purge($0) }, isCached: { await backend.isCached($0) },
            availableWhisperModels: { ["tiny", "small"] }))
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
    }

    @Test func progressCompletesAndReleasesObserverBeforeLateEvents() async throws {
        let backend = DownloadBackend(), streams = DownloadStreams()
        let owner = coordinator(backend, streams: streams)
        owner.start(.whisper(.default))
        #expect(owner.phases[.whisper] == .downloading(progress: nil, label: "Starting…"))
        try await waitUntil { await backend.requests.count == 1 }
        streams.emit(.downloading(progress: 0.4, stage: .whisperModel))
        try await waitUntil { owner.phases[.whisper] == .downloading(progress: 0.4, label: "Downloading…") }
        await backend.finish(0)
        try await waitUntil { owner.phases[.whisper] == .idle && streams.activeCount == 0 }
        streams.emit(.downloading(progress: 0.9, stage: .whisperModel))
        #expect(owner.phases[.whisper] == .idle)
    }

    @Test func failureIsVisibleAndRetrySurvivesOldAttemptCompletion() async throws {
        let backend = DownloadBackend(), streams = DownloadStreams()
        let owner = coordinator(backend, streams: streams)
        let original = owner.start(.gemma)
        try await waitUntil { await backend.requests.count == 1 }
        owner.start(.gemma)
        try await waitUntil { streams.activeCount == 0 }
        streams.emit(.downloading(progress: 0.9, stage: .llmModel))
        #expect(owner.phases[.gemma] == .downloading(progress: nil, label: "Starting…"))
        #expect(await backend.requests.count == 1)
        await backend.finish(0, failure: true) // Old backend deliberately ignores cancellation.
        await original.value
        try await waitUntil { await backend.requests.count == 2 }
        streams.emit(.downloading(progress: 0.6, stage: .llmModel))
        try await waitUntil { owner.phases[.gemma] == .downloading(progress: 0.6, label: "Downloading…") }
        #expect(streams.activeCount == 1)
        await backend.finish(1, failure: true)
        try await waitUntil { owner.phases[.gemma] == .failed("Synthetic failure") }
        #expect(streams.activeCount == 0)
        owner.start(.gemma)
        try await waitUntil { await backend.requests.count == 3 }
        await backend.finish(2)
        try await waitUntil { owner.phases[.gemma] == .idle }
    }

    @Test func cancelAllResetsRowsAndLateBackendsCannotRestoreThem() async throws {
        let backend = DownloadBackend(), streams = DownloadStreams()
        let owner = coordinator(backend, streams: streams)
        let operations = [owner.start(.whisper(.default)), owner.start(.parakeet(variant: "v3")), owner.start(.gemma)]
        try await waitUntil { await backend.requests.count == 3 }
        owner.cancelAll()
        #expect(LocalModelKind.allCases.allSatisfy { owner.phases[$0] == .idle })
        try await waitUntil { streams.activeCount == 0 }
        for index in 0..<3 { await backend.finish(index, failure: true) }
        for operation in operations { await operation.value }
        #expect(LocalModelKind.allCases.allSatisfy { owner.phases[$0] == .idle })
    }

    @Test func cancelDuringPurgeNeverStartsDownloadEvenWhenPurgeIgnoresCancellation() async throws {
        let backend = DownloadBackend(holdPurge: true), streams = DownloadStreams()
        let owner = coordinator(backend, streams: streams)
        let operation = owner.start(.gemma, forceRedownload: true)
        try await waitUntil { await backend.purges.count == 1 }
        owner.cancel(.gemma)
        await backend.releasePurge()
        await operation.value
        #expect(await backend.requests.isEmpty)
        #expect(owner.phases[.gemma] == .idle)
        #expect(streams.activeCount == 0)
    }

    @Test func failedPurgeRemainsBestEffortAndRequestSelectionIsForwarded() async throws {
        let backend = DownloadBackend(failPurge: true), streams = DownloadStreams()
        let owner = coordinator(backend, streams: streams)
        let request = ModelDownloadCoordinator.Request.whisper(.init(modelName: "selected", language: "nl", diarizationEnabled: false))
        #expect(await owner.isCached(request))
        #expect(await backend.cacheRequests == [request])
        #expect(await owner.availableWhisperModels() == ["tiny", "small"])
        owner.start(request, forceRedownload: true)
        try await waitUntil { await backend.requests == [request] }
        #expect(await backend.purges == [.whisper])
        await backend.finish(0)
        try await waitUntil { owner.phases[.whisper] == .idle }
        await #expect(throws: DownloadTestError.self) { try await owner.purge(.parakeet) }
        #expect(await backend.purges == [.whisper, .parakeet])
    }

    @Test func sharedProgressOnlyUpdatesItsMatchingModelRow() async throws {
        let backend = DownloadBackend(), streams = DownloadStreams()
        let owner = coordinator(backend, streams: streams)
        owner.start(.whisper(.default))
        owner.start(.gemma)
        try await waitUntil { await backend.requests.count == 2 }
        streams.emit(.downloading(progress: nil, stage: .whisperModelLoading))
        try await waitUntil { owner.phases[.whisper] == .downloading(progress: nil, label: "Loading…") }
        #expect(owner.phases[.gemma] == .downloading(progress: nil, label: "Starting…"))
        streams.emit(.downloading(progress: 0.5, stage: .llmModel))
        try await waitUntil { owner.phases[.gemma] == .downloading(progress: 0.5, label: "Downloading…") }
        #expect(owner.phases[.whisper] == .downloading(progress: nil, label: "Loading…"))
        owner.cancelAll()
        await backend.finish(0)
        await backend.finish(1)
    }
    @Test func immediateCancellationDoesNotDispatchBackendWork() async throws {
        let backend = DownloadBackend(), streams = DownloadStreams()
        let owner = coordinator(backend, streams: streams)
        let operation = owner.start(.gemma, forceRedownload: true)
        owner.cancel(.gemma)
        await operation.value
        #expect(await backend.requests.isEmpty)
        #expect(await backend.purges.isEmpty)
        #expect(owner.phases[.gemma] == .idle)
        try await waitUntil { streams.activeCount == 0 }
    }

    @Test func releasingCoordinatorCancelsObserversWithoutRetainingOwnerAcrossAwait() async throws {
        let backend = DownloadBackend(), streams = DownloadStreams()
        var owner: ModelDownloadCoordinator? = coordinator(backend, streams: streams)
        weak var weakOwner = owner
        let operation = try #require(owner).start(.gemma)
        try await waitUntil { await backend.requests.count == 1 }
        streams.emit(.downloading(progress: 0.4, stage: .llmModel))
        try await waitUntil { owner?.phases[.gemma] == .downloading(progress: 0.4, label: "Downloading…") }
        owner = nil
        #expect(weakOwner == nil)
        try await waitUntil { streams.activeCount == 0 }
        await backend.finish(0)
        await operation.value
    }

    @Test func cancelledReplacementRetainsPredecessorUntilNewestAttemptCanSubscribe() async throws {
        let backend = DownloadBackend(), streams = DownloadStreams()
        let owner = coordinator(backend, streams: streams)
        let original = owner.start(.whisper(.default))
        try await waitUntil { await backend.requests.count == 1 }
        owner.cancel(.whisper)
        let skipped = owner.start(.whisper(.init(modelName: "skipped", language: nil, diarizationEnabled: false)))
        let newestRequest = ModelDownloadCoordinator.Request.whisper(.init(modelName: "newest", language: nil, diarizationEnabled: false))
        let newest = owner.start(newestRequest)
        try await waitUntil { streams.activeCount == 0 }
        streams.emit(.downloading(progress: 0.8, stage: .whisperModel))
        #expect(owner.phases[.whisper] == .downloading(progress: nil, label: "Starting…"))
        #expect(await backend.requests.count == 1)
        await backend.finish(0)
        await original.value
        await skipped.value
        try await waitUntil { await backend.requests.count == 2 }
        #expect(await backend.requests.last == newestRequest)
        streams.emit(.downloading(progress: 0.2, stage: .whisperModel))
        try await waitUntil { owner.phases[.whisper] == .downloading(progress: 0.2, label: "Downloading…") }
        await backend.finish(1)
        await newest.value
        #expect(owner.phases[.whisper] == .idle)
        #expect(streams.activeCount == 0)
    }

}

private enum DownloadTestError: Error, LocalizedError {
    case failure
    var errorDescription: String? { "Synthetic failure" }
}

private actor DownloadBackend {
    private(set) var requests: [ModelDownloadCoordinator.Request] = []
    private(set) var cacheRequests: [ModelDownloadCoordinator.Request] = []
    private(set) var purges: [LocalModelKind] = []
    private(set) var finished: Set<Int> = []
    private(set) var purgeReturned = false
    private var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var purgeWaiter: CheckedContinuation<Void, Never>?
    let holdPurge: Bool
    let failPurge: Bool
    init(holdPurge: Bool = false, failPurge: Bool = false) { self.holdPurge = holdPurge; self.failPurge = failPurge }
    func download(_ request: ModelDownloadCoordinator.Request) async throws {
        let index = requests.count
        requests.append(request)
        defer { finished.insert(index) }
        try await withCheckedThrowingContinuation { waiters[index] = $0 }
    }
    func finish(_ index: Int, failure: Bool = false) {
        let waiter = waiters.removeValue(forKey: index)
        if failure { waiter?.resume(throwing: DownloadTestError.failure) } else { waiter?.resume() }
    }
    func purge(_ kind: LocalModelKind) async throws {
        purges.append(kind)
        if holdPurge { await withCheckedContinuation { purgeWaiter = $0 } }
        purgeReturned = true
        if failPurge { throw DownloadTestError.failure }
    }
    func releasePurge() { purgeWaiter?.resume(); purgeWaiter = nil }
    func isCached(_ request: ModelDownloadCoordinator.Request) -> Bool { cacheRequests.append(request); return true }
}

private final class DownloadStreams: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var subscribers: [UUID: AsyncStream<LocalAIPluginState>.Continuation] = [:]
    var activeCount: Int { lock.withLock { subscribers.count } }
    func subscribe() -> AsyncStream<LocalAIPluginState> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { subscribers[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.subscribers[id] = nil }
            }
        }
    }
    func emit(_ value: LocalAIPluginState) {
        let current = lock.withLock { Array(subscribers.values) }
        current.forEach { $0.yield(value) }
    }
}
