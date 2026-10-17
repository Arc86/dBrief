import Foundation
import Testing
@testable import dBrief

@Suite struct KeychainTestIsolationTests {
    /// Test runs must never touch the user's real Keychain items: reading them shows a
    /// login-password prompt on every run, and writing could overwrite real secrets.
    @Test func testRunsKeepSecretsInMemory() throws {
        #expect(KeychainHelper.usesInMemoryStore)
        let id = UUID()
        try KeychainHelper.setEndpointAPIKey("synthetic-key", endpointID: id)
        #expect(try KeychainHelper.endpointAPIKey(endpointID: id) == "synthetic-key")
        try KeychainHelper.setEndpointAPIKey("", endpointID: id)
        #expect(try KeychainHelper.endpointAPIKey(endpointID: id) == "")
    }
}
