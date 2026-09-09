import Foundation
import Testing
@testable import dBrief

struct ReprocessingStoreTests {
    private struct Fixture {
        let root: URL
        let audio: URL
        let storeRoot: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("reprocessing-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            audio = root.appendingPathComponent("meeting.m4a")
            storeRoot = root.appendingPathComponent("attempts")
            try Data([0, 1, 2, 255, 42]).write(to: audio)
        }
        func sidecar(_ suffix: String) -> URL { audio.deletingPathExtension().appendingPathExtension(suffix) }
        func write(_ text: String, _ suffix: String) throws { try Data(text.utf8).write(to: sidecar(suffix)) }
        func read(_ suffix: String) throws -> String { String(decoding: try Data(contentsOf: sidecar(suffix)), as: UTF8.self) }
        func setUpdatedAt(_ date: Date, attemptID: UUID) throws {
            let manifest = storeRoot.appendingPathComponent(attemptID.uuidString).appendingPathComponent("manifest.json")
            var attempt = try JSONDecoder().decode(ReprocessingStore.Attempt.self, from: Data(contentsOf: manifest))
            attempt.updatedAt = date
            try JSONEncoder().encode(attempt).write(to: manifest, options: .atomic)
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
    private enum SimulatedCrash: Error { case interrupted }

    @Test func stagesRemainPrivateAndRestoreEntirePreviousResultSet() async throws {
        let f = try Fixture(); defer { f.clean() }
        let audioBefore = try Data(contentsOf: f.audio)
        try f.write("old transcript", "transcript.json")
        try f.write("old insights", "insights.json")
        try f.write("old chat", "chat.json")
        try f.write("user note", "md")
        try f.write("delivery history", "integrations.json")
        let store = ReprocessingStore(root: f.storeRoot)
        let attempt = try await store.prepare(audioURL: f.audio, configuration: Data("settings".utf8))
        try await store.stage(Data("new transcript".utf8), suffix: "transcript.json", attemptID: attempt.id)
        try await store.stage(Data("new rich".utf8), suffix: "richtranscript.json", attemptID: attempt.id)
        try await store.stageRemoval(suffix: "chat.json", attemptID: attempt.id)
        #expect(try f.read("transcript.json") == "old transcript")
        #expect(try f.read("chat.json") == "old chat")
        try await store.commit(attemptID: attempt.id)
        #expect(try f.read("transcript.json") == "new transcript")
        #expect(try f.read("insights.json") == "old insights")
        #expect(!FileManager.default.fileExists(atPath: f.sidecar("chat.json").path))
        try await store.restore(audioURL: f.audio)
        #expect(try f.read("transcript.json") == "old transcript")
        #expect(!FileManager.default.fileExists(atPath: f.sidecar("chat.json").path))
        #expect(!FileManager.default.fileExists(atPath: f.sidecar("richtranscript.json").path))
        #expect(try f.read("md") == "user note")
        #expect(try f.read("integrations.json") == "delivery history")
        #expect(try Data(contentsOf: f.audio) == audioBefore)
    }

    @Test func recreationRetainsFrozenConfigurationCheckpointsAndStagedBytes() async throws {
        let f = try Fixture(); defer { f.clean() }
        let store = ReprocessingStore(root: f.storeRoot)
        let attempt = try await store.prepare(audioURL: f.audio, configuration: Data("English".utf8))
        try await store.stage(Data("candidate".utf8), suffix: "transcript.json", attemptID: attempt.id)
        try await store.checkpoint(attemptID: attempt.id, status: .stopped, completedStage: "transcribing", progress: 0.4, message: "Stopped")
        let reopened = ReprocessingStore(root: f.storeRoot)
        let resumed = try await reopened.load(attemptID: attempt.id)
        #expect(resumed.configuration == Data("English".utf8))
        #expect(resumed.status == .stopped)
        #expect(resumed.completedStages == ["transcribing"])
        #expect(resumed.progress == 0.4)
        #expect(try await reopened.stagedData(suffix: "transcript.json", attemptID: attempt.id) == Data("candidate".utf8))
        #expect(try await reopened.discover().map(\.id) == [attempt.id])
        await #expect(throws: (any Error).self) { try await reopened.prepare(audioURL: f.audio, configuration: Data()) }
        try await reopened.discard(attemptID: attempt.id)
        #expect(try await reopened.discover().isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.audio.path))
    }

    @Test func restoreAllowsNewDerivativesAndNeverResurrectsOldOnes() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write("old transcript", "transcript.json")
        let derivatives = ["chat.json", "spokensummary.json", "spokensummary.m4a"]
        for suffix in derivatives { try f.write("old derivative", suffix) }
        let store = ReprocessingStore(root: f.storeRoot)
        let attempt = try await store.prepare(audioURL: f.audio, configuration: Data())
        try await store.stage(Data("new transcript".utf8), suffix: "transcript.json", attemptID: attempt.id)
        for suffix in derivatives { try await store.stageRemoval(suffix: suffix, attemptID: attempt.id) }
        try await store.commit(attemptID: attempt.id)
        for suffix in derivatives { try f.write("new derivative", suffix) }
        // Interrupt after the first derivative removal to exercise missing targets
        // in the restore journal, not just a successful uninterrupted restore.
        let crashing = ReprocessingStore(root: f.storeRoot, publicationStep: { _ in throw SimulatedCrash.interrupted })
        await #expect(throws: SimulatedCrash.self) { try await crashing.restore(audioURL: f.audio) }
        let publishing = try #require(try await store.discover().first { $0.status == .publishing })
        for suffix in derivatives {
            #expect(publishing.publishedFingerprints?[suffix] == .missing)
        }
        let reopened = ReprocessingStore(root: f.storeRoot)
        _ = try await reopened.recover()
        #expect(try f.read("transcript.json") == "old transcript")
        for suffix in derivatives { #expect(!FileManager.default.fileExists(atPath: f.sidecar(suffix).path)) }
    }

    @Test func purgeCompletedRemovesOnlyRetainedWorkspaceAndRefusesPendingAttempt() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write("old transcript", "transcript.json")
        let store = ReprocessingStore(root: f.storeRoot)
        let completed = try await store.prepare(audioURL: f.audio, configuration: Data())
        try await store.stage(Data("new transcript".utf8), suffix: "transcript.json", attemptID: completed.id)
        try await store.commit(attemptID: completed.id)
        let pending = try await store.prepare(audioURL: f.audio, configuration: Data())
        await #expect(throws: ReprocessingStore.StoreError.self) { try await store.purgeCompleted(audioURL: f.audio) }
        #expect(try await store.discover().count == 2)
        try await store.discard(attemptID: pending.id)
        try await store.purgeCompleted(audioURL: f.audio)
        #expect(try await store.discover().isEmpty)
        #expect(try f.read("transcript.json") == "new transcript")
        #expect(FileManager.default.fileExists(atPath: f.audio.path))
    }

