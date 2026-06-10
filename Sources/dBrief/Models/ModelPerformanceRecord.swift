import Foundation

/// One processing session's measured performance, appended to the performance
/// log after a recording is transcribed and/or analyzed. The Model Performance
/// panel in the transcript viewer aggregates these by model and time range.
///
/// Each pass is optional: a record may carry only transcription metrics (AI was
/// skipped/failed), only AI metrics (e.g. a retry-AI pass), or both.
struct ModelPerformanceRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date

    /// Display name of the transcription model used (e.g. "Whisper Large V3
    /// Turbo (632 MB)"), or nil when transcription didn't run.
    var transcriptionModel: String?
    /// Length of the transcribed audio in seconds.
    var audioDuration: TimeInterval?
    /// Wall-clock time the transcription pass took, in seconds.
    var transcriptionTime: TimeInterval?
    /// Pure model-inference time (seconds), excluding model load/prewarm, IPC,
    /// audio decode and diarization. Nil for engines that don't report it.
    var inferenceTime: TimeInterval?

    /// Display name of the AI analysis model used (e.g. "gemini-2.5-flash-lite",
    /// "Apple Intelligence"), or nil when AI analysis didn't run.
    var aiModel: String?
    /// Wall-clock time the AI analysis pass took, in seconds.
    var aiTime: TimeInterval?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        transcriptionModel: String? = nil,
        audioDuration: TimeInterval? = nil,
        transcriptionTime: TimeInterval? = nil,
        inferenceTime: TimeInterval? = nil,
        aiModel: String? = nil,
        aiTime: TimeInterval? = nil
    ) {
        self.id = id
        self.date = date
        self.transcriptionModel = transcriptionModel
        self.audioDuration = audioDuration
        self.transcriptionTime = transcriptionTime
        self.inferenceTime = inferenceTime
        self.aiModel = aiModel
        self.aiTime = aiTime
    }

    /// True when this record has usable transcription timing.
    var hasTranscription: Bool {
        transcriptionModel != nil && transcriptionTime != nil
    }

    /// True when this record has usable AI-analysis timing.
    var hasAI: Bool {
        aiModel != nil && aiTime != nil
    }
}
