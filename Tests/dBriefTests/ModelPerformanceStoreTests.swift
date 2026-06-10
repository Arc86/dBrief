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