    @Test func missingAudioCleanupKeepsPendingWorkspaceAndItsPreviousResults() async throws {
        let f = try Fixture(); defer { f.clean() }
        let store = ReprocessingStore(root: f.storeRoot)
        let completed = try await store.prepare(audioURL: f.audio, configuration: Data())
        try await store.stage(Data("new transcript".utf8), suffix: "transcript.json", attemptID: completed.id)
        try await store.commit(attemptID: completed.id)
        try await store.purgeCompletedForMissingAudio()
        #expect(try await store.discover().map(\.id) == [completed.id])
        let pending = try await store.prepare(audioURL: f.audio, configuration: Data())
        try await store.checkpoint(attemptID: pending.id, status: .stopped)
        try FileManager.default.removeItem(at: f.audio)
        try await store.purgeCompletedForMissingAudio()
        #expect(try await store.discover().count == 2)
        #expect(try await store.load(attemptID: pending.id).status == .stopped)
        try await store.discard(attemptID: pending.id)
        try await store.purgeCompletedForMissingAudio()
        #expect(try await store.discover().isEmpty)
        #expect(try f.read("transcript.json") == "new transcript")
    }

    @Test func transcriptHistoryRetentionHonorsAgeFolderScopeAndPendingProtection() async throws {
        let f = try Fixture(); defer { f.clean() }
        let store = ReprocessingStore(root: f.storeRoot)
        let selected = f.root.appendingPathComponent("selected", isDirectory: true)
        let nested = selected.appendingPathComponent("nested", isDirectory: true)
        let outside = f.root.appendingPathComponent("selected-other", isDirectory: true)
        let cutoff = Date(timeIntervalSince1970: 1_000_000)
        func completed(_ name: String, in folder: URL, date: Date) async throws -> ReprocessingStore.Attempt {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let audio = folder.appendingPathComponent(name + ".m4a")
            try Data("audio-\(name)".utf8).write(to: audio)
            let attempt = try await store.prepare(audioURL: audio, configuration: Data())
            try await store.stage(Data("transcript-\(name)".utf8), suffix: "transcript.json", attemptID: attempt.id)
            try await store.commit(attemptID: attempt.id)
            try f.setUpdatedAt(date, attemptID: attempt.id)
            return attempt
        }
        let expired = try await completed("expired", in: nested, date: cutoff)
        let recent = try await completed("recent", in: selected, date: cutoff.addingTimeInterval(1))
        let unselected = try await completed("outside", in: outside, date: cutoff.addingTimeInterval(-1))
        let prior = try await completed("pending", in: selected, date: cutoff.addingTimeInterval(-1))
        let pending = try await store.prepare(audioURL: prior.audioURL, configuration: Data())
        try await store.checkpoint(attemptID: pending.id, status: .failed)
        #expect(try await store.purgeCompletedTranscriptHistory(olderThan: cutoff, in: [selected]) == 1)
        let retainedIDs = Set(try await store.discover().map(\.id))
        #expect(retainedIDs == Set([recent.id, unselected.id, prior.id, pending.id]))
        #expect(!FileManager.default.fileExists(atPath: f.storeRoot.appendingPathComponent(expired.id.uuidString).path))
        #expect(try Data(contentsOf: expired.audioURL) == Data("audio-expired".utf8))
        let current = expired.audioURL.deletingPathExtension().appendingPathExtension("transcript.json")
        #expect(try Data(contentsOf: current) == Data("transcript-expired".utf8))
        #expect(try await store.purgeCompletedTranscriptHistory(olderThan: .distantFuture, in: []) == 0)
    }

