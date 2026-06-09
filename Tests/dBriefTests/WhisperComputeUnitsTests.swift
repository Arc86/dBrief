import Testing
import dBriefWire

struct WhisperComputeUnitsTests {
    @Test("friendlyName maps .all to Automatic, keeps technical names otherwise")
    func testFriendlyName() {
        #expect(WhisperComputeUnits.all.friendlyName == "Automatic")
        #expect(WhisperComputeUnits.cpuAndNeuralEngine.friendlyName == "Neural Engine")
        #expect(WhisperComputeUnits.cpuAndGPU.friendlyName == "Metal GPU")
    }
}
