import Foundation

/// One speaker card in the confirm-first review window.
struct SpeakerReviewItem: Identifiable, Equatable {
    var id: String                 // diarization speaker id
    var proposedName: String       // matched name, or the raw "Speaker N"
    var reason: VoiceIdentityResolver.Reason
    var confidence: Float
    var personId: String?          // library link when the proposal came from a match
    var clusterEmbedding: [Float]  // for live candidate chips
    var snippet: (start: Double, end: Double)?  // representative audio range

    static func == (lhs: SpeakerReviewItem, rhs: SpeakerReviewItem) -> Bool {
        lhs.id == rhs.id && lhs.proposedName == rhs.proposedName
            && lhs.reason == rhs.reason && lhs.personId == rhs.personId
    }
}

/// A user's confirmed identity for one speaker (output of the review window).
struct ConfirmedSpeaker: Equatable {
    let name: String
    let personId: String?
}

/// The held-pipeline state for a recording paused awaiting speaker confirmation.
/// Session-only: never persisted; cleared on confirm/cancel.
@MainActor
final class SpeakerReviewSession: Identifiable {
    let id = UUID()
    let recording: Recording
    let masterAudioURL: URL?
    var items: [SpeakerReviewItem]
    // Captured so the continuation runs with the same options the user chose.
    let summary: Bool
    let actionItems: Bool
    let tags: Bool
    let localAIAvailable: Bool

    init(recording: Recording, masterAudioURL: URL?, items: [SpeakerReviewItem],
         summary: Bool, actionItems: Bool, tags: Bool, localAIAvailable: Bool) {
        self.recording = recording
        self.masterAudioURL = masterAudioURL
        self.items = items
        self.summary = summary
        self.actionItems = actionItems
        self.tags = tags
        self.localAIAvailable = localAIAvailable
    }
}
