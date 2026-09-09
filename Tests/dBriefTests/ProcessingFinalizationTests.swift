import Foundation
import Testing
@testable import dBrief

@Suite("Processing finalization")
struct ProcessingFinalizationTests {
    private actor Audit {
        var calls: [String] = []
        var facts: ProcessingPipeline.FinalizedAudioFacts?
        func add(_ call: String) { calls.append(call) }
        func measured(_ value: ProcessingPipeline.FinalizedAudioFacts) { facts = value; calls.append("measured") }
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func result(_ root: URL) -> RecordingFinalizationResult {
        .init(masterAudioURL: root.appendingPathComponent("master.m4a"), segmentAudioURLs: [],
              metadataURL: root.appendingPathComponent("master.json"), warnings: [], ffmpegDiagnostics: nil)
    }
    private func files(_ root: URL) -> ProcessingPipeline.FinalizationFiles {
        let journal = DurabilityJournal(directoryURL: root.appendingPathComponent("diagnostics"))
        return .init(record: { event in
            #expect(!Thread.isMainThread)
            journal.record(event)
        })
    }

    @Test @MainActor func committedCaptureIsAdoptedBeforeProbingEvenWhenStopArrives() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try InterruptedSessionStore.createSession(id: UUID(), startedAt: .distantPast, rootURL: root.appendingPathComponent("recovery"))
        let raw = session.directoryURL.appendingPathComponent("capture.mic.caf")
        let bytes = Data(repeating: 3, count: 5000)
        try bytes.write(to: raw)
        let output = result(root)
        let audit = Audit()
        let recovery = ProcessingPipeline.FinalizationRecovery(url: session.manifestURL,
            manifest: .init(id: UUID(), startedAt: .distantPast, state: .finalizing,
                            tracks: [.init(kind: .microphone, relativePath: raw.lastPathComponent)]))
        let input = ProcessingPipeline.FinalizationRequest(recordingID: recovery.manifest.id, duration: 12,
            source: .capture(.init(systemURL: nil, micURL: raw)), recovery: recovery)
        let context = PrivacyTrace.Context(receiptURL: root.appendingPathComponent("privacy.json"), recordingID: input.recordingID)
        let pipeline = ProcessingPipeline(duration: { url in
            #expect(url == output.masterAudioURL)
            #expect(await audit.calls == ["adopt"])
            #expect(PrivacyTrace.context?.runID == context.runID)
            return 24
        })
        let dependencies = files(root)
        let task = Task {
            try await PrivacyTrace.$context.withValue(context) {
                try await pipeline.finalizeAudio(input, steps: .init(finalize: {
                    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                    let saved = try decoder.decode(InterruptedSessionManifest.self, from: Data(contentsOf: session.manifestURL))
                    #expect(saved == recovery.manifest)
                    try FileManager.default.copyItem(at: raw, to: output.masterAudioURL)
                    try Data("{}".utf8).write(to: output.metadataURL)
                    try FileManager.default.removeItem(at: raw)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return output
                }, adopt: { @MainActor value in
                    #expect(Task.isCancelled)
                    #expect(value.masterAudioURL == output.masterAudioURL)
                    #expect(PrivacyTrace.context?.runID == context.runID)
                    await audit.add("adopt")
                }, measured: { await audit.measured($0) }, recoveryCompleted: { url in
                    #expect(url == session.manifestURL)
                    #expect(!FileManager.default.fileExists(atPath: session.directoryURL.path))
                    await audit.add("cleanup")
                }), files: dependencies)
            }
        }
        try await task.value
        #expect(await audit.calls == ["adopt", "measured", "cleanup"])
        #expect(await audit.facts?.fileSize == 5000)
        #expect(await audit.facts?.duration == 24)
        #expect(try Data(contentsOf: output.masterAudioURL) == bytes)
        let events = DurabilityJournal(directoryURL: root.appendingPathComponent("diagnostics")).recentEvents()
        #expect(events.map(\.outcome) == [.started, .succeeded])
        #expect(events.first?.measurements["trackBytes"] == 5000)
        #expect(events.last?.measurements["masterBytes"] == 5000)
        #expect(events.last?.measurements["durationMilliseconds"] == 24000)
    }

