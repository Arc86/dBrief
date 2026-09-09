import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Processing speaker preparation")
struct ProcessingSpeakerTests {
    private func expectBackgroundScope(_ context: PrivacyTrace.Context) {
        #expect(!Thread.isMainThread)
        #expect(PrivacyTrace.context?.runID == context.runID)
    }
    private actor Audit {
        var calls: [String] = []
        var rich: RichTranscript?
        var items: [SpeakerReviewItem] = []
        func add(_ value: String) { calls.append(value) }
        func publish(_ value: RichTranscript) { rich = value; calls.append("publish") }
        func hold(_ value: [SpeakerReviewItem]) { items = value; calls.append("hold") }
    }
    private actor CheckpointGate {
        var owned = true
        private var entered = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var release: CheckedContinuation<Void, Never>?
        func checkpoint() async {
            await withCheckedContinuation { continuation in
                release = continuation
                entered = true
                waiter?.resume()
                waiter = nil
            }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func replaceOwnerAndRelease() {
            owned = false
            release?.resume()
            release = nil
        }
    }
    private func request(reviewed: Bool = false, required: Bool? = nil) -> ProcessingPipeline.SpeakerRequest {
        .init(transcription: .init(text: "Hello", segments: [.init(start: 0, end: 4, text: "Hello", speaker: "Speaker 1")],
                                  speakerEmbeddings: ["Speaker 1": [1, 0]]),
              participants: ["Alice"], roster: ["Alice"], mode: .confirmFirst,
              reviewAlreadyCompleted: reviewed, reviewRequired: required)
    }
    private func steps(_ audit: Audit, existing: RichTranscript? = nil) -> ProcessingPipeline.SpeakerSteps {
        .init(loadLibrary: { await audit.add("library"); return VoiceLibrary() },
              loadTranscript: { required in await audit.add(required ? "loadRequired" : "load"); return existing },
              saveTranscript: { _ in await audit.add("save") },
              publishTranscript: { await audit.publish($0) },
              checkpointDiarized: { await audit.add($0 ? "checkpointHold" : "checkpoint") },
              holdReview: { await audit.hold($0) },
              enroll: { await audit.add("enroll:\($0.name)") },
              completeReview: { await audit.add("complete") })
    }

    @Test func holdPersistsTranscriptAndCheckpointBeforeOpeningReviewWithoutEnrollment() async throws {
        let audit = Audit()
        let held = try await ProcessingPipeline().prepareSpeakers(request(required: true), steps: steps(audit))
        #expect(held)
        #expect(await audit.calls == ["library", "load", "save", "publish", "checkpointHold", "hold"])
        let item = try #require(await audit.items.first)
        #expect(item.proposedName == "Alice" && item.clusterEmbedding == [1, 0])
        #expect(item.snippet != nil)
    }

    @Test func completedReviewPreservesEditsAndNeverReenrollsOrReopensReview() async throws {
        let audit = Audit()
        let edited = RichTranscript(segments: [], speakerLabels: [.init(id: "Speaker 1", displayName: "Edited")])
        let held = try await ProcessingPipeline().prepareSpeakers(request(reviewed: true, required: true), steps: steps(audit, existing: edited))
        let published = await audit.rich
        #expect(!held && published == edited)
        #expect(await audit.calls == ["library", "loadRequired", "publish", "checkpoint", "complete"])
    }

    @Test func persistedNoReviewDecisionEnrollsOnlyAfterDiarizedCheckpoint() async throws {
        let audit = Audit()
        #expect(try await !ProcessingPipeline().prepareSpeakers(request(required: false), steps: steps(audit)))
        #expect(await audit.calls == ["library", "load", "save", "publish", "checkpoint", "enroll:Alice", "complete"])
    }

    @Test(arguments: ["load", "checkpoint", "enroll"])
    func failuresPreventSubsequentReviewAndEnrollment(boundary: String) async throws {
        let audit = Audit()
        var actions = steps(audit)
        switch boundary {
        case "load": actions.loadTranscript = { _ in throw TranscriptStoreError.unsupportedVersion(99) }
        case "checkpoint": actions.checkpointDiarized = { _ in throw CocoaError(.fileWriteOutOfSpace) }
        default: actions.enroll = { _ in throw CancellationError() }
        }
        await #expect(throws: (any Error).self) {
            _ = try await ProcessingPipeline().prepareSpeakers(request(required: false), steps: actions)
        }
        let calls = await audit.calls
        #expect(!calls.contains("hold") && !calls.contains("complete"))
        if boundary == "load" { #expect(!calls.contains("save") && !calls.contains("publish")) }
    }

    @Test(arguments: ["library", "load", "save", "publish", "checkpoint", "hold", "enroll"])
    func cancellationPreventsTheNextEffect(boundary: String) async throws {
        let audit = Audit()
        var actions = steps(audit)
        switch boundary {
        case "library": actions.loadLibrary = { withUnsafeCurrentTask { $0?.cancel() }; return VoiceLibrary() }
        case "load": actions.loadTranscript = { _ in withUnsafeCurrentTask { $0?.cancel() }; return nil }
        case "save": actions.saveTranscript = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        case "publish": actions.publishTranscript = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        case "checkpoint": actions.checkpointDiarized = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        case "hold": actions.holdReview = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        default: actions.enroll = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        let input = actions
        let task = Task { try await ProcessingPipeline().prepareSpeakers(request(required: boundary == "hold"), steps: input) }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let calls = await audit.calls
        #expect(!calls.contains("complete") && !calls.contains("hold") && !calls.contains("enroll:Alice"))
    }

    @Test func lostOwnershipAfterSavePreventsPublication() async throws {
        let audit = Audit()
        var actions = steps(audit)
        actions.validateOwnership = {
            if (await audit.calls).contains("save") { throw CancellationError() }
        }
        await #expect(throws: CancellationError.self) {
            _ = try await ProcessingPipeline().prepareSpeakers(request(), steps: actions)
        }
        #expect(await audit.calls == ["library", "load", "save"])
    }

    @Test func requiredMissingTranscriptCannotBeRebuilt() async throws {
        let audit = Audit()
        await #expect(throws: TranscriptStoreError.self) {
            _ = try await ProcessingPipeline().prepareSpeakers(request(reviewed: true), steps: steps(audit))
        }
        #expect(await audit.calls == ["library", "loadRequired"])
    }

