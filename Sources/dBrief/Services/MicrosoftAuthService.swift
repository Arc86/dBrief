import AppKit
import AuthenticationServices
import CryptoKit
import OSLog

struct AccountInfo: Sendable, Equatable {
    let displayName: String
    let email: String
}

enum MicrosoftAuthError: Error {
    case notConfigured
    case notSignedIn
    case tokenExchangeFailed
    case refreshFailed
    case missingAuthCode
    case accountInfoFailed
}

@MainActor
@Observable
final class MicrosoftAuthService {
    static let placeholderClientID = "YOUR-AZURE-CLIENT-ID"
    static let clientID = placeholderClientID

    /// Testable predicate: a client ID is usable when it is non-empty and not the placeholder.
    static func isConfigured(clientID: String) -> Bool {
        !clientID.isEmpty && clientID != placeholderClientID
    }

    /// True when a real Azure client ID has been set (placeholder/empty = not configured).
    static var isConfigured: Bool { isConfigured(clientID: clientID) }
    private static let redirectURI = "dbrief://oauth/callback"
    private static let scopes = "Calendars.Read offline_access"
    private static let authorizeURL = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
    private static let tokenURL = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
    private static let graphMeURL = "https://graph.microsoft.com/v1.0/me"

    private(set) var isSignedIn: Bool = false
    private(set) var accountInfo: AccountInfo?
    private var activeAuthSession: ASWebAuthenticationSession?
    private let log = Logger.calendar

    init() {
        let accessToken = Self.loadSecretForStartup(.microsoftAccessToken)
        let refreshToken = Self.loadSecretForStartup(.microsoftRefreshToken)
        isSignedIn = !accessToken.isEmpty || !refreshToken.isEmpty
        if isSignedIn {
            accountInfo = loadPersistedAccountInfo()
        }
    }

