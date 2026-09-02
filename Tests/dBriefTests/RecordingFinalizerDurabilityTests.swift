import Foundation
import Testing
@testable import dBrief

@Suite("Recording finalizer durability")
struct RecordingFinalizerDurabilityTests {
    @Test
    func fallbackSkipsHeaderOnlyMicCopiesSystemAndPreservesRawTracks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbrief-finalizer-durability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let mic = root.appendingPathComponent("mic.caf")
        let system = root.appendingPathComponent("system.caf")
        let target = root.appendingPathComponent("master.m4a")
        try Data(repeating: 1, count: 128).write(to: mic)
        let expected = Data(repeating: 2, count: 5_000)
        try expected.write(to: system)

        try await RecordingFinalizer().fallbackPromoteTrack(
            tracks: CapturedTracks(systemURL: system, micURL: mic),
            targetURL: target
        )

        #expect(try Data(contentsOf: target) == expected)
        #expect(FileManager.default.fileExists(atPath: mic.path))
        #expect(FileManager.default.fileExists(atPath: system.path))
    }
}
