import Foundation

/// Pure, view-independent breakdown of a single `ModelPerformanceRecord` into the
/// per-step timeline shown in the Benchmark page's "Recent Transcriptions" section.
/// Kept free of SwiftUI so the share/overhead/slower-than-usual math is unit-tested
/// in isolation (`RecordingPerformanceRowTests`). Formatting lives in the view.
struct RecordingPerformanceRow: Identifiable {
    /// The processing steps a row can break time down into, in pipeline order.
    enum StepKind: String, CaseIterable, Identifiable {
        case finalize
        case transcribe
        case diarize
        case ai
        case vocab
        case title
        var id: String { rawValue }

        /// Display label for the step.
        var title: String {
            switch self {
            case .finalize: "Finalize audio"
            case .transcribe: "Transcribe"
            case .diarize: "Diarize"
            case .ai: "AI analysis"
            case .vocab: "Vocabulary fix"
            case .title: "Title"
            }
        }
    }

    struct Step: Identifiable {
        let kind: StepKind
        let duration: TimeInterval
        /// Fraction of the row total this step represents (0…1).
        let share: Double
        /// Optional secondary line (e.g. the transcribe step's model/overhead split,
        /// or the model name for the AI step).
        let caption: String?
        var id: String { kind.id }
    }

    /// How the run's transcription speed reads at a glance.
    enum SpeedTier { case fast, normal, slow, unknown }

    let id: UUID
    let label: String
    let date: Date
    let transcriptionModel: String?
    let aiModel: String?
    /// Transcribed audio length, when transcription ran.
    let audioDuration: TimeInterval?
    /// Realtime ratio of the transcription step (audio ÷ transcription wall-clock),
    /// nil when transcription didn't run or timing is unusable.
    let transcriptionRealtime: Double?
    /// Sum of every present step's wall-clock — the row's "total".
    let total: TimeInterval
    let steps: [Step]
    /// True when this run's transcription realtime is well below this model's
    /// typical realtime in the same data set (the "slower than usual" tag).
    let isSlowerThanUsual: Bool

    var speedTier: SpeedTier {
        guard let rt = transcriptionRealtime else { return .unknown }
        if rt >= RecordingPerformanceRow.fastRealtimeThreshold { return .fast }
        if rt < RecordingPerformanceRow.slowRealtimeThreshold { return .slow }
        return .normal
    }

    // Tunable thresholds.
    static let fastRealtimeThreshold = 2.0
    static let slowRealtimeThreshold = 1.0
    /// A run is "slower than usual" when its realtime is below this fraction of the
    /// model's average realtime.
    static let slowerThanUsualFraction = 0.6
    /// Don't flag "slower than usual" unless the model has at least this many runs
    /// in the data set (one sample can't be slower than its own average).
    static let slowerThanUsualMinSessions = 3
}

/// Builds display rows from raw records: computes per-model baseline speed across
/// the whole (already time-filtered) set, then returns the most recent `limit`
/// rows newest-first with the breakdown + slower-than-usual flag resolved.
enum RecordingPerformanceBuilder {
    static func rows(from records: [ModelPerformanceRecord], limit: Int = 10) -> [RecordingPerformanceRow] {
        // Per-model average transcription realtime + session count, over the full set.
        var ratioSum: [String: Double] = [:]
        var ratioCount: [String: Int] = [:]
        for r in records {
            guard let model = r.transcriptionModel,
                  let audio = r.audioDuration,
                  let tx = r.transcriptionTime, tx > 0 else { continue }
            ratioSum[model, default: 0] += audio / tx
            ratioCount[model, default: 0] += 1
        }

        let recent = records.sorted { $0.date > $1.date }.prefix(limit)
        return recent.map { record in
            let model = record.transcriptionModel
            let avg: Double? = {
                guard let model, let sum = ratioSum[model], let count = ratioCount[model],
                      count >= RecordingPerformanceRow.slowerThanUsualMinSessions else { return nil }
                return sum / Double(count)
            }()
            return makeRow(record, modelAverageRealtime: avg)
        }
    }

    /// Construct a single row. `modelAverageRealtime` is the model's typical realtime
    /// (nil when there isn't a reliable baseline), used only for the slower-than-usual flag.
    static func makeRow(_ record: ModelPerformanceRecord, modelAverageRealtime: Double?) -> RecordingPerformanceRow {
        // Sub-steps broken out of the transcription wall-clock.
        let diarize = record.diarizationTime
        let vocab = record.spellCorrectionTime
        // The "Transcribe" step is the transcription wall-clock minus the parts we
        // surface separately (diarization + vocabulary), i.e. model inference + overhead.
        let transcribeStep: TimeInterval? = record.transcriptionTime.map {
            max(0, $0 - (diarize ?? 0) - (vocab ?? 0))
        }

        // Assemble raw (kind, duration, caption) for every step that ran.
        var raw: [(kind: RecordingPerformanceRow.StepKind, duration: TimeInterval, caption: String?)] = []
        if let f = record.finalizationTime, f > 0 {
            raw.append((.finalize, f, nil))
        }
        if let t = transcribeStep, t > 0 {
            let caption: String?
            if let inf = record.inferenceTime, inf > 0 {
                let overhead = max(0, t - inf)
                caption = "model \(Self.compact(inf)) · +overhead \(Self.compact(overhead))"
            } else {
                caption = nil
            }
            raw.append((.transcribe, t, caption))
        }
        if let d = diarize, d > 0 {
            raw.append((.diarize, d, nil))
        }
        if let a = record.aiTime, a > 0 {
            raw.append((.ai, a, record.aiModel))
        }
        if let v = vocab, v > 0 {
            raw.append((.vocab, v, nil))
        }
        if let ti = record.titleGenerationTime, ti > 0 {
            raw.append((.title, ti, nil))
        }

        let total = raw.reduce(0) { $0 + $1.duration }
        let steps = raw.map { entry in
            RecordingPerformanceRow.Step(
                kind: entry.kind,
                duration: entry.duration,
                share: total > 0 ? entry.duration / total : 0,
                caption: entry.caption
            )
        }

        let realtime: Double? = {
            guard let audio = record.audioDuration, let tx = record.transcriptionTime, tx > 0 else { return nil }
            return audio / tx
        }()

        let slower: Bool = {
            guard let avg = modelAverageRealtime, avg > 0, let rt = realtime else { return false }
            return rt < avg * RecordingPerformanceRow.slowerThanUsualFraction
        }()

        return RecordingPerformanceRow(
            id: record.id,
            label: (record.label?.isEmpty == false ? record.label! : Self.fallbackLabel(record.date)),
            date: record.date,
            transcriptionModel: record.transcriptionModel,
            aiModel: record.aiModel,
            audioDuration: record.audioDuration,
            transcriptionRealtime: realtime,
            total: total,
            steps: steps,
            isSlowerThanUsual: slower
        )
    }

    /// Label for records that predate the `label` field.
    static func fallbackLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Compact seconds used inside captions: "1.8s" or "1:31".
    private static func compact(_ s: TimeInterval) -> String {
        if s >= 60 {
            let m = Int(s) / 60
            let sec = Int(s.rounded()) % 60
            return String(format: "%d:%02d", m, sec)
        }
        return String(format: "%.1fs", s)
    }
}
