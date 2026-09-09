import Foundation
import OSLog
import dBriefWire

extension ProcessingPipeline {
    struct SpeakerRequest: Sendable {
        let transcription: TranscriptionResult
        let participants: [String]
        let roster: [String]
        let mode: AppSettings.SpeakerIdMode
        let reviewAlreadyCompleted: Bool
        let reviewRequired: Bool?
    }
    struct SpeakerSteps: Sendable {
        var loadLibrary: @Sendable () async throws -> VoiceLibrary
        /// Return nil only for an absent, optional sidecar; malformed or required
        /// sidecars must throw so recovery cannot overwrite reviewed user edits.
        var loadTranscript: @Sendable (_ required: Bool) async throws -> RichTranscript?
        var saveTranscript: @Sendable (RichTranscript) async throws -> Void
        var publishTranscript: @Sendable (RichTranscript) async throws -> Void
        var checkpointDiarized: @Sendable (_ held: Bool) async throws -> Void
        var holdReview: @Sendable ([SpeakerReviewItem]) async throws -> Void
        var enroll: @Sendable (VoiceEnrollment.Entry) async throws -> Void
        var completeReview: @Sendable () async throws -> Void
        var validateOwnership: @Sendable () async throws -> Void = {}
    }

    /// Voice matching, transcript construction, review policy and enrollment order
    /// execute on this actor. Observable state is published through owned adapters.
    func prepareSpeakers(_ request: SpeakerRequest, steps: SpeakerSteps) async throws -> Bool {
        try await validateSpeakers(steps)
        let library = try await steps.loadLibrary()
        try await validateSpeakers(steps)
        let hasLibrary = !library.people.isEmpty
        let embeddings = request.transcription.speakerEmbeddings ?? [:]
        var decisions: [String: VoiceIdentityResolver.Decision] = [:]
        var resolved: [String: ResolvedSpeaker] = [:]
        if !embeddings.isEmpty, hasLibrary {
            decisions = VoiceIdentityResolver.resolve(clusterEmbeddings: embeddings, library: library, roster: request.roster)
            for (speakerID, decision) in decisions where decision.reason == .matched {
                if let name = decision.name { resolved[speakerID] = .init(name: name, personId: decision.personId) }
            }
            Logger.transcription.info("Voice library matched \(resolved.count) of \(embeddings.count) speaker(s)")
        } else if hasLibrary {
            Logger.transcription.error("Voice library present but no speaker embeddings on this recording — speakers left unnamed (no ordinal guess)")
        }
        try await validateSpeakers(steps)
        let existing = try await steps.loadTranscript(request.reviewAlreadyCompleted)
        try await validateSpeakers(steps)
        let rich: RichTranscript
        if let existing {
            rich = existing
        } else {
            guard !request.reviewAlreadyCompleted else { throw TranscriptStoreError.noSidecarURL }
            rich = RichTranscriptBuilder().build(from: request.transcription, participants: request.participants,
                                                  resolved: resolved, suppressOrdinalGuess: hasLibrary)
            try await validateSpeakers(steps)
            try await steps.saveTranscript(rich)
            try await validateSpeakers(steps)
        }
        try await steps.publishTranscript(rich)
        try await validateSpeakers(steps)
        let speakerCount = Set(rich.segments.compactMap(\.speakerId)).count
        let computedHold = SpeakerReviewGate.shouldHold(mode: request.mode, speakerCount: speakerCount, libraryCount: library.people.count)
        let held = !request.reviewAlreadyCompleted && (request.reviewRequired ?? computedHold)
        try await steps.checkpointDiarized(held)
        try await validateSpeakers(steps)
        if held {
            let items = rich.speakerLabels.map { label in
                let decision = decisions[label.id]
                return SpeakerReviewItem(id: label.id, proposedName: label.displayName,
                    reason: decision?.reason ?? .noEmbedding, confidence: decision?.confidence ?? 0,
                    personId: label.personId, clusterEmbedding: embeddings[label.id] ?? [],
                    snippet: SpeakerSnippet.representative(for: label.id, in: rich))
            }.sorted { $0.id < $1.id }
            try await validateSpeakers(steps)
            try await steps.holdReview(items)
            try await validateSpeakers(steps)
            return true
        }
        if !request.reviewAlreadyCompleted, !embeddings.isEmpty {
            let entries = VoiceEnrollment.enrollable(speakerLabels: rich.speakerLabels, embeddings: embeddings)
            for entry in entries {
                try await validateSpeakers(steps)
                try await steps.enroll(entry)
                try await validateSpeakers(steps)
            }
        }
        try await steps.completeReview()
        try await validateSpeakers(steps)
        return false
    }

    private func validateSpeakers(_ steps: SpeakerSteps) async throws {
        try Task.checkCancellation()
        try await steps.validateOwnership()
        try Task.checkCancellation()
    }
}
