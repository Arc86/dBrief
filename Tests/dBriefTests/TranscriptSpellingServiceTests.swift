import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Transcript spelling execution")
struct TranscriptSpellingServiceTests {
    private func input() -> TranscriptionResult {
        .init(text: "service now and ordinary words", segments: [
            .init(start: 0, end: 2, text: "service now and ordinary words")
        ], diarizationTime: 1.5, speakerEmbeddings: ["Speaker 1": [0.1, 0.2]])
    }
    private func bytes(_ result: TranscriptionResult) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(result)
    }
    private var request: TranscriptSpellingService.Request {
        .init(terms: ["ServiceNow"], engine: .remoteEndpoint,
              endpoint: .init(name: "Fixture", baseURL: "https://fixture.invalid", modelName: "fixture"))
    }

    @Test @MainActor func actorRewritesOffMainAndRetainsPrivacyAndTiming() async throws {
        let context = PrivacyTrace.Context(receiptURL: URL(fileURLWithPath: "/tmp/synthetic-spelling.privacy.json"), recordingID: UUID())
        let frozen = request
        let service = TranscriptSpellingService(backend: { request, system, user in
            #expect(request.terms == frozen.terms)
            #expect(request.endpoint == frozen.endpoint)
            #expect(system.contains("JSON array"))
            #expect(user.contains("DOMAIN TERMS:\nServiceNow"))
            #expect(user.contains("service now and ordinary words"))
            #expect(PrivacyTrace.context?.runID == context.runID)
            return #"[{"from":"service now","to":"ServiceNow"},{"from":"ordinary","to":"unapproved"}]"#
        }, apply: { corrections, vocabulary, result in
            #expect(!Thread.isMainThread)
            #expect(PrivacyTrace.context?.runID == context.runID)
            return VocabularyCorrection.apply(corrections, vocabulary: vocabulary, to: result)
        })
        let correction = await PrivacyTrace.$context.withValue(context) { await service.correct(input(), request: frozen) }
        let result = correction.result
        #expect(correction.outcome == .corrected(2))
        #expect(correction.outcome.warning == nil)
        #expect(result.text == "ServiceNow and ordinary words")
        #expect(result.segments.first?.text == result.text)
        #expect(result.diarizationTime == 1.5)
        #expect(result.speakerEmbeddings == ["Speaker 1": [0.1, 0.2]])
    }

    @Test(arguments: [false, true]) func cancelledCorrectionDoesNotApplyBackendResult(cancelBeforeCall: Bool) async throws {
        let service = TranscriptSpellingService(backend: { _, _, _ in
            #expect(!cancelBeforeCall)
            withUnsafeCurrentTask { $0?.cancel() }
            return #"[{"from":"service now","to":"ServiceNow"}]"#
        }, apply: { _, _, original in
            Issue.record("Cancelled correction must not rewrite the transcript")
            return original
        })
        let original = input(), frozen = request
        let task = Task {
            if cancelBeforeCall { withUnsafeCurrentTask { $0?.cancel() } }
            return await service.correct(original, request: frozen)
        }
        let correction = await task.value
        #expect(try bytes(correction.result) == bytes(original))
        #expect(correction.outcome == .cancelled)
        #expect(correction.outcome.warning == nil)
    }

    @Test(arguments: [("", TranscriptSpellingService.Outcome.skipped(.unreadableAnswer)),
                      ("not JSON", .skipped(.unreadableAnswer)),
                      ("[]", .unchanged)])
    func invalidResponsesPreserveOriginal(raw: String, expected: TranscriptSpellingService.Outcome) async throws {
        let service = TranscriptSpellingService(backend: { _, _, _ in raw }, apply: { _, _, original in
            Issue.record("Empty correction list must not rewrite the transcript")
            return original
        })
        let correction = await service.correct(input(), request: request)
        #expect(try bytes(correction.result) == bytes(input()))
        #expect(correction.outcome == expected)
    }

    @Test func noVocabularyOrBackendFailureIsBestEffort() async throws {
        let original = input()
        let service = TranscriptSpellingService(backend: { request, _, _ in
            #expect(!request.terms.isEmpty)
            throw CocoaError(.fileReadUnknown)
        })
        let noTerms = await service.correct(original, request: .init(terms: [], engine: .localCLI, endpoint: nil))
        #expect(try bytes(noTerms.result) == bytes(original))
        #expect(noTerms.outcome == .notNeeded)
        #expect(noTerms.outcome.warning == nil)
        let failed = await service.correct(original, request: request)
        #expect(try bytes(failed.result) == bytes(original))
        #expect(failed.outcome == .skipped(.engineFailed))
    }

    @Test(arguments: [
        TranscriptSpellingService.Request(terms: ["ServiceNow"], engine: .localCLI, endpoint: nil),
        TranscriptSpellingService.Request(terms: ["ServiceNow"], engine: .remoteEndpoint, endpoint: nil),
    ])
    func missingEngineIsReportedAsSkipped(request: TranscriptSpellingService.Request) async throws {
        let original = input()
        let correction = await TranscriptSpellingService().correct(original, request: request)
        #expect(try bytes(correction.result) == bytes(original))
        #expect(correction.outcome == .skipped(.noEngine))
        #expect(correction.outcome.warning?.contains("no AI engine") == true)
    }

    @Test func everySkipReasonHasAWarningAndOtherOutcomesDoNot() {
        let reasons: [TranscriptSpellingService.SkipReason] = [.noEngine, .engineFailed, .unreadableAnswer]
        for reason in reasons {
            let warning = TranscriptSpellingService.Outcome.skipped(reason).warning
            #expect(warning?.hasPrefix("Vocabulary correction skipped") == true)
        }
        let silent: [TranscriptSpellingService.Outcome] = [.notNeeded, .unchanged, .corrected(1), .cancelled]
        #expect(silent.allSatisfy { $0.warning == nil })
    }

    @Test @MainActor func transcriptionSnapshotKeepsProfileChoiceAcrossSettingsChanges() throws {
        let settings = AppSettings()
        let savedProfiles = settings.profiles
        defer { settings.profiles = savedProfiles }
        var first = MeetingProfile(name: "Frozen transcription fixture")
        first.overrides.transcriptionEngine = .appleSpeech
        first.overrides.transcriptionLanguage = "nl-NL"
        first.overrides.customVocabulary = ["ServiceNow"]
        first.overrides.aiEngine = .appleIntelligence
        settings.profiles = [first]
        let snapshot = ProcessingPipeline.TranscriptionSettings(settings: settings)
        var replacement = first
        replacement.overrides.transcriptionEngine = .remoteEndpoint
        replacement.overrides.transcriptionLanguage = "en-US"
        replacement.overrides.customVocabulary = ["Replacement"]
        replacement.overrides.aiEngine = .qwenLocal
        settings.profiles = [replacement]
        #expect(snapshot.engine == .appleSpeech)
        #expect(snapshot.language == "nl-NL")
        #expect(snapshot.modelDisplayName == "Apple Speech")
        #expect(snapshot.spelling.terms == ["ServiceNow"])
        #expect(snapshot.spelling.engine == .appleIntelligence)
        let next = ProcessingPipeline.TranscriptionSettings(settings: settings)
        #expect(next.engine == .remoteEndpoint)
        #expect(next.language == "en-US")
        #expect(next.spelling.terms == ["Replacement"])
        #expect(next.spelling.engine == .qwenLocal)
    }
}
