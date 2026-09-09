import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Processing recovery inputs")
struct ProcessingRecoveryInputTests {
    private let rawURL = URL(fileURLWithPath: "/synthetic/raw.json")
    private let richURL = URL(fileURLWithPath: "/synthetic/rich.json")
    private var raw: TranscriptionResult { .init(text: "Saved words", segments: []) }
    private var rich: RichTranscript { .init(segments: [], speakerLabels: [.init(id: "Speaker 1", displayName: "Edited name")]) }
    private func request(_ mode: ProcessingPipeline.RecoveryInputMode,
                         raw: TranscriptionResult? = nil, rich: RichTranscript? = nil) -> ProcessingPipeline.RecoveryInputRequest {
        .init(mode: mode, transcriptURL: rawURL, richTranscriptURL: richURL, transcription: raw, richTranscript: rich)
    }
    private func pipeline() throws -> ProcessingPipeline {
        let bytes = try JSONEncoder().encode(raw)
        return ProcessingPipeline(transcriptFiles: .init(read: { url in
            #expect(url == rawURL)
            return bytes
        }, write: { _, _ in Issue.record("Recovery must not write raw transcripts") }))
    }

    @Test(arguments: [true, false])
    func frozenOrUnrequestedExportDoesNotReadAnyTranscript(frozen: Bool) async throws {
        let pipeline = ProcessingPipeline(transcriptFiles: .init(read: { _ in
            Issue.record("Bypassed export read raw input"); throw CancellationError()
        }))
        let input = request(.export(hasFrozenPlan: frozen, transcribe: frozen))
        try input.validatePaths(transcriptURL: nil, richTranscriptURL: nil)
        let result = try await pipeline.recoverInputs(input, loadRich: { _ in
            Issue.record("Bypassed export read rich input"); throw CancellationError()
        })
        #expect(result == nil)
    }

    @Test func exportRequiresBothCanonicalTranscriptsAndPreservesReviewedLabels() async throws {
        let result = try #require(try await pipeline().recoverInputs(request(.export(hasFrozenPlan: false, transcribe: true)), loadRich: { url in
            #expect(url == richURL)
            return rich
        }))
        #expect(result.transcription.text == "Saved words")
        #expect(result.richTranscript == rich && result.loadedTranscriptURL == rawURL)
    }

    @Test(arguments: [false, true])
    func missingOrCorruptRawStopsBeforeRichRead(corrupt: Bool) async throws {
        let pipeline = ProcessingPipeline(transcriptFiles: .init(read: { _ in
            if corrupt { return Data("not JSON".utf8) }
            throw CocoaError(.fileReadNoSuchFile)
        }))
        await #expect(throws: TranscriptStoreError.self) {
            _ = try await pipeline.recoverInputs(request(.export(hasFrozenPlan: false, transcribe: true)), loadRich: { _ in
                Issue.record("Rich load followed unavailable raw input"); return rich
            })
        }
    }

    @Test func exportRejectsRichLoadFailureInsteadOfRebuilding() async throws {
        await #expect(throws: TranscriptStoreError.self) {
            _ = try await pipeline().recoverInputs(request(.export(hasFrozenPlan: false, transcribe: true)), loadRich: { _ in
                throw TranscriptStoreError.unsupportedVersion(99)
            })
        }
    }

    @Test func retryReusesMemoryWithoutReadingSidecars() async throws {
        let pipeline = ProcessingPipeline(transcriptFiles: .init(read: { _ in
            Issue.record("Read despite in-memory raw transcript"); throw CancellationError()
        }))
        let input = request(.aiRetry, raw: raw, rich: rich)
        try input.validatePaths(transcriptURL: nil, richTranscriptURL: nil)
        let result = try #require(try await pipeline.recoverInputs(input, loadRich: { _ in
            Issue.record("Read despite in-memory rich transcript"); throw CancellationError()
        }))
        #expect(result.transcription.text == raw.text && result.richTranscript == rich)
        #expect(result.loadedTranscriptURL == nil)
    }

    @Test func retryRetainsBestEffortRichLoading() async throws {
        let result = try #require(try await pipeline().recoverInputs(request(.aiRetry), loadRich: { _ in
            throw TranscriptStoreError.unsupportedVersion(99)
        }))
        #expect(result.transcription.text == raw.text && result.richTranscript == nil)
    }

    @Test(arguments: [false, true])
    func cancellationAfterRichReadCannotReturnInputs(retry: Bool) async throws {
        let pipeline = try pipeline()
        let input = request(retry ? .aiRetry : .export(hasFrozenPlan: false, transcribe: true))
        let task = Task {
            try await pipeline.recoverInputs(input, loadRich: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                if retry { throw CocoaError(.fileReadUnknown) }
                return rich
            })
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    private actor Ownership {
        var active = true
        func replace() { active = false }
    }
    @Test func ownershipLossDuringBestEffortReadIsNotSwallowed() async throws {
        let owner = Ownership()
        await #expect(throws: CancellationError.self) {
            _ = try await pipeline().recoverInputs(request(.aiRetry), loadRich: { _ in
                await owner.replace()
                throw CocoaError(.fileReadUnknown)
            }, validateOwnership: { if !(await owner.active) { throw CancellationError() } })
        }
    }

    @Test func changedRequiredPathsRejectStaleSnapshots() throws {
        let export = request(.export(hasFrozenPlan: false, transcribe: true))
        #expect(throws: CancellationError.self) { try export.validatePaths(transcriptURL: nil, richTranscriptURL: richURL) }
        #expect(throws: CancellationError.self) { try export.validatePaths(transcriptURL: rawURL, richTranscriptURL: nil) }
        let retry = request(.aiRetry, raw: raw)
        try retry.validatePaths(transcriptURL: nil, richTranscriptURL: richURL)
        #expect(throws: CancellationError.self) { try retry.validatePaths(transcriptURL: nil, richTranscriptURL: nil) }
    }

    private func checkBackgroundScope(_ context: PrivacyTrace.Context) {
        #expect(!Thread.isMainThread)
        #expect(PrivacyTrace.context?.runID == context.runID)
    }

    @Test @MainActor func recoveryReadsKeepPrivacyScopeAcrossOwnedUICallbacks() async throws {
        let context = PrivacyTrace.Context(receiptURL: URL(fileURLWithPath: "/synthetic/privacy.json"), recordingID: UUID())
        let bytes = try JSONEncoder().encode(raw)
        let pipeline = ProcessingPipeline(transcriptFiles: .init(read: { _ in
            checkBackgroundScope(context)
            return bytes
        }))
        let result = try await PrivacyTrace.$context.withValue(context) {
            try await pipeline.recoverInputs(request(.export(hasFrozenPlan: false, transcribe: true)), loadRich: { _ in
                checkBackgroundScope(context)
                return rich
            }, validateOwnership: { @MainActor in
                MainActor.preconditionIsolated()
                #expect(PrivacyTrace.context?.recordingID == context.recordingID)
            })
        }
        #expect(result?.transcription.text == raw.text && result?.richTranscript == rich)
    }
}
