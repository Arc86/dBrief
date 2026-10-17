import Foundation
import Testing
@testable import dBrief

@Suite("TickTick API requests")
struct TickTickAPITests {
    private let credentials = TickTickCredentials(clientID: "client-id", clientSecret: "s3cret/+=")

    @Test func credentialsNeedBothValues() {
        #expect(!TickTickCredentials(infoDictionary: nil).isConfigured)
        #expect(!TickTickCredentials(infoDictionary: [TickTickCredentials.clientIDKey: "id"]).isConfigured)
        #expect(!TickTickCredentials(infoDictionary: [TickTickCredentials.clientIDKey: " ",
                                                      TickTickCredentials.clientSecretKey: "secret"]).isConfigured)
        #expect(TickTickCredentials(infoDictionary: [TickTickCredentials.clientIDKey: "id",
                                                     TickTickCredentials.clientSecretKey: "secret"]).isConfigured)
    }

    @Test func authorizeURLCarriesClientScopeStateAndRedirect() throws {
        let url = TickTickAPI.authorizeURL(clientID: "client-id", state: "state-123")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "ticktick.com")
        #expect(components.path == "/oauth/authorize")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items == ["client_id": "client-id", "scope": "tasks:read tasks:write", "state": "state-123",
                          "redirect_uri": "http://127.0.0.1:47213/ticktick/callback", "response_type": "code"])
    }

    @Test func callbackNeedsMatchingStateAndCode() throws {
        let good = try #require(URL(string: "http://127.0.0.1:47213/ticktick/callback?code=abc&state=s1"))
        #expect(try TickTickAPI.authorizationCode(from: good, expectedState: "s1") == "abc")
        #expect(throws: TickTickError.stateMismatch) {
            try TickTickAPI.authorizationCode(from: good, expectedState: "other")
        }
        #expect(throws: TickTickError.stateMismatch) {
            try TickTickAPI.authorizationCode(from: URL(string: "http://127.0.0.1:47213/ticktick/callback?code=abc")!, expectedState: "s1")
        }
        #expect(throws: TickTickError.missingCode) {
            try TickTickAPI.authorizationCode(from: URL(string: "http://127.0.0.1:47213/ticktick/callback?state=s1")!, expectedState: "s1")
        }
    }

    @Test func tokenRequestUsesBasicAuthAndFormBody() throws {
        let request = TickTickAPI.tokenRequest(code: "the code", credentials: credentials)
        #expect(request.url?.absoluteString == "https://ticktick.com/oauth/token")
        #expect(request.httpMethod == "POST")
        let expectedBasic = "Basic " + Data("client-id:s3cret/+=".utf8).base64EncodedString()
        #expect(request.value(forHTTPHeaderField: "Authorization") == expectedBasic)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body == "code=the%20code&grant_type=authorization_code&scope=tasks%3Aread%20tasks%3Awrite&redirect_uri=http%3A%2F%2F127.0.0.1%3A47213%2Fticktick%2Fcallback")
        #expect(!body.contains("s3cret"))
    }

    @Test func formBodyPercentEncodesEverythingOutsideUnreservedASCII() {
        #expect(String(decoding: TickTickAPI.formBody([("k", "é&= a~")]), as: UTF8.self) == "k=%C3%A9%26%3D%20a~")
    }

    @Test func accessTokenParsing() throws {
        #expect(try TickTickAPI.accessToken(from: Data(#"{"access_token":"tok","token_type":"bearer"}"#.utf8)) == "tok")
        #expect(throws: TickTickError.invalidResponse) {
            try TickTickAPI.accessToken(from: Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        #expect(throws: TickTickError.invalidResponse) {
            try TickTickAPI.accessToken(from: Data(#"{"access_token":"  "}"#.utf8))
        }
    }

    @Test func apiRequestSetsBearerPathAndJSONBody() throws {
        let get = TickTickAPI.apiRequest("open/v1/project", token: "tok")
        #expect(get.url?.absoluteString == "https://api.ticktick.com/open/v1/project")
        #expect(get.httpMethod == "GET")
        #expect(get.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(get.httpBody == nil)
        let post = TickTickAPI.apiRequest("open/v1/task", token: "tok", method: "POST", body: Data("{}".utf8))
        #expect(post.httpMethod == "POST")
        #expect(post.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(post.httpBody == Data("{}".utf8))
    }

    @Test func createTaskBodyHasRequiredFields() throws {
        let body = try TickTickAPI.createTaskBody(title: "Send deck", content: "From x", projectID: "inbox")
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["title": "Send deck", "content": "From x", "projectId": "inbox"])
    }

    @Test func taskContentIsStableForTheSameMeeting() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 14:13 UTC
        let locale = Locale(identifier: "en_US")
        let zone = try #require(TimeZone(identifier: "UTC"))
        let content = TickTickAPI.taskContent(meetingTitle: " Q3 “review” 🚀 ", date: date, reference: "1a2b3c4d",
                                              locale: locale, timeZone: zone)
        #expect(content == "From “Q3 “review” 🚀” · Sep 21, 2026 — added by dBrief (ref 1a2b3c4d)")
        #expect(TickTickAPI.taskContent(meetingTitle: "  ", date: date, reference: "1a2b3c4d", locale: locale, timeZone: zone)
            == "From “Untitled meeting” · Sep 21, 2026 — added by dBrief (ref 1a2b3c4d)")
    }

    @Test func referenceMatchingIgnoresTheLocalizedDate() throws {
        let id = try #require(UUID(uuidString: "1A2B3C4D-0000-4000-8000-000000000000"))
        #expect(TickTickAPI.reference(for: id) == "1a2b3c4d")
        let reformatted = "From “Weekly sync” · 21 sep 2026 — added by dBrief (ref 1a2b3c4d)"
        #expect(TickTickAPI.content(reformatted, carries: "1a2b3c4d"))
        #expect(!TickTickAPI.content("From “Weekly sync” · Sep 21, 2026 — added by dBrief (ref 99999999)", carries: "1a2b3c4d"))
        #expect(!TickTickAPI.content(nil, carries: "1a2b3c4d"))
    }

    @Test func loopbackRequestYieldsTheCallbackURL() throws {
        let request = "GET /ticktick/callback?code=abc&state=s1 HTTP/1.1\r\nHost: 127.0.0.1:47213\r\n\r\n"
        let url = try #require(TickTickAPI.callbackURL(fromRequest: request))
        #expect(try TickTickAPI.authorizationCode(from: url, expectedState: "s1") == "abc")
        #expect(TickTickAPI.callbackURL(fromRequest: "GET /favicon.ico HTTP/1.1\r\n\r\n") == nil)
        #expect(TickTickAPI.callbackURL(fromRequest: "POST /ticktick/callback?code=a HTTP/1.1\r\n\r\n") == nil)
        #expect(TickTickAPI.callbackURL(fromRequest: "GET /ticktick/callbackish?code=a HTTP/1.1\r\n\r\n") == nil)
        #expect(TickTickAPI.callbackURL(fromRequest: "garbage") == nil)
    }

    @Test func statesAreUnique() {
        #expect(TickTickAPI.makeState() != TickTickAPI.makeState())
    }
}
