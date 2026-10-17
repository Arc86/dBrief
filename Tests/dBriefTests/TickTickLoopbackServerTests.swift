import Foundation
import Testing
@testable import dBrief

@Suite("TickTick loopback sign-in listener")
struct TickTickLoopbackServerTests {
    private func get(_ port: UInt16, _ path: String) async throws -> (Int, String) {
        let url = try #require(URL(string: "http://127.0.0.1:\(port)\(path)"))
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    @Test func returnsTheCallbackAndIgnoresOtherRequests() async throws {
        let server = try TickTickLoopbackServer(port: 0)
        defer { server.cancel() }
        let port = try await server.start()
        let (faviconStatus, _) = try await get(port, "/favicon.ico")
        #expect(faviconStatus == 404)
        async let callback = server.waitForCallback()
        let (status, body) = try await get(port, "/ticktick/callback?code=abc&state=s1")
        #expect(status == 200)
        #expect(body.contains("dBrief"))
        let url = try await callback
        #expect(try TickTickAPI.authorizationCode(from: url, expectedState: "s1") == "abc")
    }

    @Test func cancellingEndsTheWait() async throws {
        let server = try TickTickLoopbackServer(port: 0)
        _ = try await server.start()
        server.cancel(with: TickTickError.signInTimedOut)
        await #expect(throws: TickTickError.signInTimedOut) { try await server.waitForCallback() }
    }
}
