import Foundation
import Testing
import dBriefWire
@testable import dBrief

@MainActor @Suite struct LiveFinalPublicationTests {
    private func provider(_ f: LiveArtifactFixture, _ registry: LiveRecordingSessionRegistry) -> TranscriptContextProvider {
        .recording(recordingID: f.identity.recordingID, registry: registry,
            legacy: { .legacy(text: "Unexpected fallback", recordingID: f.identity.recordingID, speakerLabels: []) })
    }

    @Test func heldWriteBindingAndSavedSpeakerRevisionsRetainTheExactLatestPublication() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .sourceTranscript, initiallyEnabled: false)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { try await gate.enter($0) })
        let entry = try registry.registerLegacy(f.identity), owner = entry.artifacts
        registry.startPersistence(f.identity)
        try owner.appendLegacy([.init(start: 0, end: 1, text: "Retained live source")])
        try await owner.flush()
        await gate.arm(); try registry.captureDidClose(f.identity)
        do {
            try await gate.waitForArrival()
            try owner.publishFinal(.init(text: "Raw final source"))
            let raw = try await provider(f, registry).freeze().snapshot()
            let rich = RichTranscript(segments: [.init(start: 1, end: 2, text: "Saved rich source", originalText: "Saved rich source", speakerId: "s")],
                speakerLabels: [.init(id: "s", displayName: "Initial")])
            try await TranscriptStore().save(rich, to: f.root.appendingPathComponent("saved.richtranscript.json"))
            try owner.publishSavedFinal(rich)
            let frozen = provider(f, registry).freeze()
            try owner.bind(to: f.audio)
            var reviewed = rich; reviewed.speakerLabels[0].displayName = "Reviewed"
            let richURL = f.root.appendingPathComponent("saved.richtranscript.json"), store = TranscriptStore()
            try await ProcessingPipeline().confirmSpeakers(["s": .init(name: "Reviewed", personId: nil)], transcript: rich, steps: .init(
                loadTranscript: { try await store.load(from: richURL) },
                save: { updated, original in try await store.save(updated, to: richURL, replacing: original) },
                publish: { @MainActor updated in try owner.publishSavedFinal(updated) }, loadEmbeddings: { [:] }, enroll: { _ in }))
            try owner.publishSavedFinal(reviewed) // Idempotent saved callbacks.
            let latest = try await provider(f, registry).freeze().snapshot()
            #expect(latest.source.publicationID == raw.source.publicationID && latest.source.publicationRevision == 3)
            #expect(try await frozen.snapshot().source.speakerLegend.first?.displayName == "Initial")
            #expect(latest.source.speakerLegend.first?.displayName == "Reviewed" && !owner.isDurable)
            await gate.release(); try await owner.flush()
            let recovered = try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover()
            #expect(recovered.appTranscript?.finalContext() == latest && recovered.audioURL == f.audio.standardizedFileURL)
            #expect(recovered.appTranscript?.legacy?.first?.text == "Retained live source")
            try registry.retire(f.identity)
            await #expect(throws: CancellationError.self) { _ = try await frozen.snapshot() }
        } catch { await gate.release(); owner.retire(); await owner.waitForSubmittedWrites(); throw error }
    }

    @Test func finalAuthorityCannotClaimThatAnOpenNativeCheckpointIsDurableOrEvictable() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root), entry = try registry.register(f.identity)
        do {
        registry.startPersistence(f.identity); try registry.captureDidClose(f.identity)
        try entry.artifacts.publishFinal(.init(text: "Final source saved after hardware closure"))
        try await f.eventually {
            let restored = try? await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover().appTranscript
            return restored?.finalPublication != nil
        }
        #expect(!entry.artifacts.isDurable && !entry.artifacts.canEvict)
        #expect(await entry.store.projection().isClosed == false)
        #expect(try await provider(f, registry).freeze().snapshot().source.version == .final)
        #expect(await entry.store.close(owner: f.identity) == .accepted)
        try await f.eventually { await MainActor.run { entry.artifacts.isDurable } }
        let recovered = try #require(try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover().appTranscript)
        #expect(recovered.native == (await entry.store.checkpoint()) && recovered.finalPublication?.fallbackText == "Final source saved after hardware closure")
        #expect(entry.artifacts.canEvict)
        try registry.retire(f.identity); await entry.artifacts.waitForSubmittedWrites()
        } catch { try? registry.retire(f.identity); await entry.artifacts.waitForSubmittedWrites(); throw error }
    }

    @Test func oversizedCompletePublicationAndAFullOrderedQueuePreserveThePreviouslyAcceptedSource() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let gate = LiveArtifactGate(stage: .sourceChat, initiallyEnabled: false)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { try await gate.enter($0) })
        let entry = try registry.registerLegacy(f.identity), owner = entry.artifacts
        registry.startPersistence(f.identity); try registry.captureDidClose(f.identity)
        try await owner.flush(); _ = try await owner.loadChat()
        #expect(throws: LiveArtifactError.artifactTooLarge) { try owner.publishFinal(.init(text: String(repeating: "x", count: 100_000))) }
        #expect(try owner.finalContext() == nil)
        await gate.arm()
        do {
            try owner.saveChat(f.history("First"), urgent: true); try await gate.waitForArrival()
            try owner.clearChat(); try owner.saveChat(f.history("Second"), urgent: true)
            try owner.clearChat(); try owner.saveChat(f.history("Third"), urgent: true)
            let revision = owner.acceptedRevision
            #expect(throws: LiveArtifactError.queueFull) { try owner.publishFinal(.init(text: "Not admitted yet")) }
            #expect(owner.acceptedRevision == revision)
            #expect(try owner.finalContext() == nil)
            await gate.release(); try await owner.flush()
            try owner.publishFinal(.init(text: "Admitted complete source"))
            let accepted = try #require(try owner.finalContext())
            let oversized = RichTranscript(segments: [.init(start: 0, end: 1, text: String(repeating: "x", count: 100_000), originalText: "")])
            #expect(throws: LiveArtifactError.artifactTooLarge) { try owner.publishSavedFinal(oversized) }
            #expect(try owner.finalContext() == accepted && owner.failure == nil)
            try await owner.flush()
            #expect(try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover().appTranscript?.finalContext() == accepted)
        } catch { await gate.release(); owner.retire(); await owner.waitForSubmittedWrites(); throw error }
    }

    @Test(arguments: ["skipped", "transcribe", "save", "checkpoint"])
    func actualPreparationKeepsLiveEvidenceWhenFinalTextHasNotCommitted(boundary: String) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root), entry = try registry.registerLegacy(f.identity)
        do {
        registry.startPersistence(f.identity); try entry.artifacts.appendLegacy([.init(start: 0, end: 1, text: "Live evidence")])
        try registry.captureDidClose(f.identity)
        let pipeline = ProcessingPipeline(), raw = TranscriptionResult(text: "Uncommitted preview")
        let url = f.root.appendingPathComponent("raw.transcript.json")
        do {
            _ = try await pipeline.prepareWorkflow(transcribe: boundary != "skipped", steps: .init(
                waitForCalendar: {}, finalize: {}, finalizationCommitted: {}, meetingContext: {}, prewarm: {}, loadTranscript: { nil },
                transcribe: {
                    if boundary == "transcribe" { throw LiveArtifactFixtureFailure.injected }
                    return .init(transcription: raw, model: "fixture", audioDuration: 1, spellCorrectionTime: nil)
                }, publishTranscript: { _, _ in }, saveTranscript: { result in
                    if boundary == "save" { throw LiveArtifactFixtureFailure.injected }
                    try await pipeline.saveTranscript(result, to: url)
                }, checkpoint: { stage in
                    if stage == .transcribed, boundary == "checkpoint" { throw LiveArtifactFixtureFailure.injected }
                }, retireQueue: {}, transcriptCommitted: { @MainActor result, _ in try entry.artifacts.publishFinal(result) }, speakers: { _, _ in false }))
            #expect(boundary == "skipped")
        } catch let error as ProcessingPipeline.PreparationFailure { #expect(error.underlying is LiveArtifactFixtureFailure) }
        #expect(try entry.artifacts.finalContext() == nil)
        #expect(try await provider(f, registry).freeze().snapshot().segments.map(\.text) == ["Live evidence"])
        try await entry.artifacts.flush()
        #expect(try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover().appTranscript?.finalPublication == nil)
        try registry.retire(f.identity); await entry.artifacts.waitForSubmittedWrites()
        } catch { try? registry.retire(f.identity); await entry.artifacts.waitForSubmittedWrites(); throw error }
    }

    @Test func heldDurableCheckpointDelaysFinalPublicationAndLaterAnalysisFailureKeepsIt() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root), entry = try registry.registerLegacy(f.identity)
        registry.startPersistence(f.identity); try registry.captureDidClose(f.identity)
        let pipeline = ProcessingPipeline(), raw = TranscriptionResult(text: "", segments: [.init(start: 0, end: 1, text: "Actual segment text")])
        let gate = LiveArtifactGate(stage: .sourceTranscript), url = f.root.appendingPathComponent("raw.transcript.json")
        let processing = Task {
            try await pipeline.prepareWorkflow(transcribe: true, steps: .init(waitForCalendar: {}, finalize: {}, finalizationCommitted: {},
                meetingContext: {}, prewarm: {}, loadTranscript: { nil },
                transcribe: { .init(transcription: raw, model: "fixture", audioDuration: 1, spellCorrectionTime: nil) },
                publishTranscript: { _, _ in }, saveTranscript: { try await pipeline.saveTranscript($0, to: url) },
                checkpoint: { stage in
                    if stage == .transcribed {
                        try await gate.enter(.sourceTranscript)
                        let checkpoint = f.root.appendingPathComponent("committed-checkpoint.txt"), data = Data(stage.rawValue.utf8)
                        try data.write(to: checkpoint, options: .atomic)
                        guard try Data(contentsOf: checkpoint) == data else { throw LiveArtifactFixtureFailure.injected }
                    }
                }, retireQueue: {}, transcriptCommitted: { @MainActor result, _ in try entry.artifacts.publishFinal(result) }, speakers: { _, _ in false }))
        }
        do {
            try await gate.waitForArrival()
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(try entry.artifacts.finalContext() == nil)
            await gate.release(); _ = try await processing.value
            let final = try #require(try entry.artifacts.finalContext())
            #expect(final.segments.map(\.text) == ["Actual segment text"] && final.segments.first?.finalPlayback == nil)
            let outcome = try await pipeline.analysisExportWorkflow(.init(mode: .processing, analysisAlreadyCompleted: false,
                runAnalysis: true, analysisRequested: true, writeMarkdown: true, stopBeforeIntegrations: true), steps: .init(
                    restoreAnalysis: {}, analyze: { throw LiveArtifactFixtureFailure.injected }, saveAnalysis: {}, checkpointAnalysis: { _ in },
                    title: {}, performance: {}, markdown: { _ in throw LiveArtifactFixtureFailure.injected }, persistTitle: {},
                    updateExportLink: { _ in }, saveRetryInsights: { _ in }, prepareDeliveries: { _ in }, checkpointMarkdown: {},
                    markdownCommitted: {}, dispatch: { _, _ in false }, reportFailure: { error in #expect(error.phase == .analyzing) }))
            if case .failed = outcome {} else { Issue.record("Expected analysis failure") }
            #expect(try entry.artifacts.finalContext() == final)
            try await entry.artifacts.flush()
            #expect(try await LiveSessionArtifactStore(identity: f.identity, rootURL: f.root).recover().appTranscript?.finalContext() == final)
        } catch {
            await gate.release(); _ = try? await processing.value
            try? registry.retire(f.identity); await entry.artifacts.waitForSubmittedWrites(); throw error
        }
    }

    @Test func rejectedTextOnlyRawCannotTurnIntoAnEmptyCompleteSourceThroughTheSavedRichCallback() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root), entry = try registry.registerLegacy(f.identity)
        registry.startPersistence(f.identity); try entry.artifacts.appendLegacy([.init(start: 0, end: 1, text: "Keep this live source")])
        try registry.captureDidClose(f.identity)
        do {
            #expect(throws: LiveArtifactError.artifactTooLarge) {
                try entry.artifacts.publishFinal(.init(text: String(repeating: "x", count: 100_000), segments: []))
            }
            let empty = RichTranscript(segments: [])
            try await TranscriptStore().save(empty, to: f.root.appendingPathComponent("saved.richtranscript.json"))
            #expect(throws: LiveArtifactError.artifactTooLarge) { try entry.artifacts.publishSavedFinal(empty) }
            #expect(try entry.artifacts.finalContext() == nil)
            #expect(try await provider(f, registry).freeze().snapshot().segments.map(\.text) == ["Keep this live source"])
            try await entry.artifacts.flush()
        } catch { try? registry.retire(f.identity); await entry.artifacts.waitForSubmittedWrites(); throw error }
    }
}
