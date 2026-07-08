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
        let event = try await conn.call(.transcribe(path: "/a.m4a", initialPrompt: nil, config: .default, safeMode: false, unloadAfter: true))
        guard case let .transcriptionResult(tr) = event else { Issue.record("no result"); return }
        #expect(tr.text == "echo")
        await conn.shutdown()
    }

    @Test func errorEventThrowsWireError() async {
        let conn = MLHostConnection(binaryURL: stubURL(),
                                    supportBase: URL(fileURLWithPath: "/tmp"),
                                    environment: ["STUB_MODE": "error"])
        await #expect(throws: WireError.self) {
            _ = try await conn.call(.transcribe(path: "/a.m4a", initialPrompt: nil, config: .default, safeMode: false, unloadAfter: true))
        }
        await conn.shutdown()
    }

    @Test func crashSurfacesHelperCrashedError() async {
        let conn = MLHostConnection(binaryURL: stubURL(),
                                    supportBase: URL(fileURLWithPath: "/tmp"),
                                    environment: ["STUB_MODE": "crash-once", "STUB_FLAG_1": uniqueFlagPath()])
        await #expect(throws: MLHostError.helperCrashed) {
            _ = try await conn.call(.transcribe(path: "/a.m4a", initialPrompt: nil, config: .default, safeMode: false, unloadAfter: true))
        }
        await conn.shutdown()
    }
}
