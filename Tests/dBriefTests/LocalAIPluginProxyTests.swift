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

    /// Cancelling processing force-unloads the helper, which then refuses every
    /// request. The next request must reach a fresh helper instead of failing
    /// with "ML helper is shutting down" until the app restarts. Repeated so a
    /// retired helper exiting after its replacement launched is also exercised.
    @Test func forceUnloadLeavesLaterRequestsWorking() async throws {
        let conn = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
                                    supportBase: URL(fileURLWithPath: "/tmp"),
                                    environment: ["STUB_MODE": "closes-after-unload"])
        let svc = LocalAIPluginService(connection: conn)
        for _ in 0..<5 {
            await svc.forceUnload()
            let result = try await svc.transcribe(fileURL: URL(fileURLWithPath: "/a.m4a"),
                                                   initialPrompt: nil, whisperConfig: .default)
            #expect(result.text == "echo")
        }
        await conn.shutdown()
    }
}
