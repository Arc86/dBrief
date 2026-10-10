import Foundation
import dBriefWire

/// One detected voice in the confirm-first review.
struct SpeakerReviewItem: Identifiable, Equatable, Sendable {
    var id: String                 // diarization speaker id
    var proposedName: String       // matched name, or the raw "Speaker N"
    var reason: VoiceIdentityResolver.Reason
    var confidence: Float
    var personId: String?          // library link when the proposal came from a match
    var clusterEmbedding: [Float]  // ranks the library choices
    var snippet: (start: Double, end: Double)?  // representative audio range

    static func == (lhs: SpeakerReviewItem, rhs: SpeakerReviewItem) -> Bool {
        lhs.id == rhs.id && lhs.proposedName == rhs.proposedName
            && lhs.reason == rhs.reason && lhs.personId == rhs.personId
    }
}

/// A user's confirmed identity for one speaker (output of the review window).
struct ConfirmedSpeaker: Equatable, Sendable {
    let name: String
    let personId: String?
}

/// Transcription-side performance metrics gathered before the confirm-first hold,
/// carried through so the post-confirm continuation can record a complete
/// `ModelPerformanceRecord` (it adds the AI-side metrics itself).
struct TranscriptionPerf: Sendable {
    var model: String? = nil
    var time: TimeInterval? = nil
    var inference: TimeInterval? = nil
    var diarization: TimeInterval? = nil
    var spellCorrection: TimeInterval? = nil
    var finalization: TimeInterval? = nil
    var audioDuration: TimeInterval? = nil
}

extension TranscriptionPerf {
    /// Timings of a transcription that just ran (not one loaded from a sidecar).
    init(fresh result: TranscriptionResult, model: String?, audioDuration: TimeInterval,
         spellCorrection: TimeInterval?, elapsed: TimeInterval) {
        self.init(model: model, time: elapsed, inference: result.inferenceTime,
                  diarization: result.diarizationTime, spellCorrection: spellCorrection,
                  audioDuration: audioDuration)
    }
}

/// The held-pipeline state for a recording paused awaiting speaker confirmation.
/// Session-only: never persisted; cleared on confirm/cancel.
@MainActor
final class SpeakerReviewSession: Identifiable {
    /// Where the hold was armed — determines what Confirm/Cancel does next.
    enum Origin {
        case pipeline    // fresh-transcription hold; resume runs AI → markdown → export
        case reprocessing
    }

    let id = UUID()
    let recording: Recording
    let masterAudioURL: URL?
    var items: [SpeakerReviewItem]
    // Captured so the continuation runs with the same options the user chose.
    let transcribe: Bool
    let summary: Bool
    let actionItems: Bool
    let tags: Bool
    let localAIAvailable: Bool
    let perf: TranscriptionPerf
    let origin: Origin
    /// Launch recovery stops after Markdown, before any integration dispatch.
    let stopBeforeIntegrations: Bool

    init(recording: Recording, masterAudioURL: URL?, items: [SpeakerReviewItem],
         transcribe: Bool, summary: Bool, actionItems: Bool, tags: Bool,
         localAIAvailable: Bool, perf: TranscriptionPerf, origin: Origin = .pipeline,
         stopBeforeIntegrations: Bool = false) {
        self.recording = recording
        self.masterAudioURL = masterAudioURL
        self.items = items
        self.transcribe = transcribe
        self.summary = summary
        self.actionItems = actionItems
        self.tags = tags
        self.localAIAvailable = localAIAvailable
        self.perf = perf
        self.origin = origin
        self.stopBeforeIntegrations = stopBeforeIntegrations
    }
}
