import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Processing speaker review")
struct ProcessingReviewTests {
    private actor Audit {
        var calls: [String] = []
        var transcript: RichTranscript?
        func add(_ call: String) { calls.append(call) }
        func publish(_ rich: RichTranscript) { calls.append("publish"); transcript = rich }
    }
    private var rich: RichTranscript {
        .init(segments: [.init(start: 0, end: 3, text: "Edited words", originalText: "Original", speakerId: "Speaker 1")],
              speakerLabels: [.init(id: "Speaker 1", displayName: "Old name")])
    }
    private var edits: [String: ConfirmedSpeaker] { ["Speaker 1": .init(name: " Alice ", personId: "person")] }
    private func steps(_ audit: Audit) -> ProcessingPipeline.ReviewConfirmationSteps {
        .init(loadTranscript: { await audit.add("load"); return rich },
              save: { _, _ in await audit.add("save") }, publish: { await audit.publish($0) },
              loadEmbeddings: { await audit.add("embeddings"); return ["Speaker 1": [1, 0]] },
              enroll: { await audit.add("enroll:\($0.name)") })
    }
    @Test func confirmationSavesBeforePublicationAndEnrollment() async throws {
        let audit = Audit()
        try await ProcessingPipeline().confirmSpeakers(edits, transcript: nil, steps: steps(audit))
        #expect(await audit.calls == ["load", "save", "publish", "embeddings", "enroll:Alice"])
        let saved = try #require(await audit.transcript)
        #expect(saved.segments.first?.text == "Edited words")
        #expect(saved.speakerLabels.first?.displayName == "Alice" && saved.speakerLabels.first?.personId == "person")
    }
    @Test func saveFailureDoesNotPublishOrEnroll() async throws {
        let audit = Audit()
        var input = steps(audit)
        input.save = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        await #expect(throws: CocoaError.self) {
            try await ProcessingPipeline().confirmSpeakers(edits, transcript: rich, steps: input)
        }
        #expect(await audit.calls.isEmpty)
    }
    @Test func blankAndPlaceholderNamesDoNotLoadEmbeddings() async throws {
        let audit = Audit()
        try await ProcessingPipeline().confirmSpeakers(["Speaker 1": .init(name: " ", personId: nil), "Speaker 2": .init(name: "Speaker 2", personId: nil)],
            transcript: rich, steps: steps(audit))
        #expect(await audit.calls == ["save", "publish"])
        #expect(await audit.transcript?.speakerLabels.first?.displayName == "Old name")
    }
    @Test(arguments: ["load", "save", "publish", "embeddings", "enroll"])
    func cancellationStopsConfirmationAtEachBoundary(boundary: String) async throws {
        let audit = Audit()
        var input = steps(audit)
        switch boundary {
        case "load": input.loadTranscript = { withUnsafeCurrentTask { $0?.cancel() }; return rich }
        case "save": input.save = { _, _ in withUnsafeCurrentTask { $0?.cancel() } }
        case "publish": input.publish = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        case "embeddings": input.loadEmbeddings = { withUnsafeCurrentTask { $0?.cancel() }; return [:] }
        default: input.enroll = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        let actions = input
        let task = Task { try await ProcessingPipeline().confirmSpeakers(edits, transcript: nil, steps: actions) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!(await audit.calls).contains("enroll:Alice"))
    }
    @Test func replacementAfterSavePreventsPublication() async throws {
        let audit = Audit()
        var input = steps(audit)
        input.validateOwnership = { if (await audit.calls).contains("save") { throw CancellationError() } }
        await #expect(throws: CancellationError.self) {
            try await ProcessingPipeline().confirmSpeakers(edits, transcript: rich, steps: input)
        }
        #expect(await audit.calls == ["save"])
    }

    private func rediarization(mode: AppSettings.SpeakerIdMode = .confirmFirst) -> ProcessingPipeline.RediarizationReviewRequest {
        .init(turns: [.init(speakerId: "Speaker 2", start: 0, end: 3)], embeddings: ["Speaker 2": [1, 0]],
              transcript: rich, mode: mode, roster: ["Alice"])
    }
    private var library: VoiceLibrary {
        .init(people: [.init(id: "person", name: "Alice", voiceprints: [.init(embedding: [1, 0], model: "fixture", capturedAt: Date())])])
    }
    @Test func rediarizationSavesResolvedNamesBeforeReturningReview() async throws {
        let audit = Audit()
        let result = try #require(try await ProcessingPipeline().prepareRediarizationReview(rediarization(), loadLibrary: { library }, save: {
            await audit.publish($0)
        }))
        #expect(result.transcript.segments.first?.text == "Edited words")
        #expect(result.transcript.segments.first?.speakerId == "Speaker 2")
        #expect(result.items.first?.proposedName == "Alice" && result.items.first?.personId == "person")
        #expect(await audit.transcript == result.transcript)
    }
    @Test func declinedGateDoesNotSaveOrProposeReview() async throws {
        let result = try await ProcessingPipeline().prepareRediarizationReview(rediarization(mode: .optimistic), loadLibrary: { library }, save: { _ in
            Issue.record("Declined gate saved a transcript")
        })
        #expect(result == nil)
    }
    @Test func rediarizationSaveFailureCannotReturnReview() async throws {
        await #expect(throws: CocoaError.self) {
            _ = try await ProcessingPipeline().prepareRediarizationReview(rediarization(), loadLibrary: { library }, save: { _ in
                throw CocoaError(.fileWriteOutOfSpace)
            })
        }
    }
    @Test func rediarizationOwnershipLossAfterSaveCannotReturnReview() async throws {
        let audit = Audit()
        await #expect(throws: CancellationError.self) {
            _ = try await ProcessingPipeline().prepareRediarizationReview(rediarization(), loadLibrary: { library }, save: { _ in
                await audit.add("save")
            }, validateOwnership: { if (await audit.calls).contains("save") { throw CancellationError() } })
        }
    }

    @Test func confirmationCarriesOriginalSnapshotAndUsesReviewedEmbeddings() async throws {
        let audit = Audit()
        let source = rich
        var input = steps(audit)
        input.save = { updated, original in
            #expect(original == source)
            #expect(updated.speakerLabels.first?.displayName == "Alice")
        }
        input.loadEmbeddings = { ["Speaker 1": [0, 1]] }
        input.enroll = { entry in
            #expect(entry.name == "Alice" && entry.embedding == [0, 1])
            await audit.add("reviewedEmbedding")
        }
        try await ProcessingPipeline().confirmSpeakers(edits, transcript: source, steps: input)
        #expect(await audit.calls.last == "reviewedEmbedding")
    }

    @Test(arguments: [false, true])
    func rediarizationCancellationNeverReturnsAReview(afterSave: Bool) async throws {
        let task = Task {
            try await ProcessingPipeline().prepareRediarizationReview(rediarization(), loadLibrary: {
                if !afterSave { withUnsafeCurrentTask { $0?.cancel() } }
                return library
            }, save: { _ in withUnsafeCurrentTask { $0?.cancel() } })
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    private func checkBackgroundScope(_ context: PrivacyTrace.Context) {
        #expect(!Thread.isMainThread)
        #expect(PrivacyTrace.context?.runID == context.runID)
    }

    @Test @MainActor func confirmationReentersStoreWithOwnedCallbacksAndPrivacyScope() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("richtranscript.json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TranscriptStore()
        try await store.save(rich, to: url)
        let context = PrivacyTrace.Context(receiptURL: url.appendingPathExtension("privacy.json"), recordingID: UUID())
        let audit = Audit()
        var input = steps(audit)
        input.loadTranscript = {
            let saved = try await store.load(from: url)
            checkBackgroundScope(context)
            return saved
        }
        input.save = { @MainActor updated, original in
            MainActor.preconditionIsolated()
            #expect(PrivacyTrace.context?.runID == context.runID)
            try await store.save(updated, to: url, replacing: original)
        }
        input.publish = { @MainActor updated in
            MainActor.preconditionIsolated()
            #expect(PrivacyTrace.context?.recordingID == context.recordingID)
            let saved = try await store.load(from: url)
            #expect(saved == updated)
        }
        let actions = input
        try await PrivacyTrace.$context.withValue(context) {
            try await ProcessingPipeline().confirmSpeakers(edits, transcript: nil, steps: actions)
        }
        #expect(try await store.load(from: url).speakerLabels.first?.displayName == "Alice")
    }

    @Test @MainActor func changedReviewInputKeepsOwnershipOfItsFailurePath() throws {
        let recording = Recording(fileURL: URL(fileURLWithPath: "/synthetic/review.wav"), duration: 3)
        recording.richTranscript = rich
        let job = ProcessingJob(recording: recording)
        let operation = RecordingManager.ReviewOperation(recording: recording, job: job)
        recording.richTranscript?.segments[0].text = "Later viewer edit"
        #expect(throws: TranscriptStoreError.self) { try operation.validateSnapshot() }
        #expect(operation.ownsLifecycle(current: operation, activeJob: job, pendingReview: nil))
        let replacement = ProcessingJob(recording: recording)
        #expect(!operation.ownsLifecycle(current: operation, activeJob: replacement, pendingReview: nil))
    }

    @Test @MainActor func newerReviewOperationOwnsContinuationAndOldWorkCannotRetireIt() {
        let recording = Recording(fileURL: URL(fileURLWithPath: "/synthetic/review.wav"), duration: 3)
        let old = RecordingManager.ReviewOperation(recording: recording, job: nil)
        let current = RecordingManager.ReviewOperation(recording: recording, job: nil)
        #expect(current.ownsLifecycle(current: current, activeJob: nil, pendingReview: nil))
        #expect(!old.ownsLifecycle(current: current, activeJob: nil, pendingReview: nil))
    }
}
