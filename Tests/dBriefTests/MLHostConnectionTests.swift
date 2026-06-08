import Testing
import Foundation
import dBriefWire
@testable import dBrief

private func stubURL() -> URL {
    URL(fileURLWithPath: ".build/debug/dBriefMLHostStub")
}

@Suite struct MLHostConnectionTests {
    @Test func callReturnsResult() async throws {
        let conn = MLHostConnection(binaryURL: stubURL(),
                                    supportBase: URL(fileURLWithPath: "/tmp"),
                                    environment: ["STUB_MODE": "echo"])
        let event = try await conn.call(.transcribe(path: "/a.m4a", initialPrompt: nil, config: .default, safeMode: false))
        guard case let .transcriptionResult(tr) = event else { Issue.record("no result"); return }
        #expect(tr.text == "echo")
        await conn.shutdown()
    }

    @Test func errorEventThrowsWireError() async {
        let conn = MLHostConnection(binaryURL: stubURL(),
                                    supportBase: URL(fileURLWithPath: "/tmp"),
                                    environment: ["STUB_MODE": "error"])
        await #expect(throws: WireError.self) {
            _ = try await conn.call(.transcribe(path: "/a.m4a", initialPrompt: nil, config: .default, safeMode: false))
        }
        await conn.shutdown()
    }

    @Test func crashSurfacesHelperCrashedError() async {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stub_crashed"))
        let conn = MLHostConnection(binaryURL: stubURL(),
                                    supportBase: URL(fileURLWithPath: "/tmp"),
                                    environment: ["STUB_MODE": "crash-once"])
        await #expect(throws: MLHostError.helperCrashed) {
            _ = try await conn.call(.transcribe(path: "/a.m4a", initialPrompt: nil, config: .default, safeMode: false))
        }
        await conn.shutdown()
    }
}
