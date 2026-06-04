import AppKit
import AuthenticationServices
import CryptoKit
import OSLog

struct AccountInfo: Sendable, Equatable {
    let displayName: String
    let email: String
}

enum MicrosoftAuthError: Error {
    case notSignedIn
    case tokenExchangeFailed
    case refreshFailed
    case missingAuthCode
}

@MainActor
@Observable
final class MicrosoftAuthService {
    static let clientID = "YOUR-AZURE-CLIENT-ID"
    private static let redirectURI = "dbrief://oauth/callback"
    private static let scopes = "Calendars.Read offline_access"
    private static let authorizeURL = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
    private static let tokenURL = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
    private static let graphMeURL = "https://graph.microsoft.com/v1.0/me"

    private(set) var isSignedIn: Bool = false
    private(set) var accountInfo: AccountInfo?
    private var activeAuthSession: ASWebAuthenticationSession?

    init() {
        let stored = KeychainHelper.get(for: .microsoftAccessToken)
        isSignedIn = !stored.isEmpty
    }

    func signIn() async throws {
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
        storeTokens(tokens)
        isSignedIn = true
        accountInfo = try? await fetchAccountInfo(accessToken: tokens.accessToken)
    }

    func signOut() {
        KeychainHelper.set("", for: .microsoftAccessToken)
        KeychainHelper.set("", for: .microsoftRefreshToken)
        KeychainHelper.set("", for: .microsoftTokenExpiry)
        isSignedIn = false
        accountInfo = nil
    }

    /// Returns a valid access token, refreshing automatically if expired.
    /// Throws `MicrosoftAuthError.notSignedIn` if no refresh token is available.
    func getValidAccessToken() async throws -> String {
        let accessToken = KeychainHelper.get(for: .microsoftAccessToken)
        let expiryString = KeychainHelper.get(for: .microsoftTokenExpiry)

        if !accessToken.isEmpty,
           let expiry = ISO8601DateFormatter().date(from: expiryString),
           Date().addingTimeInterval(60) < expiry {
            return accessToken
        }

        let refreshToken = KeychainHelper.get(for: .microsoftRefreshToken)
        guard !refreshToken.isEmpty else {
            isSignedIn = false
            throw MicrosoftAuthError.notSignedIn
        }

        do {
            let tokens = try await refreshAccessToken(refreshToken)
            storeTokens(tokens)
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

    private func storeTokens(_ tokens: TokenResponse) {
        KeychainHelper.set(tokens.accessToken, for: .microsoftAccessToken)
        if let rt = tokens.refreshToken {
            KeychainHelper.set(rt, for: .microsoftRefreshToken)
        }
        let expiry = Date().addingTimeInterval(TimeInterval(tokens.expiresIn))
        KeychainHelper.set(ISO8601DateFormatter().string(from: expiry), for: .microsoftTokenExpiry)
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
        let (data, _) = try await URLSession.shared.data(for: request)
        let me = try JSONDecoder().decode(MeResponse.self, from: data)
        return AccountInfo(
            displayName: me.displayName ?? "",
            email: me.mail ?? me.userPrincipalName ?? ""
        )
    }

    // MARK: - Utilities

    private func urlEncodeParams(_ params: [String: String]) -> Data? {
        params.map { k, v in
            let encoded = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
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
