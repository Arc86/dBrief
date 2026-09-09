import Foundation
import dBriefWire

extension RecordingManager {
    func hydrateReprocessing(_ job: ProcessingJob, options: ReprocessingOptions) async throws {
        let raw: Data?
        let rich: Data?
        if options.requiresTranscription {
            raw = try await reprocessingStore.stagedData(suffix: "transcript.json", attemptID: job.id)
            rich = try await reprocessingStore.stagedData(suffix: "richtranscript.json", attemptID: job.id)
        } else {
            raw = try await reprocessingData("transcript.json", job: job)
            rich = try await reprocessingData("richtranscript.json", job: job)
        }
        if let raw { job.recording.transcription = try? JSONDecoder().decode(TranscriptionResult.self, from: raw) }
        if let rich { job.recording.richTranscript = try JSONDecoder().decode(RichTranscript.self, from: rich) }
        else if !options.requiresTranscription, let raw = job.recording.transcription {
            job.recording.richTranscript = RichTranscriptBuilder().build(from: raw, participants: job.recording.participants,
                resolved: [:], suppressOrdinalGuess: true)
        }
    }

    func reprocessingData(_ suffix: String, job: ProcessingJob) async throws -> Data? {
        if let data = try await reprocessingStore.stagedData(suffix: suffix, attemptID: job.id) { return data }
        return try await reprocessingStore.originalData(suffix: suffix, attemptID: job.id)
    }

    func executeReprocessing(_ stage: ReprocessingWorkflow.Stage, job: ProcessingJob,
                             options: ReprocessingOptions) async throws -> ReprocessingWorkflow.Result {
        let index = appState.processingSteps.count
        let name = switch stage {
        case .transcription: "Retranscribing audio"
        case .speakers: "Detecting speakers"
        case .analysis: "Regenerating AI results"
        }
        appState.processingSteps.append(.init(name: name, status: .inProgress))
        let result: ReprocessingWorkflow.Result
        switch stage {
        case .transcription:
            let config = try options.transcriptionSettings(settings: appSettings)
            job.transcriptionStartedAt = Date()
            let output = try await transcribeRecordingAudio(recording: job.recording, stepIndex: index, settings: config)
            try requireProcessingOwnership(job)
            let raw = output.transcription
            job.recording.transcription = raw
            let rich = RichTranscriptBuilder().build(from: raw, participants: job.recording.participants,
                resolved: [:], suppressOrdinalGuess: true)
            job.recording.richTranscript = rich
            try await reprocessingStore.stage(JSONEncoder().encode(raw), suffix: "transcript.json", attemptID: job.id)
            try await reprocessingStore.stage(JSONEncoder().encode(rich), suffix: "richtranscript.json", attemptID: job.id)
            result = .completed
        case .speakers:
            result = try await reprocessSpeakers(job: job, options: options)
        case .analysis:
            try await reprocessAnalysis(job: job, options: options, stepIndex: index)
            result = .completed
        }
        try requireProcessingOwnership(job)
        if appState.processingSteps.indices.contains(index) {
            appState.processingSteps[index].status = .completed
        }
        return result
    }

