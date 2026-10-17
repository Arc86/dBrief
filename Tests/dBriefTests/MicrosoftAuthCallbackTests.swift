import Foundation
import Testing
@testable import dBrief

/// ASWebAuthenticationSession calls its completion on an XPC queue. A handler
/// that inherits @MainActor isolation traps there (seen with TickTick on macOS 26).
@Suite("Microsoft sign-in callback")
struct MicrosoftAuthCallbackTests {
    private func complete(url: URL?, error: Error?) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let completion = MicrosoftAuthService.authCompletion(continuation)
            DispatchQueue.global().async { completion(url, error) }
        }
    }

    @Test func callbackFromABackgroundQueueReturnsTheURL() async throws {
        let url = try #require(URL(string: "dbrief://oauth/callback?code=x"))
        #expect(try await complete(url: url, error: nil) == url)
    }

    @Test func errorsAndEmptyCallbacksThrow() async {
        await #expect(throws: CocoaError.self) { try await complete(url: nil, error: CocoaError(.userCancelled)) }
        await #expect(throws: MicrosoftAuthError.self) { try await complete(url: nil, error: nil) }
    }
}
