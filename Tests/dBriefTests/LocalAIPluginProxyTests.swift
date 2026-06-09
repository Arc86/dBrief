import Testing
import Foundation
import dBriefWire
@testable import dBrief

@Suite struct LocalAIPluginProxyTests {
    @Test func transcribeForwardsAndReturns() async throws {
        let conn = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
                                    supportBase: URL(fileURLWithPath: "/tmp"),
                                    environment: ["STUB_MODE": "echo"])
        let svc = LocalAIPluginService(connection: conn)
        let result = try await svc.transcribe(fileURL: URL(fileURLWithPath: "/a.m4a"),
                                               initialPrompt: nil, whisperConfig: .default)
        #expect(result.text == "echo")
        await conn.shutdown()
    }
}