    @Test func replacementDuringSuspendedCheckpointDoesNotOpenReviewOrEnroll() async throws {
        let audit = Audit()
        let gate = CheckpointGate()
        var actions = steps(audit)
        actions.checkpointDiarized = { _ in await gate.checkpoint() }
        actions.validateOwnership = { if !(await gate.owned) { throw CancellationError() } }
        let input = actions
        let task = Task { try await ProcessingPipeline().prepareSpeakers(request(required: true), steps: input) }
        await gate.waitUntilEntered()
        await gate.replaceOwnerAndRelease()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await audit.calls == ["library", "load", "save", "publish"])
    }

    @Test(arguments: [true, false])
    func voiceLibraryMatchesRespectRosterAndSuppressOrdinalGuess(onRoster: Bool) async throws {
        let audit = Audit()
        var actions = steps(audit)
        actions.loadLibrary = {
            VoiceLibrary(people: [.init(id: "known", name: onRoster ? "Alice" : "Bob",
                voiceprints: [.init(embedding: [1, 0], model: "fixture", capturedAt: Date())])])
        }
        // A nonempty library triggers confirm-first even for one speaker.
        #expect(try await ProcessingPipeline().prepareSpeakers(request(), steps: actions))
        let item = try #require(await audit.items.first)
        #expect(item.proposedName == (onRoster ? "Alice" : "Speaker 1"))
        #expect(item.personId == (onRoster ? "known" : nil))
        #expect(item.reason == (onRoster ? .matched : .offRoster))
    }

    @Test @MainActor func privacyScopeSurvivesActorWorkAndMainActorCallbacks() async throws {
        let audit = Audit()
        let context = PrivacyTrace.Context(receiptURL: URL(fileURLWithPath: "/synthetic/speakers.privacy.json"), recordingID: UUID())
        var actions = steps(audit)
        actions.loadLibrary = {
            expectBackgroundScope(context)
            return VoiceLibrary()
        }
        actions.saveTranscript = { _ in
            expectBackgroundScope(context)
        }
        actions.publishTranscript = { @MainActor rich in
            MainActor.preconditionIsolated()
            #expect(PrivacyTrace.context?.runID == context.runID)
            #expect(rich.speakerLabels.first?.displayName == "Alice")
        }
        actions.holdReview = { @MainActor _ in
            MainActor.preconditionIsolated()
            #expect(PrivacyTrace.context?.recordingID == context.recordingID)
        }
        let input = actions
        let held = try await PrivacyTrace.$context.withValue(context) {
            try await ProcessingPipeline().prepareSpeakers(request(required: true), steps: input)
        }
        #expect(held)
    }
}
