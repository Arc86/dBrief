import Foundation
import Testing
@testable import dBrief

struct RecordingPerformanceRowTests {

    // MARK: - Step breakdown

    @Test func breaksTranscriptionIntoModelOverheadDiarizeVocab() {
        // transcriptionTime 100 = transcribe(70) + diarize(20) + vocab(10);
        // within transcribe: model 50, overhead 20.
        let record = ModelPerformanceRecord(
            label: "Standup",
            transcriptionModel: "Whisper Turbo",
            audioDuration: 600,
            transcriptionTime: 100,
            inferenceTime: 50,
            diarizationTime: 20,
            finalizationTime: 8,
            aiModel: "gemini",
            aiTime: 15,
            spellCorrectionTime: 10,
            titleGenerationTime: 2
        )
        let row = RecordingPerformanceBuilder.makeRow(record, modelAverageRealtime: nil)

        // total = finalize 8 + transcribe 70 + diarize 20 + ai 15 + vocab 10 + title 2 = 125
        #expect(abs(row.total - 125) < 0.001)

        func dur(_ kind: RecordingPerformanceRow.StepKind) -> TimeInterval? {
            row.steps.first { $0.kind == kind }?.duration
        }
        #expect(dur(.finalize) == 8)
        #expect(dur(.transcribe) == 70)   // 100 - diarize 20 - vocab 10
        #expect(dur(.diarize) == 20)
        #expect(dur(.ai) == 15)
        #expect(dur(.vocab) == 10)
        #expect(dur(.title) == 2)

        // Shares sum to ~1.
        let shareSum = row.steps.reduce(0) { $0 + $1.share }
        #expect(abs(shareSum - 1.0) < 0.0001)

        // Transcribe caption splits model vs overhead (70 - 50 = 20).
        let cap = row.steps.first { $0.kind == .transcribe }?.caption ?? ""
        #expect(cap.contains("model"))
        #expect(cap.contains("overhead"))
    }

    @Test func omitsStepsThatDidNotRun() {
        // Transcription only, no diarization / AI / vocab / title / finalize.
        let record = ModelPerformanceRecord(
            label: "Quick note",
            transcriptionModel: "Parakeet v3",
            audioDuration: 120,
            transcriptionTime: 30,
            inferenceTime: 28
        )
        let row = RecordingPerformanceBuilder.makeRow(record, modelAverageRealtime: nil)
        let kinds = Set(row.steps.map(\.kind))
        #expect(kinds == [.transcribe])
        #expect(abs(row.total - 30) < 0.001)
    }

    @Test func overheadClampsAtZeroWhenInferenceExceedsStep() {
        // Degenerate timing: inference reported larger than the transcribe step.
        let record = ModelPerformanceRecord(
            transcriptionModel: "M",
            audioDuration: 100,
            transcriptionTime: 40,
            inferenceTime: 60
        )
        let row = RecordingPerformanceBuilder.makeRow(record, modelAverageRealtime: nil)
        let cap = row.steps.first { $0.kind == .transcribe }?.caption ?? ""
        // overhead = max(0, 40 - 60) = 0
        #expect(cap.contains("+overhead 0"))
    }

    // MARK: - Speed tier

    @Test func speedTierFromRealtime() {
        func tier(audio: TimeInterval, tx: TimeInterval) -> RecordingPerformanceRow.SpeedTier {
            RecordingPerformanceBuilder.makeRow(
                ModelPerformanceRecord(transcriptionModel: "M", audioDuration: audio, transcriptionTime: tx),
                modelAverageRealtime: nil
            ).speedTier
        }
        #expect(tier(audio: 100, tx: 20) == .fast)    // 5×
        #expect(tier(audio: 100, tx: 70) == .normal)  // ~1.4×
        #expect(tier(audio: 100, tx: 200) == .slow)   // 0.5×
    }

    @Test func speedTierUnknownWhenNoTranscription() {
        let row = RecordingPerformanceBuilder.makeRow(
            ModelPerformanceRecord(aiModel: "gemini", aiTime: 10),
            modelAverageRealtime: nil
        )
        #expect(row.speedTier == .unknown)
        #expect(row.transcriptionRealtime == nil)
    }

    // MARK: - Slower-than-usual flag

    @Test func flagsRunWellBelowModelAverage() {
        // model average realtime 4.0; this run is 1.0× → below 0.6 × 4.0 = 2.4.
        let record = ModelPerformanceRecord(
            transcriptionModel: "M", audioDuration: 100, transcriptionTime: 100, inferenceTime: 90
        )
        let row = RecordingPerformanceBuilder.makeRow(record, modelAverageRealtime: 4.0)
        #expect(row.isSlowerThanUsual)
    }

    @Test func doesNotFlagTypicalRun() {
        let record = ModelPerformanceRecord(
            transcriptionModel: "M", audioDuration: 100, transcriptionTime: 25, inferenceTime: 20
        )
        // 4.0× vs average 4.0× → not slow.
        let row = RecordingPerformanceBuilder.makeRow(record, modelAverageRealtime: 4.0)
        #expect(!row.isSlowerThanUsual)
    }

    @Test func doesNotFlagWithoutBaseline() {
        let record = ModelPerformanceRecord(
            transcriptionModel: "M", audioDuration: 100, transcriptionTime: 100
        )
        let row = RecordingPerformanceBuilder.makeRow(record, modelAverageRealtime: nil)
        #expect(!row.isSlowerThanUsual)
    }

    // MARK: - Builder (ordering, limit, baseline gating)

    @Test func rowsAreNewestFirstAndLimited() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let records = (0..<5).map { i in
            ModelPerformanceRecord(
                date: base.addingTimeInterval(Double(i) * 60),
                transcriptionModel: "M", audioDuration: 100, transcriptionTime: 25
            )
        }
        let rows = RecordingPerformanceBuilder.rows(from: records, limit: 3)
        #expect(rows.count == 3)
        // Newest (i=4) first.
        #expect(rows[0].date > rows[1].date)
        #expect(rows[1].date > rows[2].date)
    }

    @Test func baselineNeedsMinimumSessionsBeforeFlagging() {
        // Two fast runs + one slow run of the same model. With only 3 sessions the
        // baseline is allowed (min = 3); the slow run should flag.
        let base = Date(timeIntervalSince1970: 2_000_000)
        let fast1 = ModelPerformanceRecord(date: base, transcriptionModel: "M", audioDuration: 100, transcriptionTime: 20)
        let fast2 = ModelPerformanceRecord(date: base.addingTimeInterval(60), transcriptionModel: "M", audioDuration: 100, transcriptionTime: 20)
        let slow = ModelPerformanceRecord(date: base.addingTimeInterval(120), transcriptionModel: "M", audioDuration: 100, transcriptionTime: 100)
        let rows = RecordingPerformanceBuilder.rows(from: [fast1, fast2, slow])
        let slowRow = rows.first { $0.id == slow.id }
        #expect(slowRow?.isSlowerThanUsual == true)
    }

    @Test func usesFallbackLabelWhenMissing() {
        let record = ModelPerformanceRecord(transcriptionModel: "M", audioDuration: 100, transcriptionTime: 25)
        let row = RecordingPerformanceBuilder.makeRow(record, modelAverageRealtime: nil)
        #expect(!row.label.isEmpty)  // formatted date fallback
    }
}
