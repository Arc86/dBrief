import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Processing model provenance")
struct ProcessingModelProvenanceTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-provenance-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func transcript(model: String? = "asr-A") -> TranscriptionResult {
        .init(text: "service now", segments: [.init(start: 0, end: 1, text: "service now", speaker: "Speaker 1")],
              language: "en", modelName: model)
    }
    private func insights(model: String? = "ai-A") -> RecordingInsights {
        .init(summary: "Summary", actionItems: ["Do it"], tags: [], sentiment: "Positive", markdownPath: nil,
              modelProvenance: .init(summary: model, actionItems: model, tags: model))
    }

    @Test func freshSegmentedTranscriptCarriesFrozenModelThroughCorrectionAndRecovery() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = ProcessingPipeline(duration: { _ in 1 })
        let result = try await pipeline.transcribe(.init(audioURL: root.appendingPathComponent("master.wav"),
            segmentURLs: [root.appendingPathComponent("part1.wav"), root.appendingPathComponent("part2.wav")]),
            options: .init(removeFillerWords: false, ignoredSegments: [], modelName: "asr-A"),
            using: { _ in transcript(model: nil) }, correct: { result in
                // Correction is a separate model and cannot relabel the ASR pass.
                var copy = result; copy.modelName = "speller-B"; return copy
            })
        #expect(result.transcription.modelName == "asr-A")
        let raw = root.appendingPathComponent("master.transcript.json")
        try await pipeline.saveTranscript(result.transcription, to: raw)
        let recovered = try await ProcessingPipeline().recoverInputs(.init(mode: .aiRetry,
            transcriptURL: raw, richTranscriptURL: nil, transcription: nil, richTranscript: nil),
            loadRich: { _ in throw CocoaError(.fileNoSuchFile) })
        #expect(recovered?.transcription.modelName == "asr-A")
    }

    @Test func legacySidecarsRemainUnknown() throws {
        let raw = try JSONDecoder().decode(TranscriptionResult.self, from: Data(#"{"text":"old","segments":[]}"#.utf8))
        let saved = try JSONDecoder().decode(RecordingInsights.self,
            from: Data(#"{"version":1,"summary":"old","actionItems":[],"tags":[],"sentiment":""}"#.utf8))
        #expect(raw.modelName == nil)
        #expect(saved.modelProvenance == nil)
    }

    @Test(arguments: [false, true]) func textAndSpeakerTransformsPreserveASROrigin(withWords: Bool) {
        let input = TranscriptionResult(text: "service now", segments: [.init(start: 0, end: 1, text: "service now",
            words: withWords ? [.init(word: "service", start: 0, end: 0.4), .init(word: "now", start: 0.4, end: 1)] : nil,
            speaker: "Speaker 1")], modelName: "asr-A")
        let cleaned = TranscriptCleanup.clean(input, removeFillerWords: false, ignoredSegments: [])
        let corrected = VocabularyCorrection.apply([.init(from: "service now", to: "ServiceNow")],
            vocabulary: ["ServiceNow"], to: cleaned)
        #expect(cleaned.modelName == "asr-A")
        #expect(corrected.modelName == "asr-A")
        let turns = [DiarizedTurn(speakerId: "Speaker 2", start: 0, end: 1)]
        #expect(SpeakerMerge.merge(corrected, turns: turns).modelName == "asr-A")
        #expect(SpeakerMerge.mergePreservingSegments(corrected, turns: turns).modelName == "asr-A")
    }

    @Test func remoteModelIdentityMatchesSentDefaultsAndUnknownServerChoice() {
        let deepgram = Endpoint(name: "Fixture", baseURL: "https://fixture.invalid", modelName: "", provider: .deepgram)
        let eleven = Endpoint(name: "Fixture", baseURL: "https://fixture.invalid", modelName: "", provider: .elevenLabs)
        let server = Endpoint(name: "Fixture", baseURL: "https://fixture.invalid/asr", modelName: "unused-client-model")
        #expect(TranscriptionService.modelName(for: deepgram) == "nova-3")
        #expect(TranscriptionService.modelName(for: eleven) == "scribe_v1")
        #expect(server.isWhisperASR)
        #expect(TranscriptionService.modelName(for: server) == nil)
        #expect(TranscriptionService.modelName(for: .init(name: "Fixture", baseURL: "https://fixture.invalid/v1",
                                                         modelName: "configured-model")) == "configured-model")
    }

    @Test @MainActor func parakeetSnapshotLabelsTheLoadedVariantAndStaysFrozen() {
        let settings = AppSettings()
        let savedProfiles = settings.profiles
        let savedVariant = settings.parakeetModelVariant
        defer {
            settings.profiles = savedProfiles
            settings.parakeetModelVariant = savedVariant
        }
        var profile = MeetingProfile(name: "Parakeet provenance fixture")
        profile.overrides.transcriptionEngine = .parakeetLocal
        settings.profiles = [profile]
        for variant in ["v2", "v3", "obsolete-variant", ""] {
            settings.parakeetModelVariant = variant
            let snapshot = ProcessingPipeline.TranscriptionSettings(settings: settings)
            // The backend selects v2 only for that exact value, otherwise v3.
            let expected = variant == "v2" ? "v2 (CoreML)" : "v3 (CoreML)"
            settings.parakeetModelVariant = variant == "v2" ? "v3" : "v2"
            #expect(snapshot.modelName == expected)
            #expect(snapshot.cleanup.modelName == expected)
            #expect(snapshot.parakeetModelVariant == variant)
        }
    }

    @Test func consensusRequiresKnownOriginsForEveryPresentFieldIncludingSentiment() {
        let same = insights()
        #expect(same.modelProvenance?.modelName(summary: same.summary, actionItems: same.actionItems,
                                               tags: same.tags, sentiment: same.sentiment) == "ai-A")
        var mixed = same; mixed.modelProvenance?.summary = "ai-B"
        #expect(mixed.modelProvenance?.modelName(summary: mixed.summary, actionItems: mixed.actionItems,
                                                tags: mixed.tags, sentiment: mixed.sentiment) == nil)
        let partial = AnalysisModelProvenance(summary: "ai-A", actionItems: nil, tags: nil)
        #expect(partial.modelName(summary: "Summary", actionItems: [], tags: [], sentiment: "") == "ai-A")
        #expect(partial.modelName(summary: "Summary", actionItems: [], tags: [], sentiment: "Positive") == nil)
        #expect(partial.modelName(summary: "", actionItems: [], tags: [], sentiment: "") == nil)
    }

    @Test @MainActor func successfulFieldsReplaceOriginWhileFailuresAndUnknownModelsDoNotInventIt() {
        let recording = Recording(fileURL: URL(fileURLWithPath: "/tmp/synthetic-analysis.wav"))
        recording.applyAnalysisField(.summary("Original"), modelName: "ai-A")
        recording.applyAnalysisField(.actionItems(["Original action"]), modelName: "ai-A")
        recording.applyAnalysisField(.tags([], "Positive"), modelName: "ai-A")
        recording.applyAnalysisField(.summary("New summary"), modelName: "ai-B")
        recording.applyAnalysisField(.failed(.actionItems, "Synthetic failure"), modelName: "ai-B")
        #expect(recording.summary == "New summary")
        #expect(recording.actionItems == ["Original action"])
        #expect(recording.analysisModelProvenance == .init(summary: "ai-B", actionItems: "ai-A", tags: "ai-A"))
        recording.applyAnalysisField(.summary("Server chose model"), modelName: nil)
        #expect(recording.analysisModelProvenance?.summary == nil)
        #expect(recording.analysisModelProvenance?.actionItems == "ai-A")
        recording.applyAnalysisField(.actionItems([]), modelName: "ai-B")
        #expect(recording.actionItems == [])
        #expect(recording.analysisModelProvenance?.actionItems == "ai-B")
    }

    @Test @MainActor func modelStringsCannotBreakYamlScalars() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let recording = Recording(fileURL: root.appendingPathComponent("audio.wav"))
        recording.transcription = transcript(model: "model\"\nextra: fake")
        let text = MarkdownGenerator().prepare(recording: recording, outputFolder: root).content
        #expect(text.contains("transcription_model: \"model\\\"\\nextra: fake\""))
        #expect(!text.contains("\nextra: fake"))
    }

    @Test func editingCompletionAndExportLinksRetainGenerationOrigins() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("saved.insights.json")
        let store = InsightsStore()
        try await store.save(insights(), to: url)
        var loaded = try #require(try await InsightsStore().load(from: url))
        loaded.summary = "User-edited summary"
        try await store.save(loaded, to: url)
        _ = try await store.setActionCompleted("Do it", completed: true, at: url)
        try await store.setExportLink(root.appendingPathComponent("export.md"), generatedTitle: "Title", at: url)
        let final = try #require(try await InsightsStore().load(from: url))
        #expect(final.modelProvenance == insights().modelProvenance)
        #expect(final.summary == "User-edited summary")
        #expect(final.completedActions == ["Do it"])
    }

    @Test @MainActor func exportUsesRestoredStageOriginsAndRetryReplacesOnlyAIOrigin() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("master.transcript.json")
        let saved = root.appendingPathComponent("master.insights.json")
        let pipeline = ProcessingPipeline()
        try await pipeline.saveTranscript(transcript(), to: raw)
        try await pipeline.saveAnalysis(insights(), to: saved, store: InsightsStore())
        let restored = try await pipeline.restoreAnalysis(from: saved, required: true, adoptLegacyMarkdown: false,
                                                         insightsStore: InsightsStore(), markdownStore: MarkdownOutputStore())
        let recording = Recording(fileURL: root.appendingPathComponent("master.wav"))
        recording.transcription = try await pipeline.loadTranscript(from: raw)
        let output = try #require(restored.insights)
        recording.summary = output.summary; recording.actionItems = output.actionItems
        recording.tags = output.tags; recording.sentiment = output.sentiment
        recording.analysisModelProvenance = output.modelProvenance
        func render() -> String {
            MarkdownGenerator().prepare(recording: recording, outputFolder: root).content
        }
        let first = render()
        #expect(first.contains("transcription_model: \"asr-A\""))
        #expect(first.contains("ai_model: \"ai-A\""))
        // A new analysis run replaces AI results, but does not retranscribe.
        recording.analysisModelProvenance = .init(summary: "ai-B", actionItems: "ai-B", tags: "ai-B")
        let retried = render()
        #expect(retried.contains("transcription_model: \"asr-A\""))
        #expect(retried.contains("ai_model: \"ai-B\""))
        recording.transcription?.modelName = nil
        recording.analysisModelProvenance = nil
        let legacy = render()
        #expect(!legacy.contains("transcription_model:"))
        #expect(!legacy.contains("ai_model:"))
    }

    @Test @MainActor func frozenPlanPreservesExistingModelMetadataAndUserEdits() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("original.md")
        let edited = "---\nai_model: retained-old-model\n---\nUser edited note"
        try edited.write(to: url, atomically: true, encoding: .utf8)
        let plan = MarkdownExportPlan(destination: url, content: "Original", generatedTitle: nil)
        let recording = Recording(fileURL: root.appendingPathComponent("master.wav"))
        recording.transcription = transcript(model: "new-model")
        let result = try await ProcessingPipeline().publishMarkdown(.init(snapshot: .init(recording: recording),
            outputFolder: root, includeTranscript: false,
            mode: .restartable(jobID: UUID(), savedPlan: plan, alreadyCompleted: true)),
            store: MarkdownOutputStore(), savePlan: { _ in Issue.record("Frozen plan must not be replaced") })
        #expect(try String(contentsOf: result.url, encoding: .utf8) == edited)
    }
}
