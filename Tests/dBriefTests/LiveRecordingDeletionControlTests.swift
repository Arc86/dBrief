import Foundation
import Testing
@testable import dBrief

extension LiveArtifactDurabilityTests {
@MainActor @Suite("Recording-owned Delete controls")
struct LiveRecordingDeletionControlTests {
    @Test func deleteFollowsHeldBindAndClearAndCancellationCannotLoseItsReceipt() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let bind = LiveArtifactGate(stage: .journalPrepared, initiallyEnabled: false)
        let intent = LiveArtifactGate(stage: .deletionIntent)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { try await bind.enter($0); try await intent.enter($0) })
        let entry = try registry.registerLegacy(f.identity)
        entry.artifacts.start(); _ = try await entry.artifacts.loadChat(); try registry.captureDidClose(f.identity)
        try entry.artifacts.saveChat(f.history("Before Bind"), urgent: true); try await entry.artifacts.flush()
        var deletion: Task<Void, any Error>?
        do {
            await bind.arm(); try entry.artifacts.bind(to: f.audio); try await bind.waitForArrival()
            let revision = try entry.artifacts.clearChat()
            let task = Task { try await registry.deleteArtifacts(recordingID: f.identity.recordingID) }; deletion = task
            try await f.eventually { await MainActor.run { entry.artifacts.deletionPending } }
            #expect(entry.isValid)
            #expect(throws: LiveArtifactError.deleted) { try entry.artifacts.saveChat(f.history("Too late"), urgent: true) }
            #expect(throws: LiveArtifactError.deleted) { try entry.artifacts.clearChat() }
            #expect(throws: (any Error).self) { try entry.artifacts.bind(to: f.audio) }
            task.cancel(); await bind.release(); try await intent.waitForArrival()
            let value = try JSONDecoder().decode(ChatHistory.self, from: Data(contentsOf: f.audio.deletingPathExtension().appendingPathExtension("chat.json")))
            #expect(value.messages.isEmpty && value.revision == revision)
            #expect(entry.isValid)
            #expect(await entry.artifacts.writer.status().deleted == false)
            await intent.release(); try await task.value
            #expect(!entry.isValid && registry.hasPendingDeletion(recordingID: f.identity.recordingID))
            #expect(FileManager.default.fileExists(atPath: f.audio.path))
            registry.completeDeletion(recordingID: f.identity.recordingID)
        } catch {
            await bind.release(); await intent.release(); _ = try? await deletion?.value
            await entry.artifacts.waitForSubmittedWrites(); throw error
        }
    }

    @Test func deleteJoinsAnAdmittedHistoryLoadBeforeCommittingItsIntent() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let load = LiveArtifactGate(stage: .historyLoad, initiallyEnabled: false), intent = LiveArtifactGate(stage: .deletionIntent)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { try await load.enter($0); try await intent.enter($0) })
        let entry = try registry.registerLegacy(f.identity)
        entry.artifacts.start(); try registry.captureDidClose(f.identity); try await entry.artifacts.flush()
        var loading: Task<ChatHistory?, any Error>?, deletion: Task<Void, any Error>?
        do {
            await load.arm(); let read = Task { try await entry.artifacts.loadChat() }; loading = read
            try await load.waitForArrival()
            let task = Task { try await registry.deleteArtifacts(recordingID: f.identity.recordingID) }; deletion = task
            try await f.eventually { await MainActor.run { entry.artifacts.deletionPending } }
            #expect(await entry.artifacts.writer.status().deleted == false && entry.isValid)
            task.cancel(); await load.release(); try await intent.waitForArrival()
            #expect(try await read.value == nil)
            #expect(entry.isValid)
            await intent.release(); try await task.value
            #expect(!entry.isValid && registry.hasPendingDeletion(recordingID: f.identity.recordingID))
            registry.completeDeletion(recordingID: f.identity.recordingID)
        } catch {
            await load.release(); await intent.release(); _ = try? await loading?.value; _ = try? await deletion?.value
            await entry.artifacts.waitForSubmittedWrites(); throw error
        }
    }

    @Test func deleteSharesTheExistingEightControlAdmissionLimit() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .journalPrepared, initiallyEnabled: false)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { try await gate.enter($0) })
        let entry = try registry.registerLegacy(f.identity)
        entry.artifacts.start(); _ = try await entry.artifacts.loadChat(); try registry.captureDidClose(f.identity); try await entry.artifacts.flush()
        do {
            await gate.arm(); try entry.artifacts.bind(to: f.audio); try await gate.waitForArrival()
            for _ in 0..<7 { _ = try entry.artifacts.clearChat() }
            await #expect(throws: LiveArtifactError.queueFull) { _ = try await entry.artifacts.commitDeletionIntent() }
            #expect(!entry.artifacts.deletionPending && entry.isValid)
            await gate.release(); try await entry.artifacts.flush()
            #expect(await entry.artifacts.writer.status().deleted == false)
        } catch { await gate.release(); await entry.artifacts.waitForSubmittedWrites(); throw error }
    }

    @Test func retirementSettlesADeleteQueuedBehindHeldPhysicalIO() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .journalPrepared, initiallyEnabled: false)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { try await gate.enter($0) })
        let entry = try registry.registerLegacy(f.identity)
        entry.artifacts.start(); try registry.captureDidClose(f.identity); try await entry.artifacts.flush()
        var deletion: Task<LiveSessionArtifactStore.DeletionReceipt, any Error>?
        do {
            await gate.arm(); try entry.artifacts.bind(to: f.audio); try await gate.waitForArrival()
            let task = Task { try await entry.artifacts.commitDeletionIntent() }; deletion = task
            try await f.eventually { await MainActor.run { entry.artifacts.deletionPending } }
            try registry.retire(f.identity)
            await #expect(throws: LiveArtifactError.deleted) { _ = try await task.value }
            #expect(await entry.artifacts.writer.status().deleted == false)
            await gate.release(); await entry.artifacts.waitForSubmittedWrites()
        } catch { await gate.release(); _ = try? await deletion?.value; await entry.artifacts.waitForSubmittedWrites(); throw error }
    }
}
}
