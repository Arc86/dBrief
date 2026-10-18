# TickTick Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a recording is processed, every action item becomes a task in the user's chosen TickTick list, after a one-time "Sign in with TickTick".

**Architecture:** A pure request layer (`TickTickAPI`) and a small HTTP client (`TickTickClient`) feed a new `.tickTick` branch in `IntegrationDispatchService`, which reuses the existing durable delivery pipeline (`IntegrationDeliveryBatch` + `IntegrationDeliveryCoordinator`). Per-item progress is stored on the delivery (`createdItems`), and retries match existing tasks before creating, so nothing is duplicated. A `@MainActor` `TickTickAuthService` runs the OAuth sign-in with `ASWebAuthenticationSession`; client credentials are stamped into the built app's `Info.plist` and never committed.

**Tech Stack:** Swift 6.2, SwiftUI, AuthenticationServices, URLSession, swift-testing, Python 3 (build script + its unittest).

**Spec:** `docs/superpowers/specs/2026-10-11-ticktick-integration-design.md`

## Global Constraints

- Branch: `ui/redesign`. Commit after each task. End every commit message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- The repo is **public**: never commit a TickTick client ID or secret. They come only from `TICKTICK_CLIENT_ID` / `TICKTICK_CLIENT_SECRET` or the gitignored `packaging/secrets.env`.
- Info.plist keys: `DBTickTickClientID`, `DBTickTickClientSecret`.
- Redirect URI: `dbrief://oauth/ticktick`. Scopes: `tasks:read tasks:write`. Inbox project id: `inbox`.
- Endpoints: authorize `https://ticktick.com/oauth/authorize`, token `https://ticktick.com/oauth/token` (Basic auth, form body), revoke `https://api.ticktick.com/oauth/revoke`, API base `https://api.ticktick.com`.
- Keychain account for the token: `integration.ticktick.accessToken`. UserDefaults flag for an expired sign-in: `ticktick.sessionExpired`.
- Task content line (also the duplicate-check marker): `From “<meeting title>” · <date, medium style> — added by dBrief`.
- New files use `Logger.integrations` (from `dBriefWire`), not ad-hoc loggers.
- Build: `swift build`. Tests: `swift build --build-tests` then `swift test --skip-build --filter <Suite>`; full suite `swift test --skip-build`.
- Settings UI uses only the existing Settings components (`SettingsCard`, `SettingsRow`, `SettingsStatusPill`, `.settingsPrimary` / `.settingsSecondary`).

## Review Focus

1. **Two identical action items in one meeting** ("Follow up" twice): a retry must match each existing TickTick task to at most one item and create the missing one. Test: Task 4 `duplicateTitlesClaimOneExistingTaskEach`.
2. **Meeting titles with quotes, emoji or surrounding spaces:** the content line must be identical on every attempt or the duplicate check silently fails. Test: Task 1 `taskContentIsStableForTheSameMeeting`.
3. **List changed between a failed attempt and the retry:** the retry must not send to the new list. Test: Task 4 `changedListBlocksTheRetry`.
4. **Whitespace-only action items:** never sent as empty tasks, and a meeting with only those is "skipped", not "failed". Test: Task 4 `sendsOneTaskPerNonEmptyItem`, `whitespaceOnlyItemsAreSkipped`.
5. **Settings saved before this change:** must still load every other integration's settings. Test: Task 2 `settingsSavedBeforeTickTickStillDecode`.

---

### Task 1: TickTick request layer and credentials

Pure, side-effect-free request building and parsing.

**Files:**
- Create: `Sources/dBrief/Services/TickTickAPI.swift`
- Test: `Tests/dBriefTests/TickTickAPITests.swift`

