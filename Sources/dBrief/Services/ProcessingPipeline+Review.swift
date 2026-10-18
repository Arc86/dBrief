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
            rich = SpeakerReassignment.confirm(rich, speakerId: speakerID, as: confirmation)
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

    private func validateReviewOwner(_ validate: @Sendable () async throws -> Void) async throws {
        try Task.checkCancellation()
        try await validate()
        try Task.checkCancellation()
    }
}
