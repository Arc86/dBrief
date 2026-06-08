import Testing
import Foundation
import dBriefWire
@testable import dBrief

@Suite struct TranscribeRetryTests {
    @Test func retriesOnceAfterCrashThenSucceeds() async throws {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stub_crashed"))
        let conn = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
                                    supportBase: URL(fileURLWithPath: "/tmp"),
                                    environment: ["STUB_MODE": "crash-once"])
        let svc = LocalAIPluginService(connection: conn)
        let result = try await svc.transcribe(fileURL: URL(fileURLWithPath: "/a.m4a"),
                                               initialPrompt: nil, whisperConfig: .default)
        #expect(result.text == "recovered")   // first call crashed, retry returned this
        await conn.shutdown()
    }

    @Test func secondCrashSurfacesCleanError() async {
        let conn = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
                                    supportBase: URL(fileURLWithPath: "/tmp"),
                                    environment: ["STUB_MODE": "crash-always"])
        await #expect(throws: MLHostError.helperCrashed) {
            _ = try await conn.call(.transcribe(path: "/a.m4a", initialPrompt: nil, config: .default, safeMode: false))
        }
        await conn.shutdown()
    }
}
