import Foundation
import Testing
import dBriefWire

@Suite struct MLLifecycleDiagnosticsTests {
    @Test func diagnosticsPersistAcrossWritersAndRotate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.jsonl")
        let first = MLLifecycleDiagnostics(url: url, maxBytes: 800)
        first.record(.memoryWarning)
        let second = MLLifecycleDiagnostics(url: url, maxBytes: 800)
        second.record(.recoveryStarted, operation: "whisper", computeUnits: "cpuAndGPU", workers: 4)
        let initial = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(initial.count == 2)
        let record = try #require(JSONSerialization.jsonObject(with: Data(initial[1].utf8)) as? [String: Any])
        #expect(record["event"] as? String == "recoveryStarted")
        #expect(record["workers"] as? Int == 4)
        #expect(record["date"] as? String != nil)
        #expect(Set(record.keys) == ["date", "processID", "event", "operation", "computeUnits", "workers"])
        for _ in 0..<20 { second.record(.cleanupCompleted) }
        for file in [url, url.appendingPathExtension("previous")] {
            let data = try Data(contentsOf: file)
            #expect(data.count <= 800)
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                _ = try JSONSerialization.jsonObject(with: Data(line.utf8))
            }
        }
    }
}