**Interfaces:**
- Produces:
  - `struct TickTickCredentials: Equatable, Sendable` — `static let clientIDKey`, `static let clientSecretKey`, `static let bundled`, `init(clientID:clientSecret:)`, `init(infoDictionary: [String: Any]?)`, `let clientID: String`, `let clientSecret: String`, `var isConfigured: Bool`.
  - `enum TickTickError: LocalizedError, Equatable, Sendable` — cases `notConfigured, notSignedIn, stateMismatch, missingCode, unauthorized, invalidResponse, http(Int)`.
  - `enum TickTickAPI` — `authorizeEndpoint`, `tokenEndpoint`, `revokeEndpoint`, `apiBase` (URLs); `redirectURI`, `callbackScheme`, `scope`, `inboxProjectID` (Strings); `makeState() -> String`; `authorizeURL(clientID:state:) -> URL`; `authorizationCode(from:expectedState:) throws -> String`; `tokenRequest(code:credentials:) -> URLRequest`; `accessToken(from: Data) throws -> String`; `formBody(_ pairs: [(String, String)]) -> Data`; `apiRequest(_ path: String, token: String, method: String = "GET", body: Data? = nil) -> URLRequest`; `createTaskBody(title:content:projectID:) throws -> Data`; `taskContent(meetingTitle:date:locale:timeZone:) -> String`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/dBriefTests/TickTickAPITests.swift`:

```swift
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
                          "redirect_uri": "dbrief://oauth/ticktick", "response_type": "code"])
    }

    @Test func callbackNeedsMatchingStateAndCode() throws {
        let good = try #require(URL(string: "dbrief://oauth/ticktick?code=abc&state=s1"))
        #expect(try TickTickAPI.authorizationCode(from: good, expectedState: "s1") == "abc")
        #expect(throws: TickTickError.stateMismatch) {
            try TickTickAPI.authorizationCode(from: good, expectedState: "other")
        }
        #expect(throws: TickTickError.stateMismatch) {
            try TickTickAPI.authorizationCode(from: URL(string: "dbrief://oauth/ticktick?code=abc")!, expectedState: "s1")
        }
        #expect(throws: TickTickError.missingCode) {
            try TickTickAPI.authorizationCode(from: URL(string: "dbrief://oauth/ticktick?state=s1")!, expectedState: "s1")
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
        #expect(body == "code=the%20code&grant_type=authorization_code&scope=tasks%3Aread%20tasks%3Awrite&redirect_uri=dbrief%3A%2F%2Foauth%2Fticktick")
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
        let content = TickTickAPI.taskContent(meetingTitle: " Q3 “review” 🚀 ", date: date, locale: locale, timeZone: zone)
        #expect(content == "From “Q3 “review” 🚀” · Sep 21, 2026 — added by dBrief")
        #expect(content == TickTickAPI.taskContent(meetingTitle: " Q3 “review” 🚀 ", date: date, locale: locale, timeZone: zone))
        #expect(TickTickAPI.taskContent(meetingTitle: "  ", date: date, locale: locale, timeZone: zone)
            == "From “Untitled meeting” · Sep 21, 2026 — added by dBrief")
    }

    @Test func statesAreUnique() {
        #expect(TickTickAPI.makeState() != TickTickAPI.makeState())
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | head -5`
Expected: compile errors such as `cannot find 'TickTickCredentials' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/dBrief/Services/TickTickAPI.swift`:

```swift
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

    /// The line under every task. Retries compare it to find tasks a lost
    /// response already created, so it must not change between attempts.
    static func taskContent(meetingTitle: String, date: Date,
                            locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let title = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return "From “\(title.isEmpty ? "Untitled meeting" : title)” · \(formatter.string(from: date)) — added by dBrief"
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | head; swift test --skip-build --filter TickTickAPITests 2>&1 | grep -E "✘|Test run with"`
Expected: `Test run with 10 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Services/TickTickAPI.swift Tests/dBriefTests/TickTickAPITests.swift
git commit -m "feat(ticktick): add OAuth and task request builders

Refs #69

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: TickTick destination, settings and delivery records

Adds the destination and its config, keeps old settings and delivery records loading, records per-item progress, and stores the token's Keychain key and privacy provider.

**Files:**
- Modify: `Sources/dBrief/Models/Integrations.swift` (enum, `available`, new config, `IntegrationSettings`, `IntegrationDispatchResult`)
- Modify: `Sources/dBrief/Models/IntegrationDeliveryBatch.swift` (`Delivery.createdItems`, `configurationDigests(_:available:)`)
- Modify: `Sources/dBrief/Services/IntegrationDeliveryCoordinator.swift` (copy `createdItems`)
- Modify: `Sources/dBrief/Utilities/KeychainHelper.swift` (`tickTickAccessToken`)
- Modify: `Sources/dBrief/Models/PrivacyReceipt.swift` (`Provider.tickTick`)
- Modify: `Sources/dBrief/UI/PrivacyReceiptView.swift` (provider name)
- Modify: `Sources/dBrief/UI/SettingsIntegrationsTab.swift` (exhaustive switches; interim values replaced in Task 5)
- Modify: `Sources/dBrief/Services/IntegrationDispatchService.swift` (`testConnection` switch; interim case replaced in Task 4)
- Test: `Tests/dBriefTests/IntegrationTickTickModelTests.swift`, `Tests/dBriefTests/IntegrationDeliveryTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `IntegrationDestination.tickTick` (raw value `"tickTick"`, display name `"TickTick"`).
  - `static var IntegrationDestination.available: [IntegrationDestination]` and `static func available(tickTickConfigured: Bool) -> [IntegrationDestination]`.
  - `struct TickTickConfig: Codable, Hashable, Sendable { var enabled: Bool; var projectID: String?; var projectName: String? }`; `IntegrationSettings.tickTick`.
  - `IntegrationDispatchResult.createdItems: [Int: String]?` (memberwise init gains a defaulted trailing `createdItems:`).
  - `IntegrationDeliveryBatch.Delivery.createdItems: [Int: String]?`.
  - `IntegrationDeliveryBatch.configurationDigests(_ settings: IntegrationSettings, available: [IntegrationDestination] = IntegrationDestination.available)`.
  - `KeychainSecretKey.tickTickAccessToken`, `PrivacyDestination.Provider.tickTick`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/dBriefTests/IntegrationTickTickModelTests.swift`:

```swift
import Foundation
import Testing
@testable import dBrief

@Suite("TickTick destination model")
struct IntegrationTickTickModelTests {
    @Test func tickTickIsOfferedOnlyWithCredentials() {
        #expect(IntegrationDestination.available(tickTickConfigured: false)
            == [.obsidian, .appleNotes, .appleReminders, .webhook])
        #expect(IntegrationDestination.available(tickTickConfigured: true)
            == [.obsidian, .appleNotes, .appleReminders, .webhook, .tickTick])
        #expect(IntegrationDestination.tickTick.displayName == "TickTick")
    }

    @Test func settingsSavedBeforeTickTickStillDecode() throws {
        var saved = IntegrationSettings()
        saved.webhook.enabled = true
        saved.appleReminders.listName = "Work"
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        object["tickTick"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(IntegrationSettings.self, from: legacy)
        #expect(decoded.webhook.enabled)
        #expect(decoded.appleReminders.listName == "Work")
        #expect(decoded.tickTick == TickTickConfig())
    }

    @Test func tickTickSettingsRoundTrip() throws {
        var settings = IntegrationSettings()
        settings.tickTick = TickTickConfig(enabled: true, projectID: "p1", projectName: "Work")
        let decoded = try JSONDecoder().decode(IntegrationSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test func digestCoversTheChosenListOnlyWhenOffered() throws {
        var settings = IntegrationSettings()
        settings.tickTick.enabled = true
        let offered = IntegrationDestination.available(tickTickConfigured: true)
        #expect(try IntegrationDeliveryBatch.configurationDigests(settings,
            available: IntegrationDestination.available(tickTickConfigured: false))[.tickTick] == nil)
        let inbox = try #require(try IntegrationDeliveryBatch.configurationDigests(settings, available: offered)[.tickTick])
        settings.tickTick.projectName = "Renamed"
        #expect(try IntegrationDeliveryBatch.configurationDigests(settings, available: offered)[.tickTick] == inbox)
        settings.tickTick.projectID = "p2"
        #expect(try IntegrationDeliveryBatch.configurationDigests(settings, available: offered)[.tickTick] != inbox)
        settings.tickTick.enabled = false
        #expect(try IntegrationDeliveryBatch.configurationDigests(settings, available: offered)[.tickTick] == nil)
    }

    @Test func deliveryRecordsWithoutCreatedItemsStillDecode() throws {
        let delivery = IntegrationDeliveryBatch.Delivery(id: UUID(), destination: .webhook, configurationDigest: "d")
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(delivery)) as? [String: Any])
        object["createdItems"] = nil
        let decoded = try JSONDecoder().decode(IntegrationDeliveryBatch.Delivery.self,
                                               from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.createdItems == nil)
        var withItems = delivery
        withItems.createdItems = [0: "t1", 3: "t4"]
        let roundTrip = try JSONDecoder().decode(IntegrationDeliveryBatch.Delivery.self,
                                                 from: JSONEncoder().encode(withItems))
        #expect(roundTrip.createdItems == [0: "t1", 3: "t4"])
    }
}
```

Append to `Tests/dBriefTests/IntegrationDeliveryTests.swift`, inside `struct IntegrationDeliveryTests` (it uses the file's private `DeliveryTestStore`):

```swift
    @Test
    func coordinatorKeepsCreatedItemsFromEveryAttempt() async throws {
        let original = IntegrationDeliveryBatch(id: UUID(), recordingID: UUID(), createdAt: Date(),
            bundle: .init(title: "Meeting", createdAt: Date(), durationSeconds: 60,
                          audioFileURL: URL(fileURLWithPath: "/tmp/meeting.m4a"),
                          transcript: nil, summary: nil, actionItems: ["A", "B"],
                          tags: [], sentiment: nil, markdown: nil, calendarEvent: nil),
            deliveries: [.init(id: UUID(), destination: .tickTick, configurationDigest: "tt")])
        let store = DeliveryTestStore(original)
        let coordinator = IntegrationDeliveryCoordinator(store: store)
        let failed = try await coordinator.run(id: original.id, configurationDigests: [.tickTick: "tt"]) { _, entry in
            #expect(entry.createdItems == nil)
            return .init(destination: .tickTick, status: .failed, message: "lost", remoteID: nil, createdItems: [0: "t-a"])
        }
        #expect(failed.deliveries[0].status == .uncertain)
        #expect(failed.deliveries[0].createdItems == [0: "t-a"])
        let retried = try await coordinator.run(id: original.id, configurationDigests: [.tickTick: "tt"],
                                                allowUncertainRetry: true) { _, entry in
            #expect(entry.createdItems == [0: "t-a"])
            return .init(destination: .tickTick, status: .success, message: "Sent", remoteID: "t-a,t-b",
                         createdItems: [0: "t-a", 1: "t-b"])
        }
        #expect(retried.deliveries[0].createdItems == [0: "t-a", 1: "t-b"])
        #expect(await store.batch.deliveries[0].createdItems == [0: "t-a", 1: "t-b"])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | head -5`
Expected: errors such as `type 'IntegrationDestination' has no member 'tickTick'`.

- [ ] **Step 3: Add the destination, config and decoding**

In `Sources/dBrief/Models/Integrations.swift`:

Add the case after `case webhook`:

```swift
    case tickTick
```

Add to `displayName`:

```swift
        case .tickTick: "TickTick"
```

Replace the `available` declaration (and its comment) with:

```swift
    /// Destinations currently exposed to users. Untested integrations
    /// (Notion, Evernote, Google Keep, OneNote) are omitted until verified.
    /// TickTick appears only in builds stamped with its OAuth credentials.
    static var available: [IntegrationDestination] {
        available(tickTickConfigured: TickTickCredentials.bundled.isConfigured)
    }

    static func available(tickTickConfigured: Bool) -> [IntegrationDestination] {
        [.obsidian, .appleNotes, .appleReminders, .webhook] + (tickTickConfigured ? [.tickTick] : [])
    }
```

Add after `AppleRemindersConfig`:

```swift
struct TickTickConfig: Codable, Hashable, Sendable {
    var enabled: Bool = false
    /// Nil sends to the Inbox.
    var projectID: String? = nil
    /// Display only; the id is what routes tasks.
    var projectName: String? = nil
}
```

Add `var tickTick = TickTickConfig()` as the last property of `IntegrationSettings`, then add below the struct:

```swift
extension IntegrationSettings {
    /// Settings saved before a destination existed lack its key; decode each
    /// one leniently so adding a destination never resets the others.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        appleNotes = try container.decodeIfPresent(AppleNotesConfig.self, forKey: .appleNotes) ?? appleNotes
        appleReminders = try container.decodeIfPresent(AppleRemindersConfig.self, forKey: .appleReminders) ?? appleReminders
        notion = try container.decodeIfPresent(NotionConfig.self, forKey: .notion) ?? notion
        evernote = try container.decodeIfPresent(EvernoteConfig.self, forKey: .evernote) ?? evernote
        googleKeep = try container.decodeIfPresent(GoogleKeepConfig.self, forKey: .googleKeep) ?? googleKeep
        oneNote = try container.decodeIfPresent(OneNoteConfig.self, forKey: .oneNote) ?? oneNote
        webhook = try container.decodeIfPresent(WebhookConfig.self, forKey: .webhook) ?? webhook
        tickTick = try container.decodeIfPresent(TickTickConfig.self, forKey: .tickTick) ?? tickTick
    }
}
```

If the compiler reports that `CodingKeys` is not accessible from the extension, add an explicit `private enum CodingKeys: String, CodingKey { case appleNotes, appleReminders, notion, evernote, googleKeep, oneNote, webhook, tickTick }` inside `IntegrationSettings` (change `private` to `fileprivate`) and keep the extension.

In `IntegrationDispatchResult`, add after `let remoteID: String?`:

```swift
    /// Action-item index → remote id for destinations that create one item per
    /// action item (TickTick). Kept on failure so a retry resumes.
    var createdItems: [Int: String]? = nil
```

- [ ] **Step 4: Record progress on deliveries and include TickTick in digests**

In `Sources/dBrief/Models/IntegrationDeliveryBatch.swift`, add to `struct Delivery` after `var remoteID: String?`:

```swift
        /// Action-item index → remote id created so far (TickTick). Optional so
        /// records written before this field existed still decode.
        var createdItems: [Int: String]? = nil
```

Change the digests function signature and its guard, and add the TickTick entry before `return values`:

```swift
    static func configurationDigests(_ settings: IntegrationSettings,
                                     available: [IntegrationDestination] = IntegrationDestination.available)
        throws -> [IntegrationDestination: String] {
```

```swift
            guard enabled, available.contains(destination) else { return }
```

```swift
        try add(.tickTick, TickTickRouting(projectID: settings.tickTick.projectID ?? "inbox"),
                enabled: settings.tickTick.enabled)
```

Add next to `WebhookRouting`:

```swift
    /// The list name is display-only; renaming it must not block a retry.
    private struct TickTickRouting: Encodable {
        let projectID: String
    }
```

In `Sources/dBrief/Services/IntegrationDeliveryCoordinator.swift`, after `batch.deliveries[index].remoteID = result.remoteID` add:

```swift
            if let created = result.createdItems { batch.deliveries[index].createdItems = created }
```

- [ ] **Step 5: Keychain key, privacy provider, exhaustive switches**

`Sources/dBrief/Utilities/KeychainHelper.swift` — add to `KeychainSecretKey`:

```swift
    case tickTickAccessToken = "integration.ticktick.accessToken"
```

`Sources/dBrief/Models/PrivacyReceipt.swift` — extend the provider line `case localCLI, appleNotes, appleReminders, webhook, fileSystem` to:

```swift
        case localCLI, appleNotes, appleReminders, webhook, tickTick, fileSystem
```

`Sources/dBrief/UI/PrivacyReceiptView.swift` — after `case .webhook: "Webhook"` add:

```swift
        case .tickTick: "TickTick"
```

`Sources/dBrief/UI/SettingsIntegrationsTab.swift` (Task 5 replaces the interim `needsSetup`, `summary` and detail values):
- `isEnabled`: add `case .tickTick: appSettings.integrations.tickTick.enabled`
- `needsSetup`: change `case .appleNotes, .appleReminders: false` to `case .appleNotes, .appleReminders, .tickTick: false`
- `summary`: change `case .notion, .evernote, .googleKeep, .oneNote:` to `case .notion, .evernote, .googleKeep, .oneNote, .tickTick:`
- `integrationDetail`: add `case .tickTick: EmptyView()`
- `iconFileBaseNames`: add `case .tickTick: return ["TickTick", destination.rawValue, destination.displayName]`
- `icon(for:)`: add `case .tickTick: "checkmark.square"`

`Sources/dBrief/Services/IntegrationDispatchService.swift` — in `testConnection`'s switch, before `case .obsidian:` add (Task 4 replaces it):

```swift
        case .tickTick:
            throw IntegrationError.unsupported("TickTick is not available yet")
```

- [ ] **Step 6: Build and run the tests**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | head; swift test --skip-build --filter "IntegrationTickTickModelTests|IntegrationDeliveryTests|IntegrationVisibilityTests" 2>&1 | grep -E "✘|Test run with"`
Expected: all pass; `IntegrationVisibilityTests` still sees exactly the four destinations (the test runner bundle has no TickTick keys).

- [ ] **Step 7: Commit**

```bash
git add Sources/dBrief/Models/Integrations.swift Sources/dBrief/Models/IntegrationDeliveryBatch.swift \
  Sources/dBrief/Services/IntegrationDeliveryCoordinator.swift Sources/dBrief/Utilities/KeychainHelper.swift \
  Sources/dBrief/Models/PrivacyReceipt.swift Sources/dBrief/UI/PrivacyReceiptView.swift \
  Sources/dBrief/UI/SettingsIntegrationsTab.swift Sources/dBrief/Services/IntegrationDispatchService.swift \
  Tests/dBriefTests/IntegrationTickTickModelTests.swift Tests/dBriefTests/IntegrationDeliveryTests.swift
git commit -m "feat(ticktick): add destination, settings and per-item delivery progress

Refs #69

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: TickTick HTTP client

**Files:**
- Create: `Sources/dBrief/Services/TickTickClient.swift`
- Create: `Tests/dBriefTests/TickTickStub.swift` (URLProtocol stub shared with Task 4)
- Test: `Tests/dBriefTests/TickTickClientTests.swift`

**Interfaces:**
- Consumes: `TickTickAPI`, `TickTickCredentials`, `TickTickError` (Task 1); `PrivacyDestination.Provider.tickTick` (Task 2).
- Produces:
  - `struct TickTickProject: Decodable, Equatable, Sendable { let id: String; let name: String; var closed: Bool? }`
  - `struct TickTickTask: Decodable, Equatable, Sendable { let id: String; var title: String?; var content: String? }`
  - `struct TickTickClient: Sendable` — `init(session: URLSession = .shared)`; `exchangeCode(_:credentials:) async throws -> String`; `revoke(token:credentials:) async`; `listProjects(token:) async throws -> [TickTickProject]`; `projectTasks(projectID:token:) async throws -> [TickTickTask]`; `createTask(title:content:projectID:token:) async throws -> String`.
  - Test support: `TickTickStubProtocol` (`register(key:_:)`, `unregister(key:)`, `session()`, `Reply`, `Seen`), `TickTickSeenLog`.

- [ ] **Step 1: Write the test stub**

Create `Tests/dBriefTests/TickTickStub.swift`:

```swift
import Foundation

/// Routes each request to a per-test responder chosen by its credential (the
/// bearer token, or the Basic value for the token endpoint), so parallel tests
/// never share responders.
final class TickTickStubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case status(Int, String)
        case failure(URLError.Code)
    }
    struct Seen: Sendable, Equatable {
        let method: String
        let path: String
        let body: String
    }
    typealias Responder = @Sendable (Seen) -> Reply

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responders: [String: Responder] = [:]

    static func register(key: String, _ responder: @escaping Responder) {
        lock.withLock { responders[key] = responder }
    }

    static func unregister(key: String) {
        lock.withLock { responders[key] = nil }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TickTickStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix("ticktick.com") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let key = authorization.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
        let seen = Seen(method: request.httpMethod ?? "GET", path: request.url?.path ?? "", body: Self.body(of: request))
        guard let responder = Self.lock.withLock({ Self.responders[key] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        switch responder(seen) {
        case .status(let code, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Thread-safe record of what a stub saw.
final class TickTickSeenLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TickTickStubProtocol.Seen] = []

    func append(_ seen: TickTickStubProtocol.Seen) { lock.withLock { items.append(seen) } }
    var all: [TickTickStubProtocol.Seen] { lock.withLock { items } }
    var posts: [TickTickStubProtocol.Seen] { all.filter { $0.method == "POST" } }
}
```

- [ ] **Step 2: Write the failing client tests**

Create `Tests/dBriefTests/TickTickClientTests.swift`:

```swift
import Foundation
import Testing
@testable import dBrief

@Suite("TickTick client")
struct TickTickClientTests {
    private func withStub<T>(key: String = UUID().uuidString,
                             _ responder: @escaping TickTickStubProtocol.Responder,
                             _ body: (TickTickClient, String) async throws -> T) async rethrows -> T {
        TickTickStubProtocol.register(key: key, responder)
        let session = TickTickStubProtocol.session()
        defer {
            TickTickStubProtocol.unregister(key: key)
            session.invalidateAndCancel()
        }
        return try await body(TickTickClient(session: session), key)
    }

    @Test func listProjectsDropsClosedListsAndSortsByName() async throws {
        let projects = try await withStub({ seen in
            #expect(seen.method == "GET")
            #expect(seen.path == "/open/v1/project")
            return .status(200, #"[{"id":"b","name":"Work"},{"id":"c","name":"Old","closed":true},{"id":"a","name":"errands"}]"#)
        }) { client, token in try await client.listProjects(token: token) }
        #expect(projects.map(\.id) == ["a", "b"])
    }

    @Test func unauthorizedAndServerErrorsAreTyped() async {
        await #expect(throws: TickTickError.unauthorized) {
            try await withStub({ _ in .status(401, "") }) { client, token in try await client.listProjects(token: token) }
        }
        await #expect(throws: TickTickError.http(503)) {
            try await withStub({ _ in .status(503, "busy") }) { client, token in try await client.listProjects(token: token) }
        }
        await #expect(throws: TickTickError.invalidResponse) {
            try await withStub({ _ in .status(200, "not json") }) { client, token in try await client.listProjects(token: token) }
        }
    }

    @Test func createTaskSendsJSONAndReturnsTheID() async throws {
        let log = TickTickSeenLog()
        let id = try await withStub({ seen in
            log.append(seen)
            return .status(200, #"{"id":"t1","projectId":"p1","title":"Send deck"}"#)
        }) { client, token in
            try await client.createTask(title: "Send deck", content: "From x", projectID: "p1", token: token)
        }
        #expect(id == "t1")
        let post = try #require(log.posts.first)
        #expect(post.path == "/open/v1/task")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(post.body.utf8)) as? [String: String])
        #expect(json == ["title": "Send deck", "content": "From x", "projectId": "p1"])
    }

    @Test func createTaskAcceptsCreatedWithoutBody() async throws {
        let id = try await withStub({ _ in .status(201, "") }) { client, token in
            try await client.createTask(title: "A", content: "B", projectID: "inbox", token: token)
        }
        #expect(id == "")
    }

    @Test func projectTasksReadsTheTaskList() async throws {
        let tasks = try await withStub({ seen in
            #expect(seen.path == "/open/v1/project/inbox/data")
            return .status(200, #"{"project":{"id":"inbox"},"tasks":[{"id":"t1","title":"A","content":"From x"},{"id":"t2"}]}"#)
        }) { client, token in try await client.projectTasks(projectID: "inbox", token: token) }
        #expect(tasks == [TickTickTask(id: "t1", title: "A", content: "From x"), TickTickTask(id: "t2")])
    }

    @Test func exchangeCodeReturnsTheAccessToken() async throws {
        let credentials = TickTickCredentials(clientID: UUID().uuidString, clientSecret: "secret")
        let basic = Data("\(credentials.clientID):secret".utf8).base64EncodedString()
        let token = try await withStub(key: basic, { seen in
            #expect(seen.path == "/oauth/token")
            #expect(seen.body.contains("code=abc"))
            return .status(200, #"{"access_token":"tok-1"}"#)
        }) { client, _ in try await client.exchangeCode("abc", credentials: credentials) }
        #expect(token == "tok-1")
    }
}
```

`TickTickTask(id: "t2")` relies on the memberwise init with defaulted optional `var`s.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | head -5`
Expected: `cannot find 'TickTickClient' in scope`.

- [ ] **Step 4: Write the client**

Create `Sources/dBrief/Services/TickTickClient.swift`:

```swift
import Foundation

struct TickTickProject: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    var closed: Bool? = nil
}

struct TickTickTask: Decodable, Equatable, Sendable {
    let id: String
    var title: String? = nil
    var content: String? = nil
}

/// HTTP calls to TickTick. Creating a task carries meeting text, so it is
/// recorded in the recording's privacy receipt; sign-in and list reads are not.
struct TickTickClient: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func exchangeCode(_ code: String, credentials: TickTickCredentials) async throws -> String {
        try TickTickAPI.accessToken(from: await send(TickTickAPI.tokenRequest(code: code, credentials: credentials)))
    }

    /// Best effort: signing out removes the local token whatever this returns.
    func revoke(token: String, credentials: TickTickCredentials) async {
        var request = URLRequest(url: TickTickAPI.revokeEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        let basic = Data("\(credentials.clientID):\(credentials.clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = TickTickAPI.formBody([("token", token)])
        _ = try? await send(request)
    }

    func listProjects(token: String) async throws -> [TickTickProject] {
        let data = try await send(TickTickAPI.apiRequest("open/v1/project", token: token))
        guard let projects = try? JSONDecoder().decode([TickTickProject].self, from: data) else {
            throw TickTickError.invalidResponse
        }
        return projects.filter { $0.closed != true }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func projectTasks(projectID: String, token: String) async throws -> [TickTickTask] {
        struct ProjectData: Decodable { var tasks: [TickTickTask]? }
        let data = try await send(TickTickAPI.apiRequest("open/v1/project/\(projectID)/data", token: token))
        guard let decoded = try? JSONDecoder().decode(ProjectData.self, from: data) else {
            throw TickTickError.invalidResponse
        }
        return decoded.tasks ?? []
    }

    /// Returns the new task's id, or "" when TickTick answers 201 without a body.
    func createTask(title: String, content: String, projectID: String, token: String) async throws -> String {
        let request = TickTickAPI.apiRequest("open/v1/task", token: token, method: "POST",
            body: try TickTickAPI.createTaskBody(title: title, content: content, projectID: projectID))
        let operation = PrivacyOperation(stage: .integration, data: [.text, .metadata],
                                         destination: .remote(url: TickTickAPI.apiBase, provider: .tickTick))
        let data = try await send(request, operation: operation)
        return (try? JSONDecoder().decode(TickTickTask.self, from: data))?.id ?? ""
    }

    private func send(_ request: URLRequest, operation: PrivacyOperation? = nil) async throws -> Data {
        let (data, response): (Data, URLResponse)
        if let operation {
            (data, response) = try await PrivacyHTTPTrace.data(for: request, operation: operation, session: session)
        } else {
            (data, response) = try await PrivacyHTTPTrace.untracedData(for: request, session: session)
        }
        guard let http = response as? HTTPURLResponse else { throw TickTickError.invalidResponse }
        if http.statusCode == 401 { throw TickTickError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw TickTickError.http(http.statusCode) }
        return data
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | head; swift test --skip-build --filter TickTickClientTests 2>&1 | grep -E "✘|Test run with"`
Expected: `Test run with 6 tests in 1 suite passed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/dBrief/Services/TickTickClient.swift Tests/dBriefTests/TickTickStub.swift Tests/dBriefTests/TickTickClientTests.swift
git commit -m "feat(ticktick): add HTTP client for lists, tasks and sign-in

Refs #69

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Send action items to TickTick

**Files:**
- Create: `Sources/dBrief/Services/IntegrationDispatchService+TickTick.swift`
- Modify: `Sources/dBrief/Services/IntegrationDispatchService.swift` (init, `prepareBatch`, `sendInRecordingContext`, `testConnection`)
- Test: `Tests/dBriefTests/TickTickDeliveryTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3 (`TickTickAPI.taskContent`, `TickTickAPI.inboxProjectID`, `TickTickClient`, `TickTickTask`, `TickTickError`, `IntegrationDispatchResult.createdItems`, `Delivery.createdItems`, `configurationDigests(_:available:)`, `KeychainSecretKey.tickTickAccessToken`).
- Produces:
  - `enum TickTickSession { static let expiredKey = "ticktick.sessionExpired"; static func markExpired() }`
  - `IntegrationDispatchService.init(session:privacyStore:privacyPendingRoot:available:tickTickToken:tickTickSessionExpired:)` (new parameters defaulted).
  - `IntegrationDispatchService.sendToTickTick(batch:delivery:config:) async -> IntegrationDispatchResult`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/dBriefTests/TickTickDeliveryTests.swift`:

```swift
import Foundation
import Testing
@testable import dBrief

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Suite("TickTick delivery")
struct TickTickDeliveryTests {
    private let offered = IntegrationDestination.available(tickTickConfigured: true)

    private struct Harness {
        let folder: URL
        let token: String
        let session: URLSession
        let service: IntegrationDispatchService
        let expired: Counter
        let log: TickTickSeenLog
        var config: IntegrationSettings

        func cleanUp() {
            TickTickStubProtocol.unregister(key: token)
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func harness(tokenStored: Bool = true,
                         respond: @escaping @Sendable (TickTickStubProtocol.Seen, Int) -> TickTickStubProtocol.Reply)
        throws -> Harness {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ticktick-delivery-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let log = TickTickSeenLog()
        let posts = Counter()
        TickTickStubProtocol.register(key: token) { seen in
            log.append(seen)
            if seen.method == "POST" { posts.increment() }
            return respond(seen, posts.count)
        }
        let session = TickTickStubProtocol.session()
        let expired = Counter()
        let service = IntegrationDispatchService(
            session: session, privacyStore: PrivacyReceiptStore(gapDirectoryURL: folder.appendingPathComponent("gaps")),
            privacyPendingRoot: folder.appendingPathComponent("pending"), available: offered,
            tickTickToken: { tokenStored ? token : "" }, tickTickSessionExpired: { expired.increment() })
        var config = IntegrationSettings()
        config.tickTick = TickTickConfig(enabled: true, projectID: "p1", projectName: "Work")
        return Harness(folder: folder, token: token, session: session, service: service,
                       expired: expired, log: log, config: config)
    }

    private func batch(_ harness: Harness, items: [String], attempts: Int = 1,
                       created: [Int: String]? = nil) throws -> (IntegrationDeliveryBatch, IntegrationDeliveryBatch.Delivery) {
        let audio = harness.folder.appendingPathComponent("meeting.m4a")
        try Data("audio".utf8).write(to: audio)
        let bundle = IntegrationContentBundle(title: "Weekly sync", createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            durationSeconds: 60, audioFileURL: audio, transcript: nil, summary: nil, actionItems: items,
            tags: [], sentiment: nil, markdown: nil, calendarEvent: nil)
        let digest = try #require(try IntegrationDeliveryBatch.configurationDigests(harness.config, available: offered)[.tickTick])
        var delivery = IntegrationDeliveryBatch.Delivery(id: UUID(), destination: .tickTick, configurationDigest: digest)
        delivery.attempts = attempts
        delivery.createdItems = created
        let batch = IntegrationDeliveryBatch(id: UUID(), recordingID: UUID(), createdAt: Date(),
                                             bundle: bundle, deliveries: [delivery])
        return (batch, delivery)
    }

    private func content() -> String {
        TickTickAPI.taskContent(meetingTitle: "Weekly sync", date: Date(timeIntervalSince1970: 1_790_000_000))
    }

    private func titles(_ log: TickTickSeenLog) -> [String] {
        log.posts.compactMap { post in
            (try? JSONSerialization.jsonObject(with: Data(post.body.utf8)) as? [String: String])?["title"]
        }
    }

    @Test func sendsOneTaskPerNonEmptyItem() async throws {
        let h = try harness { seen, posts in .status(200, #"{"id":"t\#(posts)"}"#) }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, items: ["Send deck", "  ", " Book room "])
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .success)
        #expect(result.createdItems == [0: "t1", 2: "t2"])
        #expect(result.remoteID == "t1,t2")
        #expect(titles(h.log) == ["Send deck", "Book room"])
        let first = try #require(try JSONSerialization.jsonObject(with: Data(h.log.posts[0].body.utf8)) as? [String: String])
        #expect(first["projectId"] == "p1")
        #expect(first["content"] == content())
        #expect(!h.log.all.contains { $0.method == "GET" })
    }

    @Test func whitespaceOnlyItemsAreSkipped() async throws {
        let h = try harness { _, _ in .status(500, "") }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, items: [" ", ""])
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .skipped)
        #expect(h.log.all.isEmpty)
    }

    @Test func retrySkipsRecordedItemsAndMatchesExistingTasks() async throws {
        let marker = content()
        let h = try harness { seen, _ in
            if seen.method == "GET" {
                #expect(seen.path == "/open/v1/project/p1/data")
                return .status(200, #"{"tasks":[{"id":"t-b","title":"B","content":"\#(marker)"},{"id":"x","title":"C","content":"other"}]}"#)
            }
            return .status(200, #"{"id":"t-c"}"#)
        }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, items: ["A", "B", "C"], attempts: 2, created: [0: "t-a"])
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .success)
        #expect(result.createdItems == [0: "t-a", 1: "t-b", 2: "t-c"])
        #expect(titles(h.log) == ["C"])
        #expect(h.log.all.filter { $0.method == "GET" }.count == 1)
    }

    @Test func duplicateTitlesClaimOneExistingTaskEach() async throws {
        let marker = content()
        let h = try harness { seen, _ in
            seen.method == "GET"
                ? .status(200, #"{"tasks":[{"id":"t1","title":"Follow up","content":"\#(marker)"}]}"#)
                : .status(200, #"{"id":"t2"}"#)
        }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, items: ["Follow up", "Follow up"], attempts: 2)
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.createdItems == [0: "t1", 1: "t2"])
        #expect(titles(h.log) == ["Follow up"])
    }

    @Test func failureKeepsProgressForTheNextAttempt() async throws {
        let h = try harness { _, posts in posts == 1 ? .status(200, #"{"id":"t-a"}"#) : .failure(.networkConnectionLost) }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, items: ["A", "B"])
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .failed)
        #expect(result.createdItems == [0: "t-a"])
        #expect(h.expired.count == 0)
    }

    @Test func unauthorizedMarksTheSessionExpired() async throws {
        let h = try harness { _, _ in .status(401, "") }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, items: ["A"])
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .failed)
        #expect(result.createdItems == nil)
        #expect(h.expired.count == 1)
    }

    @Test func changedListBlocksTheRetry() async throws {
        var h = try harness { _, _ in .status(200, #"{"id":"t1"}"#) }
        defer { h.cleanUp() }
        let (batch, delivery) = try batch(h, items: ["A"], attempts: 2)
        h.config.tickTick.projectID = "another-list"
        let result = await h.service.send(batch: batch, delivery: delivery, config: h.config)
        #expect(result.status == .failed)
        #expect(h.log.all.isEmpty)
    }

    @Test @MainActor func notSignedInLeavesTickTickOutOfTheBatch() async throws {
        for stored in [false, true] {
            let h = try harness(tokenStored: stored) { _, _ in .status(500, "") }
            defer { h.cleanUp() }
            let recording = Recording(fileURL: h.folder.appendingPathComponent("meeting.m4a"))
            recording.actionItems = ["A"]
            let prepared = try await h.service.prepareBatch(jobID: UUID(), recording: RecordingSnapshot(recording: recording),
                                                            config: h.config, generatedMarkdownURL: nil)
            #expect(prepared.deliveries.map(\.destination).contains(.tickTick) == stored)
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | head -5`
Expected: `extra arguments at positions … in call` (the new init parameters don't exist yet).

- [ ] **Step 3: Extend the dispatch service**

In `Sources/dBrief/Services/IntegrationDispatchService.swift`:

Replace the stored properties and `init` at the top of the actor with:

```swift
    private let webhookPayloadBuilder = WebhookPayloadBuilder()
    private let reminderStore = EKEventStore()
    private let session: URLSession
    private let privacyStore: PrivacyReceiptStore
    private let privacyPendingRoot: URL
    let available: [IntegrationDestination]
    let tickTickClient: TickTickClient
    let tickTickToken: @Sendable () throws -> String
    let tickTickSessionExpired: @Sendable () -> Void

    init(session: URLSession = .shared, privacyStore: PrivacyReceiptStore = .shared,
         privacyPendingRoot: URL = AppSupportPaths.subdirectory("Privacy Pending"),
         available: [IntegrationDestination] = IntegrationDestination.available,
         tickTickToken: @escaping @Sendable () throws -> String = { try KeychainHelper.get(for: .tickTickAccessToken) },
         tickTickSessionExpired: @escaping @Sendable () -> Void = { TickTickSession.markExpired() }) {
        self.session = session
        self.privacyStore = privacyStore
        self.privacyPendingRoot = privacyPendingRoot
        self.available = available
        self.tickTickClient = TickTickClient(session: session)
        self.tickTickToken = tickTickToken
        self.tickTickSessionExpired = tickTickSessionExpired
    }
```

In `prepareBatch`, change the digests line to:

```swift
        let digests = try IntegrationDeliveryBatch.configurationDigests(config, available: available)
```

and replace the `deliveries:` closure with:

```swift
            deliveries: available.compactMap { destination in
                guard let digest = digests[destination] else { return nil }
                // Not signed in: leave it out, like a disabled destination.
                if destination == .tickTick, ((try? tickTickToken()) ?? "").isEmpty { return nil }
                return .init(id: UUID(), destination: destination, configurationDigest: digest)
            }
```

At the start of `sendInRecordingContext`, after `let bundle = batch.bundle`, add:

```swift
        if delivery.destination == .tickTick {
            return await sendToTickTick(batch: batch, delivery: delivery, config: config)
        }
```

and change its digest check to use the injected list:

```swift
            guard try IntegrationDeliveryBatch.configurationDigests(config, available: self.available)[delivery.destination]
                    == delivery.configurationDigest else {
```

In `testConnection`, change `guard IntegrationDestination.available.contains(destination)` to `guard available.contains(destination)`, and replace the interim `.tickTick` case from Task 2 with:

```swift
        case .tickTick:
            let token = try tickTickToken()
            guard !token.isEmpty else { throw TickTickError.notSignedIn }
            do {
                _ = try await tickTickClient.listProjects(token: token)
            } catch TickTickError.unauthorized {
                tickTickSessionExpired()
                throw TickTickError.unauthorized
            }
```

Create `Sources/dBrief/Services/IntegrationDispatchService+TickTick.swift`:

```swift
import Foundation
import os
import dBriefWire

/// Records an expired TickTick sign-in: TickTick documents no refresh token, so
/// a 401 removes the stored token and Settings asks the user to sign in again.
enum TickTickSession {
    static let expiredKey = "ticktick.sessionExpired"

    static func markExpired() {
        do {
            try KeychainHelper.set("", for: .tickTickAccessToken)
        } catch {
            Logger.integrations.error("TickTick token removal failed: \(error.localizedDescription, privacy: .public)")
        }
        UserDefaults.standard.set(true, forKey: expiredKey)
    }
}

extension IntegrationDispatchService {
    /// One task per non-empty action item. Items already in `createdItems` are
    /// skipped, and a retry first matches existing tasks (same title and meeting
    /// line), so a lost response or a crash mid-attempt cannot create duplicates.
    func sendToTickTick(batch: IntegrationDeliveryBatch, delivery: IntegrationDeliveryBatch.Delivery,
                        config: IntegrationSettings) async -> IntegrationDispatchResult {
        let items = batch.bundle.actionItems.enumerated().compactMap { index, text -> (index: Int, title: String)? in
            let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : (index, title)
        }
        guard !items.isEmpty else {
            return .init(destination: .tickTick, status: .skipped, message: "No action items", remoteID: nil)
        }
        var created = delivery.createdItems ?? [:]
        do {
            try Task.checkCancellation()
            guard try IntegrationDeliveryBatch.configurationDigests(config, available: available)[.tickTick]
                    == delivery.configurationDigest else {
                throw IntegrationError.executionFailed("Integration settings changed. Restore the original destination before retrying.")
            }
            let token = try tickTickToken()
            guard !token.isEmpty else { throw TickTickError.notSignedIn }
            let projectID = config.tickTick.projectID ?? TickTickAPI.inboxProjectID
            let content = TickTickAPI.taskContent(meetingTitle: batch.bundle.title, date: batch.bundle.createdAt)
            var existing: [TickTickTask]?
            var claimed = Set(created.values.filter { !$0.isEmpty })
            for item in items where created[item.index] == nil {
                try Task.checkCancellation()
                if delivery.attempts > 1 {
                    if existing == nil {
                        existing = try await tickTickClient.projectTasks(projectID: projectID, token: token)
                    }
                    if let match = existing?.first(where: { task in
                        !claimed.contains(task.id)
                            && task.title?.trimmingCharacters(in: .whitespacesAndNewlines) == item.title
                            && task.content?.trimmingCharacters(in: .whitespacesAndNewlines) == content
                    }) {
                        created[item.index] = match.id
                        claimed.insert(match.id)
                        continue
                    }
                }
                let id = try await tickTickClient.createTask(title: item.title, content: content,
                                                             projectID: projectID, token: token)
                created[item.index] = id
                if !id.isEmpty { claimed.insert(id) }
            }
            let remoteID = items.compactMap { created[$0.index] }.filter { !$0.isEmpty }.joined(separator: ",")
            Logger.integrations.info("Integration success: tickTick (\(items.count, privacy: .public) items)")
            return .init(destination: .tickTick, status: .success, message: "Sent",
                         remoteID: remoteID.isEmpty ? nil : remoteID, createdItems: created)
        } catch {
            if error as? TickTickError == .unauthorized { tickTickSessionExpired() }
            Logger.integrations.error("Integration failure: tickTick")
            return .init(destination: .tickTick, status: .failed, message: error.localizedDescription,
                         remoteID: nil, createdItems: created.isEmpty ? nil : created)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | head; swift test --skip-build --filter "TickTickDeliveryTests|IntegrationPrivacyTests|IntegrationDeliveryTests|ProcessingDeliveryTests" 2>&1 | grep -E "✘|Test run with"`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Services/IntegrationDispatchService.swift Sources/dBrief/Services/IntegrationDispatchService+TickTick.swift \
  Tests/dBriefTests/TickTickDeliveryTests.swift
git commit -m "feat(ticktick): send action items as tasks without duplicates

Refs #69

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Sign-in service and Settings page

**Files:**
- Create: `Sources/dBrief/Services/TickTickAuthService.swift`
- Modify: `Sources/dBrief/Services/MicrosoftAuthService.swift` (make `WebAuthPresentationContext` internal)
- Modify: `Sources/dBrief/App/DBriefApp.swift` (own and inject the service)
- Modify: `Sources/dBrief/UI/SettingsIntegrationsTab.swift` (TickTick detail page; replace Task 2's interim values)
- Modify: `Tests/dBriefTests/SettingsPagesVisualTests.swift` (inject the service)

**Interfaces:**
- Consumes: `TickTickAPI`, `TickTickCredentials`, `TickTickError` (Task 1); `TickTickClient`, `TickTickProject` (Task 3); `TickTickSession` (Task 4); `TickTickConfig`, `KeychainSecretKey.tickTickAccessToken` (Task 2).
- Produces: `@MainActor @Observable final class TickTickAuthService` — `static var isConfigured`, `isSignedIn`, `sessionExpired`, `reload()`, `accessToken() throws -> String`, `signIn() async throws`, `signOut() async`.

This task is UI and system glue (ASWebAuthenticationSession, Keychain, UserDefaults); its pure parts are tested in Tasks 1–4. Verification is a clean build, the full suite, and the manual check in Task 6.

- [ ] **Step 1: Share the web-auth presentation anchor**

In `Sources/dBrief/Services/MicrosoftAuthService.swift`, change

```swift
private final class WebAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
```

to

```swift
final class WebAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
```

- [ ] **Step 2: Write the sign-in service**

Create `Sources/dBrief/Services/TickTickAuthService.swift`:

```swift
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
```

- [ ] **Step 3: Own and inject the service**

In `Sources/dBrief/App/DBriefApp.swift`, after `let microsoftAuthService = MicrosoftAuthService()` add:

```swift
    let tickTickAuthService = TickTickAuthService()
```

and in the `Window("Settings", id: "settings")` scene, after `.environment(context.microsoftAuthService)` add:

```swift
                .environment(context.tickTickAuthService)
```

In `Tests/dBriefTests/SettingsPagesVisualTests.swift`, after `.environment(auth)` add:

```swift
                    .environment(TickTickAuthService())
```

- [ ] **Step 4: Build the TickTick Settings page**

In `Sources/dBrief/UI/SettingsIntegrationsTab.swift`:

Add with the other properties:

```swift
    @Environment(TickTickAuthService.self) private var tickTickAuth
    @State private var tickTickProjects: [TickTickProject] = []
    @State private var tickTickListError: String?
    @State private var tickTickSignInError: String?
    @State private var isSigningInToTickTick = false
```

Re-read the sign-in state when the page opens: append to the `SettingsPageScaffold(...) { ... }` expression in `body`:

```swift
        .onAppear { tickTickAuth.reload() }
```

Replace Task 2's interim values:
- `needsSetup`: change `case .appleNotes, .appleReminders, .tickTick: false` back to `case .appleNotes, .appleReminders: false` and add `case .tickTick: !tickTickAuth.isSignedIn`
- `summary`: remove `.tickTick` from the `nil` group and add:

```swift
        case .tickTick:
            return "One task per action item · list “\(appSettings.integrations.tickTick.projectName ?? "Inbox")”"
```

- `integrationDetail`: replace `case .tickTick: EmptyView()` with `case .tickTick: tickTickDetail`

Add after `appleRemindersDetail`:

```swift
    @ViewBuilder
    private var tickTickDetail: some View {
        @Bindable var settings = appSettings
        SettingsCard("TickTick", description: "Only action items are sent, one task each") {
            enableRow("Send to TickTick", $settings.integrations.tickTick.enabled)
            if appSettings.integrations.tickTick.enabled {
                tickTickAccountRow
                if tickTickAuth.isSignedIn {
                    tickTickListRow
                    testRow(for: .tickTick)
                }
            }
        }
        .task(id: tickTickAuth.isSignedIn) { await loadTickTickProjects() }
    }

    @ViewBuilder
    private var tickTickAccountRow: some View {
        if tickTickAuth.isSignedIn {
            SettingsRow(verbatim: "TickTick account", caption: "Connected", systemImage: "person.crop.circle") {
                Button("Sign out") { Task { await tickTickAuth.signOut() } }
                    .buttonStyle(.settingsSecondary)
            }
        } else {
            SettingsRow(verbatim: "TickTick account",
                        caption: tickTickSignInError
                            ?? (tickTickAuth.sessionExpired ? "Your TickTick sign-in expired. Sign in again." : "Not connected"),
                        systemImage: "person.crop.circle") {
                Button(isSigningInToTickTick ? "Signing in…" : "Sign in with TickTick") {
                    Task { await signInToTickTick() }
                }
                .buttonStyle(.settingsPrimary)
                .disabled(isSigningInToTickTick)
            }
        }
    }

    private var tickTickListRow: some View {
        let saved = appSettings.integrations.tickTick
        return SettingsRow(verbatim: "List", caption: tickTickListError, systemImage: "list.bullet") {
            HStack(spacing: 8) {
                if tickTickListError != nil {
                    Button("Retry") { Task { await loadTickTickProjects() } }
                        .buttonStyle(.settingsSecondary)
                }
                Picker("List", selection: tickTickProjectSelection) {
                    Text("Inbox").tag(TickTickAPI.inboxProjectID)
                    ForEach(tickTickProjects, id: \.id) { project in
                        Text(project.name).tag(project.id)
                    }
                    // Keep a saved list selectable while the lists load or after it was deleted.
                    if let id = saved.projectID, !tickTickProjects.contains(where: { $0.id == id }) {
                        Text(saved.projectName ?? "Unavailable list").tag(id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220)
            }
        }
    }

    private var tickTickProjectSelection: Binding<String> {
        Binding(
            get: { appSettings.integrations.tickTick.projectID ?? TickTickAPI.inboxProjectID },
            set: { id in
                var config = appSettings.integrations.tickTick
                config.projectID = id == TickTickAPI.inboxProjectID ? nil : id
                config.projectName = config.projectID == nil ? nil
                    : tickTickProjects.first(where: { $0.id == id })?.name ?? config.projectName
                appSettings.integrations.tickTick = config
            })
    }

    @MainActor
    private func loadTickTickProjects() async {
        tickTickAuth.reload()
        guard tickTickAuth.isSignedIn else {
            tickTickProjects = []
            return
        }
        do {
            tickTickProjects = try await TickTickClient().listProjects(token: tickTickAuth.accessToken())
            tickTickListError = nil
        } catch TickTickError.unauthorized {
            TickTickSession.markExpired()
            tickTickAuth.reload()
        } catch {
            tickTickListError = error.localizedDescription
        }
    }

    @MainActor
    private func signInToTickTick() async {
        tickTickSignInError = nil
        isSigningInToTickTick = true
        defer { isSigningInToTickTick = false }
        do {
            try await tickTickAuth.signIn()
        } catch {
            tickTickSignInError = error.localizedDescription
        }
    }
```

In `runConnectionTest`, after the `do { … } catch { … }` block add:

```swift
        if destination == .tickTick { tickTickAuth.reload() }
```

- [ ] **Step 5: Build and run the full suite**

Run: `swift build 2>&1 | grep -E "error:|warning: .*TickTick" | head; swift build --build-tests 2>&1 | grep -E "error:" | head; swift test --skip-build 2>&1 | grep -E "✘|Test run with"`
Expected: no errors; both test runs report `passed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/dBrief/Services/TickTickAuthService.swift Sources/dBrief/Services/MicrosoftAuthService.swift \
  Sources/dBrief/App/DBriefApp.swift Sources/dBrief/UI/SettingsIntegrationsTab.swift Tests/dBriefTests/SettingsPagesVisualTests.swift
git commit -m "feat(ticktick): sign in with TickTick and choose a list in Settings

Refs #69

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Stamp credentials at build time, docs, live check

**Files:**
- Create: `scripts/stamp-ticktick-credentials.py`
- Create: `scripts/test_ticktick_credentials.py`
- Modify: `Makefile` (after the `STRIP_SU_FEED` block in the app-bundle recipe)
- Modify: `.gitignore`
- Modify: `.github/workflows/ci.yml` (run the new script test)
- Modify: `CLAUDE.md` (Integration Dispatch section), `RELEASING.md` (secrets note)

**Interfaces:**
- Consumes: Info.plist keys `DBTickTickClientID` / `DBTickTickClientSecret` (Task 1).
- Produces: `python3 scripts/stamp-ticktick-credentials.py <Info.plist> [secrets.env]`.

- [ ] **Step 1: Write the failing script test**

Create `scripts/test_ticktick_credentials.py`:

```python
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).with_name("stamp-ticktick-credentials.py")


class TickTickCredentialStampTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.plist = self.root / "Info.plist"
        self.plist.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.dbrief.app"}))

    def stamp(self, env=None, secrets=None):
        arguments = [sys.executable, str(SCRIPT), str(self.plist)]
        if secrets is not None:
            path = self.root / "secrets.env"
            path.write_text(secrets)
            arguments.append(str(path))
        environment = {k: v for k, v in os.environ.items() if not k.startswith("TICKTICK_")}
        environment.update(env or {})
        return subprocess.run(arguments, capture_output=True, text=True, env=environment, check=True)

    def values(self):
        info = plistlib.loads(self.plist.read_bytes())
        return info.get("DBTickTickClientID"), info.get("DBTickTickClientSecret")

    def test_missing_credentials_write_empty_keys(self):
        self.stamp(secrets=None)
        self.assertEqual(self.values(), ("", ""))

    def test_environment_values_are_written_and_never_printed(self):
        result = self.stamp(env={"TICKTICK_CLIENT_ID": "id-1", "TICKTICK_CLIENT_SECRET": "secret-1"})
        self.assertEqual(self.values(), ("id-1", "secret-1"))
        self.assertNotIn("secret-1", result.stdout + result.stderr)

    def test_secrets_file_fills_missing_values_and_environment_wins(self):
        self.stamp(env={"TICKTICK_CLIENT_ID": "from-env"},
                   secrets="# local only\nTICKTICK_CLIENT_ID=from-file\nTICKTICK_CLIENT_SECRET='file secret'\n")
        self.assertEqual(self.values(), ("from-env", "file secret"))

    def test_missing_secrets_file_is_not_an_error(self):
        subprocess.run([sys.executable, str(SCRIPT), str(self.plist), str(self.root / "absent.env")],
                       check=True, capture_output=True,
                       env={k: v for k, v in os.environ.items() if not k.startswith("TICKTICK_")})
        self.assertEqual(self.values(), ("", ""))

    def test_other_keys_are_preserved(self):
        self.stamp(env={"TICKTICK_CLIENT_ID": "a", "TICKTICK_CLIENT_SECRET": "b"})
        self.assertEqual(plistlib.loads(self.plist.read_bytes())["CFBundleIdentifier"], "com.dbrief.app")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 scripts/test_ticktick_credentials.py`
Expected: errors (`can't open file … stamp-ticktick-credentials.py`).

- [ ] **Step 3: Write the stamping script**

Create `scripts/stamp-ticktick-credentials.py`:

```python
#!/usr/bin/env python3
"""Write TickTick OAuth credentials into a built app's Info.plist.

Values come from TICKTICK_CLIENT_ID / TICKTICK_CLIENT_SECRET, falling back to
KEY=VALUE lines in an optional secrets file (gitignored packaging/secrets.env).
Missing values are written as empty strings, which hides TickTick in the app.
Never prints the values: this repository and its CI logs are public.
"""
import os
import pathlib
import plistlib
import sys

KEYS = {
    "TICKTICK_CLIENT_ID": "DBTickTickClientID",
    "TICKTICK_CLIENT_SECRET": "DBTickTickClientSecret",
}


def read_secrets(path):
    values = {}
    if path is None or not path.is_file():
        return values
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip("'\"")
    return values


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit("usage: stamp-ticktick-credentials.py <Info.plist> [secrets.env]")
    plist_path = pathlib.Path(sys.argv[1])
    secrets = read_secrets(pathlib.Path(sys.argv[2]) if len(sys.argv) == 3 else None)
    info = plistlib.loads(plist_path.read_bytes())
    configured = True
    for variable, plist_key in KEYS.items():
        value = os.environ.get(variable) or secrets.get(variable, "")
        info[plist_key] = value
        configured = configured and bool(value)
    plist_path.write_bytes(plistlib.dumps(info))
    print("TickTick credentials: " + ("stamped" if configured else "not set (TickTick hidden)"))


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the script test to verify it passes**

Run: `python3 scripts/test_ticktick_credentials.py`
Expected: `Ran 5 tests … OK`.

- [ ] **Step 5: Wire it into the build, gitignore and CI**

In `Makefile`, directly after the `STRIP_SU_FEED` `@if … fi` block (before `cp Sources/dBrief/Resources/AppIcon.icns`), add a recipe line (tab-indented, `@` so the command is not echoed):

```make
	@python3 scripts/stamp-ticktick-credentials.py "$(CONTENTS)/Info.plist" packaging/secrets.env
```

In `.gitignore`, under the beta build counter lock entry, add:

```gitignore
# TickTick OAuth client credentials for local release/beta builds. Never commit.
/packaging/secrets.env
```

In `.github/workflows/ci.yml`, on the line after `python3 scripts/test_beta_build.py`, add with the same indentation:

```yaml
          python3 scripts/test_ticktick_credentials.py
```

- [ ] **Step 6: Document it**

In `CLAUDE.md`, section "Integration Dispatch":
- Change "Routes post-recording content to eight implemented destinations" to "nine".
- Change the `available` sentence to: "**`IntegrationDestination.available` is the source of truth for which are exposed** — Obsidian, Apple Notes, Apple Reminders and Webhook, plus TickTick in builds stamped with its OAuth credentials."
- Add a table row: `| TickTick | Open API (OAuth2 via \`TickTickAuthService\`) — one task per action item |`
- Add after the table:

```markdown
**TickTick**: "Sign in with TickTick" (`TickTickAuthService`, `ASWebAuthenticationSession`, redirect `dbrief://oauth/ticktick`). TickTick has no PKCE, so the code exchange uses a client secret; the ID/secret are stamped into the built `Info.plist` (`DBTickTickClientID`/`DBTickTickClientSecret`) by `scripts/stamp-ticktick-credentials.py` from `TICKTICK_CLIENT_ID`/`TICKTICK_CLIENT_SECRET` or the gitignored `packaging/secrets.env` — never committed (public repo); unstamped builds hide TickTick. Only the access token is stored (Keychain); there is no refresh token, so a 401 deletes it and sets `ticktick.sessionExpired` (Settings asks to sign in again). Delivery (`IntegrationDispatchService+TickTick.swift`) records created task ids per action item on the delivery (`createdItems`) and, on a retry, matches existing tasks by title + the "added by dBrief" content line before creating, so lost responses don't duplicate tasks.
```

In `RELEASING.md`, add to the build-prerequisites part a line:

```markdown
- **TickTick credentials** (optional): put `TICKTICK_CLIENT_ID=…` and `TICKTICK_CLIENT_SECRET=…` in `packaging/secrets.env` (gitignored) or export them before `make notarize`. The build prints `TickTick credentials: stamped`; without them TickTick is hidden in that build. Never commit them — the repository is public.
```

- [ ] **Step 7: Verify the bundle and full suite**

Run: `make app 2>&1 | grep "TickTick credentials"; /usr/libexec/PlistBuddy -c "Print :DBTickTickClientID" dBrief.app/Contents/Info.plist; swift test --skip-build 2>&1 | grep -E "✘|Test run with"`
Expected: `TickTick credentials: not set (TickTick hidden)` (no secrets on this machine yet), an empty line from PlistBuddy, and the suite passing. Also confirm `git status --short` shows no `packaging/secrets.env`.

- [ ] **Step 8: Commit**

```bash
git add scripts/stamp-ticktick-credentials.py scripts/test_ticktick_credentials.py Makefile .gitignore \
  .github/workflows/ci.yml CLAUDE.md RELEASING.md
git commit -m "build(ticktick): stamp OAuth credentials at build time and document setup

Refs #69

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 9: Live check (needs the user)**

Hand these steps to the user; do not mark #69's TickTick part done until they confirm:

1. At `developer.ticktick.com/manage`, create an app named "dBrief" with redirect URL `dbrief://oauth/ticktick`. If the portal rejects a custom scheme, stop and report it (the spec's loopback fallback is then needed).
2. Write the client ID and secret to `packaging/secrets.env` as `TICKTICK_CLIENT_ID=…` / `TICKTICK_CLIENT_SECRET=…`.
3. `make run-beta`; Settings → Integrations → TickTick: turn it on, **Sign in with TickTick**, pick a list, **Test connection**.
4. Process a short recording with at least two action items; confirm one task per item appears once, with the "added by dBrief" line.
5. Turn Wi-Fi off during processing so the send fails, turn it back on, retry from the delivery review; confirm no duplicates.
