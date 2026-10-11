import Foundation

/// OAuth client credentials. `make app` stamps them into the bundle's Info.plist
/// from the environment or `packaging/secrets.env`; they are never in git, so
/// builds without them (`swift run`, Homebrew, CI) hide TickTick.
struct TickTickCredentials: Equatable, Sendable {
    static let clientIDKey = "DBTickTickClientID"
    static let clientSecretKey = "DBTickTickClientSecret"
    static let bundled = TickTickCredentials(infoDictionary: Bundle.main.infoDictionary)

    let clientID: String
    let clientSecret: String

    init(clientID: String, clientSecret: String) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(infoDictionary: [String: Any]?) {
        self.init(clientID: infoDictionary?[Self.clientIDKey] as? String ?? "",
                  clientSecret: infoDictionary?[Self.clientSecretKey] as? String ?? "")
    }

    var isConfigured: Bool { !clientID.isEmpty && !clientSecret.isEmpty }
}

enum TickTickError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case notSignedIn
    case stateMismatch
    case missingCode
    case unauthorized
    case invalidResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "TickTick isn't available in this build."
        case .notSignedIn: "Sign in to TickTick first."
        case .stateMismatch: "The TickTick sign-in response didn't match this request. Try again."
        case .missingCode: "TickTick didn't return a sign-in code. Try again."
        case .unauthorized: "Your TickTick sign-in expired. Sign in again."
        case .invalidResponse: "TickTick returned a response dBrief couldn't read."
        case .http(let code): "TickTick returned an error (\(code))."
        }
    }
}

/// TickTick Open API constants and request builders (developer.ticktick.com/docs).
/// TickTick has no PKCE: the code exchange authenticates with the client secret.
enum TickTickAPI {
    static let authorizeEndpoint = URL(string: "https://ticktick.com/oauth/authorize")!
    static let tokenEndpoint = URL(string: "https://ticktick.com/oauth/token")!
    static let revokeEndpoint = URL(string: "https://api.ticktick.com/oauth/revoke")!
    static let apiBase = URL(string: "https://api.ticktick.com")!
    static let redirectURI = "dbrief://oauth/ticktick"
    static let callbackScheme = "dbrief"
    static let scope = "tasks:read tasks:write"
    static let inboxProjectID = "inbox"

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func makeState() -> String { UUID().uuidString }

    static func authorizeURL(clientID: String, state: String) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
        ]
        return components.url!
    }

    static func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == expectedState else {
            throw TickTickError.stateMismatch
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw TickTickError.missingCode
        }
        return code
    }

    static func tokenRequest(code: String, credentials: TickTickCredentials) -> URLRequest {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let basic = Data("\(credentials.clientID):\(credentials.clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            ("code", code), ("grant_type", "authorization_code"),
            ("scope", scope), ("redirect_uri", redirectURI),
        ])
        return request
    }

    static func accessToken(from data: Data) throws -> String {
        struct Response: Decodable {
            let accessToken: String?
            enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
        }
        guard let token = (try? JSONDecoder().decode(Response.self, from: data))?.accessToken?
                .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw TickTickError.invalidResponse
        }
        return token
    }

    static func formBody(_ pairs: [(String, String)]) -> Data {
        Data(pairs.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")"
        }.joined(separator: "&").utf8)
    }

    static func apiRequest(_ path: String, token: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: apiBase.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    static func createTaskBody(title: String, content: String, projectID: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["title": title, "content": content, "projectId": projectID],
                                   options: [.sortedKeys])
    }

    /// Short id of one delivery batch. Retries match on it, never on the
    /// localized date, so a locale or time-zone change can't hide a task.
    static func reference(for batchID: UUID) -> String {
        String(batchID.uuidString.lowercased().prefix(8))
    }

    static func content(_ content: String?, carries reference: String) -> Bool {
        content?.contains("(ref \(reference))") == true
    }

    /// The line under every task; its "(ref …)" tells a retry which tasks a
    /// lost response already created for this meeting.
    static func taskContent(meetingTitle: String, date: Date, reference: String,
                            locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let title = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return "From “\(title.isEmpty ? "Untitled meeting" : title)” · \(formatter.string(from: date)) — added by dBrief (ref \(reference))"
    }
}
