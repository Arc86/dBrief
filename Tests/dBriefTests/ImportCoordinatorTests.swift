import Foundation
import Testing
@testable import dBrief

@Suite("Import preparation")
struct ImportCoordinatorTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func pickedCopyPreservesOriginalExtensionBytesAndReviewBeforeProbe() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Meeting.FLAC")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: source)
        let coordinator = ImportCoordinator(temporaryRoot: root, probe: { _ in
            Issue.record("Picked-file preparation should publish before probing")
            return 42
        })
        let prepared = try await coordinator.preparePickedFile(source, title: "meeting")
        #expect(prepared.sourceURL == source)
        #expect(prepared.stagedURL != source)
        #expect(prepared.stagedURL.pathExtension == "FLAC")
        #expect(prepared.title == "meeting")
        #expect(prepared.fileSize == 4)
        #expect(prepared.duration == 0)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try Data(contentsOf: prepared.stagedURL) == bytes)
        await coordinator.discard(prepared)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: prepared.stagedURL.path))
    }

    @Test func watchedCopyUsesSourceStemAndProbesTheStagedCopy() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Interview")
        try Data([1, 2]).write(to: source)
        let coordinator = ImportCoordinator(temporaryRoot: root, probe: { url in
            #expect(url != source)
            #expect(url.pathExtension == "m4a")
            return 42
        })
        let prepared = try await coordinator.prepareWatchedFile(source)
        #expect(prepared.title == "Interview")
        #expect(prepared.duration == 42)
        #expect(prepared.fileSize == 2)
        #expect(try Data(contentsOf: source) == Data([1, 2]))
        await coordinator.discard(prepared)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test(arguments: ["  Video title \n", " \n"])
    func downloadedAudioTransfersOwnershipWithoutAnotherCopy(title: String) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("download.m4a")
        try Data([1, 2, 3]).write(to: audio)
        let coordinator = ImportCoordinator(temporaryRoot: root, probe: { _ in 18 }, download: { value in
            #expect(value == "synthetic-download")
            return (audio, title)
        })
        let prepared = try await coordinator.prepareDownload(from: "synthetic-download")
        #expect(prepared.sourceURL == audio && prepared.stagedURL == audio)
        #expect(prepared.title == (title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "youtube-video" : "Video title"))
        #expect(prepared.duration == 18 && prepared.fileSize == 3)
        await coordinator.discard(prepared)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }

    @Test func cancellationDuringProbeRemovesOnlyOwnedStage() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try Data([1]).write(to: source)
        let gate = ImportProbeGate()
        let coordinator = ImportCoordinator(temporaryRoot: root, probe: { await gate.probe($0) })
        let task = Task { try await coordinator.prepareWatchedFile(source) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await gate.url == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let staged = try #require(await gate.url)
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func failedCopyLeavesOriginalAndRemovesPartialStage() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try Data([1, 2]).write(to: source)
        let id = UUID()
        let coordinator = ImportCoordinator(temporaryRoot: root, makeID: { id }, files: .init(copy: { _, dest in
            try Data([1]).write(to: dest)
            throw CocoaError(.fileWriteOutOfSpace)
        }))
        await #expect(throws: CocoaError.self) { try await coordinator.preparePickedFile(source, title: "meeting") }
        #expect(try Data(contentsOf: source) == Data([1, 2]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["source.wav"])
    }
    @Test func danglingSymlinkCollisionIsNeverCleanedUpAsAnOwnedStage() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let staged = root.appendingPathComponent("import-\(id.uuidString).wav")
        let source = root.appendingPathComponent("source.wav")
        try Data([1]).write(to: source)
        try FileManager.default.createSymbolicLink(atPath: staged.path, withDestinationPath: "missing-target")
        let coordinator = ImportCoordinator(temporaryRoot: root, makeID: { id })
        await #expect(throws: (any Error).self) { try await coordinator.preparePickedFile(source, title: "meeting") }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: staged.path) == "missing-target")
        #expect(try Data(contentsOf: source) == Data([1]))
    }

    @Test func cancelledDownloadThatReturnsAudioIsCleanedWithoutProbing() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("download.m4a")
        try Data([1]).write(to: audio)
        let gate = ImportProbeGate()
        let coordinator = ImportCoordinator(temporaryRoot: root, probe: { _ in
            Issue.record("A cancelled download should not start probing")
            return 0
        }, download: { _ in
            _ = await gate.probe(audio) // Deliberately ignores cancellation like a blocking downloader.
            return (audio, "Video")
        })
        let task = Task { try await coordinator.prepareDownload(from: "synthetic") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await gate.url == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.url != nil)
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }

    @Test @MainActor func fileCopiesAndMetadataReadsRunOffMainThread() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try Data([1]).write(to: source)
        let instant = Date(timeIntervalSince1970: 123)
        let coordinator = ImportCoordinator(temporaryRoot: root, now: { instant }, files: .init(copy: { source, target in
            #expect(!Thread.isMainThread)
            try FileManager.default.copyItem(at: source, to: target)
        }, size: { _ in
            #expect(!Thread.isMainThread)
            return 1
        }))
        let prepared = try await coordinator.preparePickedFile(source, title: "meeting")
        #expect(prepared.fileSize == 1)
        #expect(prepared.date == instant)
    }

    @Test(arguments: [Double.nan, .infinity, -1, 0])
    func invalidDurationsRemainUnknown(value: Double) async {
        let coordinator = ImportCoordinator(probe: { _ in value })
        #expect(await coordinator.durationSeconds(for: URL(fileURLWithPath: "/synthetic.wav")) == 0)
    }

}

private actor ImportProbeGate {
    private(set) var url: URL?
    private var waiter: CheckedContinuation<Double, Never>?
    func probe(_ url: URL) async -> Double {
        self.url = url
        return await withCheckedContinuation { waiter = $0 }
    }
    func release() { waiter?.resume(returning: 23); waiter = nil }
}