    func signIn() async throws {
        guard Self.isConfigured else { throw MicrosoftAuthError.notConfigured }
        guard activeAuthSession == nil else { return }
        let codeVerifier = makeCodeVerifier()
        let codeChallenge = makeCodeChallenge(from: codeVerifier)

        var components = URLComponents(string: Self.authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "response_mode", value: "query"),
        ]
        let authURL = components.url!

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "dbrief"
            ) { [weak self] url, error in
                self?.activeAuthSession = nil
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: MicrosoftAuthError.missingAuthCode)
                }
            }
            session.presentationContextProvider = WebAuthPresentationContext.shared
            session.prefersEphemeralWebBrowserSession = false
            activeAuthSession = session
            session.start()
        }

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else {
            throw MicrosoftAuthError.missingAuthCode
        }

        let tokens = try await exchangeCode(code, codeVerifier: codeVerifier)
        try storeTokens(tokens)
        isSignedIn = true
        let info = try? await fetchAccountInfo(accessToken: tokens.accessToken)
        accountInfo = info
        if let info { persistAccountInfo(info) }
        log.info("Microsoft sign-in succeeded for \(self.accountInfo?.email ?? "unknown")")
    }

    func signOut() {
        log.info("Microsoft sign-out")
        activeAuthSession?.cancel()
        activeAuthSession = nil
        for key in [
            KeychainSecretKey.microsoftAccessToken,
            .microsoftRefreshToken,
            .microsoftTokenExpiry,
        ] {
            do {
                try KeychainHelper.set("", for: key)
            } catch {
                log.error("Microsoft credential removal failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        isSignedIn = false
        accountInfo = nil
        UserDefaults.standard.removeObject(forKey: Self.displayNameKey)
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
    }

    /// Returns a valid access token, refreshing automatically if expired.
    /// Throws `MicrosoftAuthError.notSignedIn` if no refresh token is available.
    func getValidAccessToken() async throws -> String {
        let accessToken = try KeychainHelper.get(for: .microsoftAccessToken)
        let expiryString = try KeychainHelper.get(for: .microsoftTokenExpiry)

        if !accessToken.isEmpty,
           let expiry = ISO8601DateFormatter().date(from: expiryString),
           Date().addingTimeInterval(60) < expiry {
            return accessToken
        }

        let refreshToken = try KeychainHelper.get(for: .microsoftRefreshToken)
        guard !refreshToken.isEmpty else {
            isSignedIn = false
            throw MicrosoftAuthError.notSignedIn
        }

        do {
            let tokens = try await refreshAccessToken(refreshToken)
            try storeTokens(tokens)
            return tokens.accessToken
        } catch {
            isSignedIn = false
            throw error
        }
    }

    // MARK: - PKCE helpers

    private func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private func makeCodeChallenge(from verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }

    // MARK: - Token exchange

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private func exchangeCode(_ code: String, codeVerifier: String) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = urlEncodeParams([
            "client_id": Self.clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "code_verifier": codeVerifier,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MicrosoftAuthError.tokenExchangeFailed
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func refreshAccessToken(_ refreshToken: String) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = urlEncodeParams([
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": Self.scopes,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MicrosoftAuthError.refreshFailed
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func storeTokens(_ tokens: TokenResponse) throws {
        try KeychainHelper.set(tokens.accessToken, for: .microsoftAccessToken)
        if let rt = tokens.refreshToken {
            try KeychainHelper.set(rt, for: .microsoftRefreshToken)
        }
        let expiry = Date().addingTimeInterval(TimeInterval(tokens.expiresIn))
        try KeychainHelper.set(
            ISO8601DateFormatter().string(from: expiry),
            for: .microsoftTokenExpiry
        )
    }

    private static func loadSecretForStartup(_ key: KeychainSecretKey) -> String {
        do {
            return try KeychainHelper.get(for: key)
        } catch {
            Logger.calendar.error(
                "Microsoft credential lookup failed: \(error.localizedDescription, privacy: .public)"
            )
            return ""
        }
    }

    private static let displayNameKey = "microsoft.accountDisplayName"
    private static let emailKey = "microsoft.accountEmail"

    private func persistAccountInfo(_ info: AccountInfo) {
        UserDefaults.standard.set(info.displayName, forKey: Self.displayNameKey)
        UserDefaults.standard.set(info.email, forKey: Self.emailKey)
    }

    private func loadPersistedAccountInfo() -> AccountInfo? {
        let name = UserDefaults.standard.string(forKey: Self.displayNameKey) ?? ""
        let email = UserDefaults.standard.string(forKey: Self.emailKey) ?? ""
        guard !name.isEmpty || !email.isEmpty else { return nil }
        return AccountInfo(displayName: name, email: email)
    }

    // MARK: - Account info

    private struct MeResponse: Decodable {
        let displayName: String?
        let mail: String?
        let userPrincipalName: String?
    }

    private func fetchAccountInfo(accessToken: String) async throws -> AccountInfo {
        var components = URLComponents(string: Self.graphMeURL)!
        components.queryItems = [URLQueryItem(name: "$select", value: "displayName,mail,userPrincipalName")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            log.error("Failed to fetch account info: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            throw MicrosoftAuthError.accountInfoFailed
        }
        let me = try JSONDecoder().decode(MeResponse.self, from: data)
        return AccountInfo(
            displayName: me.displayName ?? "",
            email: me.mail ?? me.userPrincipalName ?? ""
        )
    }

    // MARK: - Utilities

    private func urlEncodeParams(_ params: [String: String]) -> Data? {
        params.map { k, v in
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "=&+")
            let encoded = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
            return "\(k)=\(encoded)"
        }
        .joined(separator: "&")
        .data(using: .utf8)
    }
}

// MARK: - ASWebAuthenticationSession presentation context

private final class WebAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    static let shared = WebAuthPresentationContext()
    private override init() {}

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.windows.first(where: { $0.isVisible }) ?? NSWindow()
    }
}

// MARK: - Data base64url helper

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
