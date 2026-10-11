import AppKit
import Foundation
import os
import dBriefWire

/// Sign in with TickTick (OAuth2 authorization code; TickTick has no PKCE, so
/// the exchange uses the bundled client secret). The sign-in page opens in the
/// default browser and redirects to a one-shot loopback listener on
/// 127.0.0.1:47213 (`TickTickLoopbackServer`). Only the access token is stored,
/// in the Keychain. TickTick documents no refresh token: a 401 marks the
/// session expired (`TickTickSession`) and the user signs in again.
@MainActor
@Observable
final class TickTickAuthService {
    static var isConfigured: Bool { TickTickCredentials.bundled.isConfigured }
    static let signInTimeout: Duration = .seconds(300)

    private(set) var isSignedIn = false
    private(set) var sessionExpired = false
    /// True while the browser sign-in is open; Settings offers Cancel.
    private(set) var isSigningIn = false
    private var activeServer: TickTickLoopbackServer?
    private let client: TickTickClient
    private let log = Logger.integrations

    init(client: TickTickClient = TickTickClient()) {
        self.client = client
        reload()
    }

    /// Re-reads the Keychain and defaults: a send may have expired the session.
    func reload() {
        isSignedIn = !((try? KeychainHelper.get(for: .tickTickAccessToken)) ?? "").isEmpty
        sessionExpired = UserDefaults.standard.bool(forKey: TickTickSession.expiredKey)
    }

    func accessToken() throws -> String {
        let token = try KeychainHelper.get(for: .tickTickAccessToken)
        guard !token.isEmpty else { throw TickTickError.notSignedIn }
        return token
    }

    /// Opens the TickTick sign-in page in the browser and waits for its redirect.
    /// Returns without an error when cancelled.
    func signIn() async throws {
        let credentials = TickTickCredentials.bundled
        guard credentials.isConfigured else { throw TickTickError.notConfigured }
        guard activeServer == nil else { return }
        let server: TickTickLoopbackServer
        do {
            server = try TickTickLoopbackServer()
            _ = try await server.start()
        } catch {
            log.error("TickTick sign-in listener failed: \(error.localizedDescription, privacy: .public)")
            throw TickTickError.callbackPortUnavailable
        }
        activeServer = server
        isSigningIn = true
        defer {
            server.cancel()
            activeServer = nil
            isSigningIn = false
        }
        let state = TickTickAPI.makeState()
        NSWorkspace.shared.open(TickTickAPI.authorizeURL(clientID: credentials.clientID, state: state))
        let timeout = Task.detached {
            try await Task.sleep(for: Self.signInTimeout)
            server.cancel(with: TickTickError.signInTimedOut)
        }
        defer { timeout.cancel() }
        let callback: URL
        do {
            callback = try await server.waitForCallback()
        } catch is CancellationError {
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let code = try TickTickAPI.authorizationCode(from: callback, expectedState: state)
        let token = try await client.exchangeCode(code, credentials: credentials)
        try KeychainHelper.set(token, for: .tickTickAccessToken)
        UserDefaults.standard.removeObject(forKey: TickTickSession.expiredKey)
        reload()
        log.info("TickTick sign-in succeeded")
    }

    func cancelSignIn() {
        activeServer?.cancel()
    }

    func signOut() async {
        cancelSignIn()
        if let token = try? accessToken() {
            await client.revoke(token: token, credentials: TickTickCredentials.bundled)
        }
        do {
            try KeychainHelper.set("", for: .tickTickAccessToken)
        } catch {
            log.error("TickTick credential removal failed: \(error.localizedDescription, privacy: .public)")
        }
        UserDefaults.standard.removeObject(forKey: TickTickSession.expiredKey)
        reload()
    }
}
