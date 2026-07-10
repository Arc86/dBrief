import Testing
import Foundation
@testable import dBrief

@Suite("ModelPerformanceStore.clear")
struct ModelPerformanceStoreClearTests {
    @Test("clear() removes all recorded sessions")
    func clearEmpties() async {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-\(UUID().uuidString).json")
        let store = ModelPerformanceStore(url: tmp)
        await store.append(ModelPerformanceRecord(transcriptionModel: "M",
                                                  audioDuration: 60,
                                                  transcriptionTime: 10))
        #expect(await store.load().count == 1)

        await store.clear()
        #expect(await store.load().isEmpty)

        try? FileManager.default.removeItem(at: tmp)
    }
}

@Suite("ModelPerformanceStore.averageTranscriptionRealtime")
struct ModelPerformanceRealtimeTests {
    private func makeStore() -> (ModelPerformanceStore, URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-\(UUID().uuidString).json")
        return (ModelPerformanceStore(url: tmp), tmp)
    }

    @Test("averages audio/wall ratios for the model")
    func averagesRatios() async {
        let (store, tmp) = makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // 120s audio in 60s wall = 2.0×; 90s audio in 90s wall = 1.0× → avg 1.5×.
        await store.append(ModelPerformanceRecord(transcriptionModel: "M", audioDuration: 120, transcriptionTime: 60))
        await store.append(ModelPerformanceRecord(transcriptionModel: "M", audioDuration: 90, transcriptionTime: 90))
        let avg = await store.averageTranscriptionRealtime(forModel: "M")
        #expect(avg == 1.5)
    }

    @Test("excludes zero-duration records so a re-transcribe bug can't poison the ratio")
    func excludesZeroDuration() async {
        let (store, tmp) = makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // A genuine session plus a 0-duration record (the pre-fix retranscribe bug).
        await store.append(ModelPerformanceRecord(transcriptionModel: "M", audioDuration: 120, transcriptionTime: 60))
        await store.append(ModelPerformanceRecord(transcriptionModel: "M", audioDuration: 0, transcriptionTime: 761))
        // The 0-duration record is skipped → the average reflects only the real 2.0×.
        let avg = await store.averageTranscriptionRealtime(forModel: "M")
        #expect(avg == 2.0)
    }

    @Test("returns nil when the model has no usable history")
    func nilWithoutHistory() async {
        let (store, tmp) = makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        await store.append(ModelPerformanceRecord(transcriptionModel: "Other", audioDuration: 60, transcriptionTime: 30))
        // Wrong model, and a record with no transcription time at all.
        await store.append(ModelPerformanceRecord(transcriptionModel: "M", audioDuration: 60, transcriptionTime: nil))
        #expect(await store.averageTranscriptionRealtime(forModel: "M") == nil)
    }
}
