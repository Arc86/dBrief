import Foundation
import Testing
import dBriefWire
import MLXLMCommon
@testable import dBriefMLHost

@Suite("Gemma model download progress")
struct GemmaModelDownloadProgressTests {
    @Test(arguments: [false, true])
    func reportsDownloadThenLoadingWithCapturedRequestSink(cached: Bool) async throws {
        let received = DownloadEvents()
        let forwarded = DownloadEvents()
        let downloader = GemmaModelDownloader(base: FixtureDownloader(cached: cached), stateHandler: received.record)
        // The SDK callback deliberately runs detached, without a TaskLocal sink.
        let directory = try await downloader.download(id: "test/model", revision: "main", matching: ["*.json"], useLatest: false) { progress in
            forwarded.record(.downloading(progress: progress.fractionCompleted, stage: .llmModel))
        }
        #expect(directory.path == "/synthetic/model")
        #expect(received.events == (cached ? ["prepare", "load"] : ["prepare", "download:0.25", "download:1.0", "load"]))
        #expect(forwarded.events == (cached ? [] : ["download:0.25", "download:1.0"]))
    }

    @Test(arguments: [false, true])
    func failedOrCancelledDownloadsNeverReportLoading(cancelled: Bool) async {
        let received = DownloadEvents()
        let downloader = GemmaModelDownloader(base: FixtureDownloader(fail: !cancelled, cancel: cancelled), stateHandler: received.record)
        let operation = Task {
            try await downloader.download(id: "test/model", revision: "main", matching: [], useLatest: false) { _ in }
        }
        do {
            _ = try await operation.value
            Issue.record("Failed/cancelled download returned a model directory")
        } catch {
            if cancelled { #expect(error is CancellationError) }
            else { #expect(error is FixtureFailure) }
        }
        #expect(!received.events.contains("load"))
        #expect(received.events.first == "prepare")
    }

    @Test(arguments: [DownloadStage.llmModelPreparing, .llmModel, .llmModelLoading])
    func newStagesSurviveHelperWireRoundTrip(stage: DownloadStage) throws {
        let data = try JSONEncoder().encode(LocalAIPluginState.downloading(progress: 0.4, stage: stage))
        let decoded = try JSONDecoder().decode(LocalAIPluginState.self, from: data)
        guard case .downloading(let fraction, let decodedStage) = decoded else {
            Issue.record("Lost download state in transport"); return
        }
        #expect(fraction == 0.4)
        #expect(decodedStage == stage)
    }
}

private struct FixtureDownloader: Downloader {
    var cached = false
    var fail = false
    var cancel = false
    func download(id: String, revision: String?, matching patterns: [String], useLatest: Bool,
                  progressHandler: @Sendable @escaping (Progress) -> Void) async throws -> URL {
        #expect(id == "test/model")
        #expect(revision == "main")
        #expect(!useLatest)
        if fail { throw FixtureFailure() }
        if !cached {
            await Task.detached {
                #expect(MLProgress.sink == nil)
                let progress = Progress(totalUnitCount: 100)
                progress.completedUnitCount = 25
                progressHandler(progress)
                progress.completedUnitCount = 100
                progressHandler(progress)
            }.value
        }
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        return URL(fileURLWithPath: "/synthetic/model")
    }
}
private struct FixtureFailure: Error {}
private final class DownloadEvents: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var values: [String] = []
    var events: [String] { lock.withLock { values } }
    func record(_ state: LocalAIPluginState) {
        let event: String
        switch state {
        case .downloading(_, .llmModelPreparing): event = "prepare"
        case .downloading(let fraction, .llmModel): event = "download:\(fraction ?? -1)"
        case .downloading(_, .llmModelLoading): event = "load"
        default: event = "unexpected"
        }
        lock.withLock { values.append(event) }
    }
}