    @Test(arguments: ["transcript.json", "insights.json", "chat.json", "m4a"])
    func changedSourceOrResultRejectsCommit(_ changed: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write("original", "transcript.json")
        let store = ReprocessingStore(root: f.storeRoot)
        let attempt = try await store.prepare(audioURL: f.audio, configuration: Data())
        try await store.stage(Data("candidate".utf8), suffix: "transcript.json", attemptID: attempt.id)
        try f.write("external edit", changed)
        await #expect(throws: (any Error).self) { try await store.commit(attemptID: attempt.id) }
        #expect(try f.read(changed) == "external edit")
        #expect(try await store.stagedData(suffix: "transcript.json", attemptID: attempt.id) == Data("candidate".utf8))
    }

    @Test func originalSnapshotAndValidationSurviveRestart() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write("original", "transcript.json")
        try f.write("previous settings", "reprocessing.json")
        let store = ReprocessingStore(root: f.storeRoot)
        let a = try await store.prepare(audioURL: f.audio, configuration: Data())
        let reopened = ReprocessingStore(root: f.storeRoot)
        try await reopened.validate(attemptID: a.id)
        try f.write("edit", "transcript.json")
        #expect(try await reopened.originalData(suffix: "transcript.json", attemptID: a.id) == Data("original".utf8))
        #expect(try await reopened.originalData(suffix: "reprocessing.json", attemptID: a.id) == Data("previous settings".utf8))
        await #expect(throws: (any Error).self) { try await reopened.validate(attemptID: a.id) }
    }

