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

    /// Human-readable title of the recording this session processed (AI-generated
    /// title → draft title → filename). Nil for records written before this field
    /// existed; the per-recording Benchmark list falls back to the date.
    var label: String?

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
    /// Wall-clock of the speaker-diarization pass (seconds), when it ran. Reported
    /// by the helper separately so it isn't conflated with transcription overhead.
    var diarizationTime: TimeInterval?

    /// Wall-clock of the audio finalization (ffmpeg merge/transcode) step, in
    /// seconds. Nil when the audio was imported/promoted without an encode.
    var finalizationTime: TimeInterval?

    /// Display name of the AI analysis model used (e.g. "gemini-2.5-flash-lite",
    /// "Apple Intelligence"), or nil when AI analysis didn't run.
    var aiModel: String?
    /// Wall-clock time the AI analysis pass took, in seconds.
    var aiTime: TimeInterval?
    /// Wall-clock of the vocabulary spell-correction AI pass, in seconds. Nil when
    /// no custom vocabulary was set (the step is skipped).
    var spellCorrectionTime: TimeInterval?
    /// Wall-clock of the title-generation step, in seconds. Nil for unified local
    /// engines (title is produced inline with the analysis) or when AI was skipped.
    var titleGenerationTime: TimeInterval?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        label: String? = nil,
        transcriptionModel: String? = nil,
        audioDuration: TimeInterval? = nil,
        transcriptionTime: TimeInterval? = nil,
        inferenceTime: TimeInterval? = nil,
        diarizationTime: TimeInterval? = nil,
        finalizationTime: TimeInterval? = nil,
        aiModel: String? = nil,
        aiTime: TimeInterval? = nil,
        spellCorrectionTime: TimeInterval? = nil,
        titleGenerationTime: TimeInterval? = nil
    ) {
        self.id = id
        self.date = date
        self.label = label
        self.transcriptionModel = transcriptionModel
        self.audioDuration = audioDuration
        self.transcriptionTime = transcriptionTime
        self.inferenceTime = inferenceTime
        self.diarizationTime = diarizationTime
        self.finalizationTime = finalizationTime
        self.aiModel = aiModel
        self.aiTime = aiTime
        self.spellCorrectionTime = spellCorrectionTime
        self.titleGenerationTime = titleGenerationTime
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