    @Test func failedFinalizerRetainsRecoveryAndDoesNotPublish() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("mic.caf")
        try Data(repeating: 2, count: 100).write(to: raw)
        let recovery = ProcessingPipeline.FinalizationRecovery(url: root.appendingPathComponent("recovery/session.json"),
            manifest: .init(id: UUID(), startedAt: .distantPast, state: .finalizing, tracks: []))
        let input = ProcessingPipeline.FinalizationRequest(recordingID: UUID(), duration: 1,
            source: .capture(.init(systemURL: nil, micURL: raw)), recovery: recovery)
        await #expect(throws: CocoaError.self) {
            try await ProcessingPipeline().finalizeAudio(input, steps: .init(finalize: { throw CocoaError(.fileWriteOutOfSpace) },
                adopt: { _ in Issue.record("Must not adopt failed output") },
                measured: { _ in Issue.record("Must not probe failed output") },
                recoveryCompleted: { _ in Issue.record("Must retain recovery") }), files: files(root))
        }
        #expect(FileManager.default.fileExists(atPath: raw.path))
        #expect(FileManager.default.fileExists(atPath: recovery.url.path))
        let events = DurabilityJournal(directoryURL: root.appendingPathComponent("diagnostics")).recentEvents()
        #expect(events.map(\.outcome) == [.started, .failed])
        #expect(events.last?.measurements["microphoneTrackBytes"] == 100)
    }

    @Test(arguments: [false, true])
    func prefinalizedAudioOnlyProbesMissingDuration(probe: Bool) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = result(root)
        let audit = Audit()
        try await ProcessingPipeline(duration: { _ in await audit.add("probe"); return 7 }).finalizeAudio(
            .init(recordingID: UUID(), duration: probe ? 0 : 10,
                  source: .existing(output.masterAudioURL), recovery: nil),
            steps: .init(finalize: { Issue.record("Already finalized"); return output },
                adopt: { _ in Issue.record("Already adopted") }, measured: { await audit.measured($0) }, recoveryCompleted: { _ in }),
            files: files(root))
        #expect(await audit.calls == (probe ? ["probe", "measured"] : []))
        if probe { #expect(await audit.facts?.duration == 7); #expect(await audit.facts?.fileSize == nil) }
    }

    @Test func importedAudioUsesFileSizeWithoutCaptureProbesOrCleanup() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = result(root)
        try Data(repeating: 1, count: 234).write(to: output.masterAudioURL)
        let audit = Audit()
        try await ProcessingPipeline(duration: { _ in Issue.record("Import duration policy changed"); return 0 }).finalizeAudio(
            .init(recordingID: UUID(), duration: 5, source: .imported, recovery: nil),
            steps: .init(finalize: { output }, adopt: { _ in await audit.add("adopt") },
                measured: { await audit.measured($0) }, recoveryCompleted: { _ in Issue.record("Import cleanup policy changed") }),
            files: files(root))
        #expect(await audit.calls == ["adopt", "measured"])
        #expect(await audit.facts?.fileSize == 234)
        #expect(await audit.facts?.duration == nil)
    }

    @Test func failedRecoveryCleanupWarnsWithoutLosingCommittedMaster() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = result(root)
        try Data("audio".utf8).write(to: output.masterAudioURL)
        let recovery = ProcessingPipeline.FinalizationRecovery(url: root.appendingPathComponent("missing/session.json"),
            manifest: .init(id: UUID(), startedAt: .distantPast, state: .finalizing, tracks: []))
        let audit = Audit()
        try await ProcessingPipeline().finalizeAudio(.init(recordingID: UUID(), duration: 4,
            source: .existing(output.masterAudioURL), recovery: recovery),
            steps: .init(finalize: { output }, adopt: { _ in }, measured: { _ in },
                recoveryCompleted: { _ in await audit.add("retired") }), files: files(root))
        #expect(await audit.calls == ["retired"])
        #expect(try Data(contentsOf: output.masterAudioURL) == Data("audio".utf8))
        let events = DurabilityJournal(directoryURL: root.appendingPathComponent("diagnostics")).recentEvents()
        #expect(events.map(\.name) == ["recovery_session_cleanup"])
        #expect(events.first?.outcome == .warning)
    }

    @Test(arguments: [false, true])
    func stopBeforeCommitDoesNotInvokeFinalizer(afterManifest: Bool) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = ProcessingPipeline.FinalizationRecovery(url: root.appendingPathComponent("recovery/session.json"),
            manifest: .init(id: UUID(), startedAt: .distantPast, state: .finalizing, tracks: []))
        let input = ProcessingPipeline.FinalizationRequest(recordingID: UUID(), duration: 1,
            source: .capture(.init(systemURL: nil, micURL: nil)), recovery: recovery)
        var dependencies = files(root)
        dependencies.writeRecovery = { value in
            #expect(!Thread.isMainThread)
            try InterruptedSessionStore.write(value.manifest, to: value.url)
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let frozen = dependencies
        let output = result(root)
        let task = Task {
            if !afterManifest { withUnsafeCurrentTask { $0?.cancel() } }
            try await ProcessingPipeline().finalizeAudio(input, steps: .init(finalize: {
                Issue.record("Stop must prevent finalization before commit"); return output
            }, adopt: { _ in Issue.record("No committed result") }, measured: { _ in Issue.record("No probe") },
               recoveryCompleted: { _ in Issue.record("Recovery must remain available") }), files: frozen)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(FileManager.default.fileExists(atPath: recovery.url.path) == afterManifest)
    }

    @Test(arguments: [0.0, -1.0, Double.nan, Double.infinity])
    func unavailableMasterProbesKeepKnownDuration(seconds: Double) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = result(root)
        let audit = Audit()
        try await ProcessingPipeline(duration: { _ in seconds }).finalizeAudio(.init(recordingID: UUID(), duration: 9,
            source: .capture(.init(systemURL: nil, micURL: nil)), recovery: nil),
            steps: .init(finalize: { output }, adopt: { _ in }, measured: { await audit.measured($0) },
                         recoveryCompleted: { _ in }), files: files(root))
        #expect(await audit.facts?.fileSize == nil)
        #expect(await audit.facts?.duration == nil)
        let events = DurabilityJournal(directoryURL: root.appendingPathComponent("diagnostics")).recentEvents()
        #expect(events.last?.measurements["durationMilliseconds"] == 9000)
        #expect(events.last?.measurements["masterBytes"] == 0)
    }

}
