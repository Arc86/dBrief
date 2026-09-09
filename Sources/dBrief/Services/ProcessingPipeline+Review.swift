import Foundation
import dBriefWire

extension ProcessingPipeline {
    struct ReviewConfirmationSteps: Sendable {
        var loadTranscript: @Sendable () async throws -> RichTranscript
        var save: @Sendable (RichTranscript, _ original: RichTranscript) async throws -> Void
        var publish: @Sendable (RichTranscript) async throws -> Void
        var loadEmbeddings: @Sendable () async throws -> [String: [Float]]
        var enroll: @Sendable (VoiceEnrollment.Entry) async throws -> Void
        var validateOwnership: @Sendable () async throws -> Void = {}
    }

    func confirmSpeakers(_ confirmed: [String: ConfirmedSpeaker], transcript: RichTranscript?,
                         steps: ReviewConfirmationSteps) async throws {
        try await validateReviewOwner(steps.validateOwnership)
        var rich: RichTranscript
        if let transcript { rich = transcript }
        else { rich = try await steps.loadTranscript() }
        try await validateReviewOwner(steps.validateOwnership)
        let original = rich
        var enrollments: [(id: String, name: String)] = []
        for speakerID in confirmed.keys.sorted() {
            guard let confirmation = confirmed[speakerID] else { continue }
            let name = confirmation.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            rich = SpeakerReassignment.rename(rich, speakerId: speakerID, to: name, personId: confirmation.personId)
            if name != speakerID { enrollments.append((speakerID, name)) }
        }
        try await validateReviewOwner(steps.validateOwnership)
        try await steps.save(rich, original)
        try await validateReviewOwner(steps.validateOwnership)
        try await steps.publish(rich)
        try await validateReviewOwner(steps.validateOwnership)
        if !enrollments.isEmpty {
            let embeddings = try await steps.loadEmbeddings()
            try await validateReviewOwner(steps.validateOwnership)
            for entry in enrollments {
                guard let embedding = embeddings[entry.id], !embedding.isEmpty else { continue }
                try await steps.enroll(.init(name: entry.name, embedding: embedding))
                try await validateReviewOwner(steps.validateOwnership)
            }
        }
    }

    struct RediarizationReviewRequest: Sendable {
        let turns: [DiarizedTurn]
        let embeddings: [String: [Float]]
        let transcript: RichTranscript
        let mode: AppSettings.SpeakerIdMode
        let roster: [String]
    }
    struct PreparedRediarizationReview: Sendable {
        let transcript: RichTranscript
        let items: [SpeakerReviewItem]
    }

    /// Nil means the gate declined review. Save errors and cancellation throw,
    /// so callers cannot mistake failed preparation for permission to commit silently.
    func prepareRediarizationReview(_ request: RediarizationReviewRequest,
                                    loadLibrary: @Sendable () async throws -> VoiceLibrary,
                                    save: @Sendable (RichTranscript) async throws -> Void,
                                    validateOwnership: @Sendable () async throws -> Void = {}) async throws -> PreparedRediarizationReview? {
        try await validateReviewOwner(validateOwnership)
        var rich = SpeakerAssigner.assign(request.turns, to: request.transcript)
        let speakerIDs = Set(rich.segments.compactMap(\.speakerId)).sorted()
        let library = try await loadLibrary()
        try await validateReviewOwner(validateOwnership)
        guard SpeakerReviewGate.shouldHold(mode: request.mode, speakerCount: speakerIDs.count,
                                          libraryCount: library.people.count) else { return nil }
        let decisions = !request.embeddings.isEmpty && !library.people.isEmpty
            ? VoiceIdentityResolver.resolve(clusterEmbeddings: request.embeddings, library: library, roster: request.roster) : [:]
        rich.speakerLabels = speakerIDs.map { id in
            if let decision = decisions[id], decision.reason == .matched, let name = decision.name {
                return SpeakerLabel(id: id, displayName: name, personId: decision.personId)
            }
            return SpeakerLabel(id: id, displayName: id)
        }
        let items = rich.speakerLabels.map { label in
            let decision = decisions[label.id]
            return SpeakerReviewItem(id: label.id, proposedName: label.displayName,
                reason: decision?.reason ?? .noEmbedding, confidence: decision?.confidence ?? 0,
                personId: label.personId, clusterEmbedding: request.embeddings[label.id] ?? [],
                snippet: SpeakerSnippet.representative(for: label.id, in: rich))
        }
        try await validateReviewOwner(validateOwnership)
        try await save(rich)
        try await validateReviewOwner(validateOwnership)
        return .init(transcript: rich, items: items)
    }

    private func validateReviewOwner(_ validate: @Sendable () async throws -> Void) async throws {
        try Task.checkCancellation()
        try await validate()
        try Task.checkCancellation()
    }
}