    func reprocessSpeakers(job: ProcessingJob, options: ReprocessingOptions) async throws -> ReprocessingWorkflow.Result {
        guard var rich = job.recording.richTranscript else { throw ReprocessingError.missingTranscript }
        let attempt = try await reprocessingStore.load(attemptID: job.id)
        try requireProcessingOwnership(job)
        let prepared = attempt.completedStages.contains("speakerPrepared")
        if !prepared {
            var embeddings = job.recording.transcription?.speakerEmbeddings ?? [:]
            let alreadyDiarized = options.operation == .transcribe
                && job.recording.transcription?.segments.contains(where: { $0.speaker != nil }) == true
            if !alreadyDiarized {
                let detected = try await localAIPluginService.diarizeWithEmbeddings(fileURL: attempt.audioURL)
                try requireProcessingOwnership(job)
                guard !detected.0.isEmpty else { throw ReprocessingError.noSpeakers }
                // A fresh clustering has no relationship to the old IDs. In
                // particular, unmatched spans must not retain an old identity.
                for index in rich.segments.indices { rich.segments[index].speakerId = nil }
                rich = SpeakerAssigner.assign(detected.0, to: rich)
                embeddings = detected.1
                let original = job.recording.transcription ?? TranscriptionResult(
                    text: rich.segments.map(\.text).joined(separator: " "),
                    segments: rich.segments.map { .init(start: $0.start, end: $0.end, text: $0.text) })
                let updated = Self.reprocessingSpeakerEvidence(original, turns: detected.0, embeddings: embeddings)
                try await reprocessingStore.stage(JSONEncoder().encode(updated), suffix: "transcript.json", attemptID: job.id)
                try requireProcessingOwnership(job)
                job.recording.transcription = updated
            }
            let library = await voiceLibraryStore.load()
            try requireProcessingOwnership(job)
            let decisions = VoiceIdentityResolver.resolve(clusterEmbeddings: embeddings, library: library,
                                                          roster: job.recording.participants)
            let ids = Set(rich.segments.compactMap(\.speakerId)).sorted()
            rich.speakerLabels = ids.map { id in
                if let decision = decisions[id], decision.reason == .matched, let name = decision.name {
                    return SpeakerLabel(id: id, displayName: name, personId: decision.personId)
                }
                return SpeakerLabel(id: id, displayName: id)
            }
            rich.meSpeakerId = nil
            try await reprocessingStore.stage(JSONEncoder().encode(rich), suffix: "richtranscript.json", attemptID: job.id)
            try requireProcessingOwnership(job)
            try await reprocessingStore.checkpoint(attemptID: job.id, status: .speakers, completedStage: "speakerPrepared")
            try requireProcessingOwnership(job)
            job.recording.richTranscript = rich
        }
        if options.speakerIdMode == .confirmFirst && rich.speakerLabels.count > 1 {
            let items = rich.speakerLabels.map {
                SpeakerReviewItem(id: $0.id, proposedName: $0.displayName, reason: .noEmbedding,
                    confidence: 0, personId: $0.personId, clusterEmbedding: [],
                    snippet: SpeakerSnippet.representative(for: $0.id, in: rich))
            }
            try await reprocessingStore.checkpoint(attemptID: job.id, status: .waitingForSpeakerReview)
            try requireProcessingOwnership(job)
            appState.pendingSpeakerReview = SpeakerReviewSession(recording: job.recording,
                masterAudioURL: attempt.audioURL, items: items, transcribe: options.requiresTranscription,
                summary: options.requiresAnalysis, actionItems: options.requiresAnalysis, tags: options.requiresAnalysis,
                localAIAvailable: false, perf: TranscriptionPerf(), origin: .reprocessing)
            SpeakerReviewWindowController.shared.show()
            return .held
        }
        return .completed
    }

    func finishReprocessingReview(sessionID: UUID, confirmed: [String: ConfirmedSpeaker]) async {
        guard !Task.isCancelled, let session = appState.pendingSpeakerReview, session.id == sessionID,
              session.origin == .reprocessing, let job = appState.processingJob,
              job.recording === session.recording, job.reprocessingAttemptID != nil,
              !processingCancellationInProgress else { return }
        // Claim confirmation and install its lifetime before the first suspension.
        // Stop now cancels/joins persistence AND the resumed workflow, and a second
        // confirmation cannot replace the handle that Stop owns.
        appState.pendingSpeakerReview = nil
        Self.installReprocessingReviewTask(on: job) {
            do {
                try self.requireProcessingOwnership(job)
                guard !self.processingCancellationInProgress else { throw CancellationError() }
                guard var rich = job.recording.richTranscript else { throw ReprocessingError.missingTranscript }
                for (id, choice) in confirmed {
                    let name = choice.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { rich = SpeakerReassignment.rename(rich, speakerId: id, to: name, personId: choice.personId) }
                }
                try await self.reprocessingStore.stage(JSONEncoder().encode(rich), suffix: "richtranscript.json", attemptID: job.id)
                try self.requireProcessingOwnership(job)
                try await self.reprocessingStore.checkpoint(attemptID: job.id, status: .ready, completedStage: "speakers")
                try self.requireProcessingOwnership(job)
                job.recording.richTranscript = rich
                let attempt = try await self.reprocessingStore.load(attemptID: job.id)
                try self.requireProcessingOwnership(job)
                guard !self.processingCancellationInProgress else { throw CancellationError() }
                let request = try JSONDecoder().decode(ReprocessingRequest.self, from: attempt.configuration)
                if let context = job.privacyContext {
                    await PrivacyTrace.$context.withValue(context) { await self.runReprocessing(job, request: request) }
                } else { await self.runReprocessing(job, request: request) }
            } catch {
                // Stop owns the terminal checkpoint once cancellation begins.
                guard !Task.isCancelled, !self.processingCancellationInProgress,
                      self.appState.processingJob === job else { return }
                try? await self.reprocessingStore.checkpoint(attemptID: job.id, status: .failed,
                    message: error.localizedDescription)
                guard !Task.isCancelled, !self.processingCancellationInProgress,
                      self.appState.processingJob === job else { return }
                self.appState.lastError = error.localizedDescription
                await self.endReprocessing(job)
            }
        }
    }