    @Test func missingAudioRejectsPublication() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write("old", "transcript.json")
        let store = ReprocessingStore(root: f.storeRoot)
        let a = try await store.prepare(audioURL: f.audio, configuration: Data())
        try await store.stage(Data("new".utf8), suffix: "transcript.json", attemptID: a.id)
        try FileManager.default.removeItem(at: f.audio)
        await #expect(throws: (any Error).self) { try await store.commit(attemptID: a.id) }
        #expect(try f.read("transcript.json") == "old")
    }

    @Test func partialCommitRecoversIdempotentlyAndPreservesOriginalBackups() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write("old transcript", "transcript.json")
        try f.write("old insights", "insights.json")
        let store = ReprocessingStore(root: f.storeRoot, publicationStep: { _ in throw SimulatedCrash.interrupted })
        let a = try await store.prepare(audioURL: f.audio, configuration: Data())
        try await store.stage(Data("new transcript".utf8), suffix: "transcript.json", attemptID: a.id)
        try await store.stage(Data("new insights".utf8), suffix: "insights.json", attemptID: a.id)
        await #expect(throws: SimulatedCrash.self) { try await store.commit(attemptID: a.id) }
        let reopened = ReprocessingStore(root: f.storeRoot)
        _ = try await reopened.recover()
        _ = try await reopened.recover()
        #expect(try f.read("transcript.json") == "new transcript")
        #expect(try f.read("insights.json") == "new insights")
        #expect(try await reopened.load(attemptID: a.id).status == .completed)
        try await reopened.restore(audioURL: f.audio)
        #expect(try f.read("transcript.json") == "old transcript")
        #expect(try f.read("insights.json") == "old insights")
    }

    @Test func recoveryDoesNotOverwriteAnExternalEditAfterPartialPublication() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write("old", "transcript.json")
        let store = ReprocessingStore(root: f.storeRoot, publicationStep: { _ in throw SimulatedCrash.interrupted })
        let a = try await store.prepare(audioURL: f.audio, configuration: Data())
        try await store.stage(Data("new".utf8), suffix: "transcript.json", attemptID: a.id)
        await #expect(throws: SimulatedCrash.self) { try await store.commit(attemptID: a.id) }
        try f.write("external edit", "transcript.json")
        let reopened = ReprocessingStore(root: f.storeRoot)
        await #expect(throws: (any Error).self) { _ = try await reopened.recover() }
        #expect(try f.read("transcript.json") == "external edit")
    }

    @Test func partialRestoreRecoversAndLaterEditsBlockRestore() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write("old transcript", "transcript.json")
        try f.write("old insights", "insights.json")
        let store = ReprocessingStore(root: f.storeRoot)
        let a = try await store.prepare(audioURL: f.audio, configuration: Data())
        try await store.stage(Data("new transcript".utf8), suffix: "transcript.json", attemptID: a.id)
        try await store.stage(Data("new insights".utf8), suffix: "insights.json", attemptID: a.id)
        try await store.commit(attemptID: a.id)
        let crashing = ReprocessingStore(root: f.storeRoot, publicationStep: { _ in throw SimulatedCrash.interrupted })
        await #expect(throws: SimulatedCrash.self) { try await crashing.restore(audioURL: f.audio) }
        let reopened = ReprocessingStore(root: f.storeRoot)
        _ = try await reopened.recover()
        #expect(try f.read("transcript.json") == "old transcript")
        #expect(try f.read("insights.json") == "old insights")
        try f.write("manual edit", "transcript.json")
        await #expect(throws: (any Error).self) { try await reopened.restore(audioURL: f.audio) }
        #expect(try f.read("transcript.json") == "manual edit")
    }

    @Test(arguments: ["../outside", "m4a", "md", "json", "privacy.json", "integrations.json"])
    func rejectsUnownedSuffixes(_ suffix: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let store = ReprocessingStore(root: f.storeRoot)
        let a = try await store.prepare(audioURL: f.audio, configuration: Data())
        await #expect(throws: (any Error).self) { try await store.stage(Data(), suffix: suffix, attemptID: a.id) }
    }

    @Test func simultaneousStoresCannotPrepareTwoAttemptsForOneRecording() async throws {
        let f = try Fixture(); defer { f.clean() }
        let first = ReprocessingStore(root: f.storeRoot)
        let second = ReprocessingStore(root: f.storeRoot)
        async let a: UUID? = try? first.prepare(audioURL: f.audio, configuration: Data()).id
        async let b: UUID? = try? second.prepare(audioURL: f.audio, configuration: Data()).id
        let ids = await [a, b].compactMap { $0 }
        #expect(ids.count == 1)
        #expect(try await first.discover().count == 1)
    }

    @Test func damagedCandidateIsRejectedBeforeAnyCanonicalMutation() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write("old transcript", "transcript.json")
        try f.write("old analysis", "insights.json")
        let store = ReprocessingStore(root: f.storeRoot)
        let a = try await store.prepare(audioURL: f.audio, configuration: Data())
        try await store.stage(Data("new transcript".utf8), suffix: "transcript.json", attemptID: a.id)
        try await store.stage(Data("new analysis".utf8), suffix: "insights.json", attemptID: a.id)
        let staged = f.storeRoot.appendingPathComponent(a.id.uuidString).appendingPathComponent("staged/transcript.json")
        try Data("disk damage".utf8).write(to: staged)
        await #expect(throws: (any Error).self) { try await store.commit(attemptID: a.id) }
        #expect(try f.read("transcript.json") == "old transcript")
        #expect(try f.read("insights.json") == "old analysis")
    }

    @Test func symlinkSidecarCannotRedirectPublication() async throws {
        let f = try Fixture(); defer { f.clean() }
        let outside = f.root.appendingPathComponent("private-note")
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: f.sidecar("transcript.json"), withDestinationURL: outside)
        let store = ReprocessingStore(root: f.storeRoot)
        await #expect(throws: (any Error).self) { try await store.prepare(audioURL: f.audio, configuration: Data()) }
        #expect(try Data(contentsOf: outside) == Data("private".utf8))
    }

    @Test func pendingAttemptRejectsCanonicalWritersUntilDiscard() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write("old", "transcript.json")
        let store = ReprocessingStore(root: f.storeRoot)
        let a = try await store.prepare(audioURL: f.audio, configuration: Data())
        #expect(throws: (any Error).self) {
            try RecordingResultMutation.withWrite(to: f.sidecar("transcript.json")) {
                try f.write("late write", "transcript.json")
            }
        }
        #expect(try f.read("transcript.json") == "old")
        try await store.checkpoint(attemptID: a.id, status: .stopped)
        #expect(throws: (any Error).self) {
            try RecordingResultMutation.withWrite(to: f.sidecar("insights.json")) {
                try f.write("late analysis", "insights.json")
            }
        }
        try await store.discard(attemptID: a.id)
        try RecordingResultMutation.withWrite(to: f.sidecar("transcript.json")) {
            try f.write("allowed edit", "transcript.json")
        }
        #expect(try f.read("transcript.json") == "allowed edit")
    }

    @Test func discoveryReclaimsDurablePendingAttemptAndCommitReleasesWriters() async throws {
        let f = try Fixture(); defer { f.clean() }
        let store = ReprocessingStore(root: f.storeRoot)
        let a = try await store.prepare(audioURL: f.audio, configuration: Data())
        try await store.stage(Data("new".utf8), suffix: "transcript.json", attemptID: a.id)
        // Emulate process-local lock state being lost on app termination.
        RecordingResultMutation.release(audioURL: f.audio, attemptID: a.id)
        let reopened = ReprocessingStore(root: f.storeRoot)
        _ = try await reopened.discover()
        #expect(throws: (any Error).self) {
            try RecordingResultMutation.withWrite(to: f.sidecar("transcript.json")) {
                try f.write("late write", "transcript.json")
            }
        }
        try await reopened.commit(attemptID: a.id)
        try RecordingResultMutation.withWrite(to: f.sidecar("transcript.json")) {
            try f.write("edited published result", "transcript.json")
        }
        #expect(try f.read("transcript.json") == "edited published result")
    }

    @Test func workspacesAndPayloadsHavePrivatePermissions() async throws {
        let f = try Fixture(); defer { f.clean() }
        let store = ReprocessingStore(root: f.storeRoot)
        let a = try await store.prepare(audioURL: f.audio, configuration: Data("private config".utf8))
        try await store.stage(Data("private transcript".utf8), suffix: "transcript.json", attemptID: a.id)
        let enumerator = try #require(FileManager.default.enumerator(at: f.storeRoot, includingPropertiesForKeys: nil))
        while let url = enumerator.nextObject() as? URL {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(permissions.intValue & 0o077 == 0)
        }
    }
}
