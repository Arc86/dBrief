import AppKit
import AuthenticationServices
import Foundation
import os
import dBriefWire

/// Sign in with TickTick (OAuth2 authorization code; TickTick has no PKCE, so
/// the exchange uses the bundled client secret). Only the access token is
/// stored, in the Keychain. TickTick documents no refresh token: a 401 marks
/// the session expired (`TickTickSession`) and the user signs in again.
@MainActor
@Observable
final class TickTickAuthService {
    static var isConfigured: Bool { TickTickCredentials.bundled.isConfigured }

    private(set) var isSignedIn = false
    private(set) var sessionExpired = false
    private var activeSession: ASWebAuthenticationSession?
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

    /// Returns without an error when the user closes the sign-in window.
    func signIn() async throws {
        let credentials = TickTickCredentials.bundled
        guard credentials.isConfigured else { throw TickTickError.notConfigured }
        guard activeSession == nil else { return }
        let state = TickTickAPI.makeState()
        let authURL = TickTickAPI.authorizeURL(clientID: credentials.clientID, state: state)
        let callback: URL
        do {
            callback = try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(url: authURL,
                                                         callbackURLScheme: TickTickAPI.callbackScheme) { [weak self] url, error in
                    self?.activeSession = nil
                    if let url {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: error ?? TickTickError.missingCode)
                    }
                }
                session.presentationContextProvider = WebAuthPresentationContext.shared
                session.prefersEphemeralWebBrowserSession = false
                activeSession = session
                session.start()
            }
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        }
        let code = try TickTickAPI.authorizationCode(from: callback, expectedState: state)
        let token = try await client.exchangeCode(code, credentials: credentials)
        try KeychainHelper.set(token, for: .tickTickAccessToken)
        UserDefaults.standard.removeObject(forKey: TickTickSession.expiredKey)
        reload()
        log.info("TickTick sign-in succeeded")
    }

    func signOut() async {
        activeSession?.cancel()
        activeSession = nil
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