    /// The held workflow can still be finishing its queue refresh. Preserve its
    /// lifetime in the joined chain before confirmation touches staged results.
    static func installReprocessingReviewTask(on job: ProcessingJob,
        operation: @escaping @MainActor () async -> Void) {
        let predecessor = job.task
        job.task = Task {
            await predecessor?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    /// Replace speaker evidence as a unit while retaining ASR words, timing and
    /// provenance. Later viewer enrollment reads this durable embedding map.
    nonisolated static func reprocessingSpeakerEvidence(_ original: TranscriptionResult,
        turns: [DiarizedTurn], embeddings: [String: [Float]]) -> TranscriptionResult {
        func speaker(start: Double, end: Double) -> String? {
            var best: String?
            var bestOverlap = 0.0
            for turn in turns {
                let overlap = min(end, turn.end) - max(start, turn.start)
                if overlap > bestOverlap { best = turn.speakerId; bestOverlap = overlap }
            }
            return best
        }
        let segments = original.segments.map { segment in
            var updated = segment
            updated.speaker = speaker(start: segment.start, end: segment.end)
            updated.words = segment.words?.map { word in
                var updatedWord = word
                updatedWord.speaker = speaker(start: word.start, end: word.end)
                return updatedWord
            }
            return updated
        }
        let ids = Set(turns.map(\.speakerId))
        return TranscriptionResult(text: original.text, segments: segments, language: original.language,
            warnings: original.warnings, speakerCount: ids.count, inferenceTime: original.inferenceTime,
            diarizationTime: nil, speakerEmbeddings: embeddings.filter { ids.contains($0.key) }, modelName: original.modelName)
    }

    func reprocessAnalysis(job: ProcessingJob, options: ReprocessingOptions, stepIndex: Int) async throws {
        let config = try options.analysisConfiguration(settings: appSettings)
        guard let rich = job.recording.richTranscript else { throw ReprocessingError.missingTranscript }
        // AI sees the user's current edited words, never an older raw sidecar.
        let raw = TranscriptionResult(text: rich.segments.map(\.text).joined(separator: " "),
            segments: rich.segments.map { .init(start: $0.start, end: $0.end, text: $0.text, speaker: $0.speakerId) })
        let input = ProcessingPipeline.AnalysisRequest(transcription: raw,
            speakerNames: Dictionary(rich.speakerLabels.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first }),
            participants: job.recording.participants, calendarEvent: job.recording.calendarEvent,
            engine: config.engine, endpoint: config.endpoint, fields: Set(ProcessingPipeline.AnalysisField.allCases),
            outputLanguage: config.outputLanguage, vocabulary: config.vocabulary, guidance: config.guidance,
            localCLIConfig: config.localCLIConfig, appleUnavailableReason: nil)
        let progress = ProcessingStepProgress(appState: appState, job: job, stepIndex: stepIndex)
        defer { progress.invalidate() }
        let output = try await MLProgress.$sink.withValue(progress.handler()) {
            try await processingPipeline.analyze(input,
                using: .live(ai: aiService, plugin: localAIPluginService, cli: localCLIService),
                onEvent: { @MainActor [weak self] event in
                    guard let self, self.appState.processingJob === job, !Task.isCancelled else { return }
                    job.recording.applyAnalysisField(event, modelName: input.modelName)
                    if case .liveText(let text) = event { self.appState.liveInferenceText = text }
                })
        }
        try requireProcessingOwnership(job)
        guard output.failures.isEmpty, let summary = output.summary,
              let actions = output.actionItems, let tags = output.tags else { throw ReprocessingError.failedAnalysis }
        var insights = RecordingInsights(summary: summary, actionItems: actions, tags: tags,
            sentiment: output.sentiment ?? "", generatedTitle: nil, markdownPath: nil,
            modelProvenance: job.recording.analysisModelProvenance)
        if let priorData = try await reprocessingStore.originalData(suffix: "insights.json", attemptID: job.id) {
            let prior = try JSONDecoder().decode(RecordingInsights.self, from: priorData)
            insights.generatedTitle = prior.generatedTitle
            insights.completedActionItems = Array(prior.completedActions.intersection(actions)).sorted()
        }
        insights.basedOnPreviousTranscript = false
        try await reprocessingStore.stage(JSONEncoder().encode(insights), suffix: "insights.json", attemptID: job.id)
    }
}
