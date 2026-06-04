# Outlook / Microsoft Graph Calendar Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Microsoft Outlook (Microsoft Graph API) as an alternative calendar source alongside the existing iCal integration, selectable via a source picker in Settings, authenticated via PKCE OAuth2 with token storage in Keychain.

**Architecture:** Three new files (`CalendarSource`, `MicrosoftAuthService`, `OutlookCalendarService`) replace the existing `calendarIntegrationEnabled: Bool` in `AppSettings` with a `CalendarSource` enum. `AppContext` owns `MicrosoftAuthService` and injects it via SwiftUI environment. `RecordingManager` switches on `calendarSource` to pick the right service. `CalendarMatcher` and the prompt-injection paths are untouched.

**Tech Stack:** Swift 6.2, CryptoKit (SHA256 for PKCE), AuthenticationServices (ASWebAuthenticationSession), Microsoft Graph REST API, KeychainHelper (existing).

**Prerequisite (developer one-time):** Register an Azure app at portal.azure.com → App registrations. Supported account types: "Accounts in any organizational directory and personal Microsoft accounts". Add redirect URI `dbrief://oauth/callback` (Mobile and desktop applications platform). Add delegated permissions: `Calendars.Read` + `offline_access`. No client secret. Copy the Application (client) ID — you'll need it in Task 3.

---

## File Structure

**Create:**
- `Sources/dBrief/Models/CalendarSource.swift` — `CalendarSource` enum
- `Sources/dBrief/Services/MicrosoftAuthService.swift` — PKCE OAuth2 + Keychain, `@MainActor @Observable`
- `Sources/dBrief/Services/OutlookCalendarService.swift` — Graph API fetch, maps to `CalendarEvent`

**Modify:**
- `Sources/dBrief/Utilities/KeychainHelper.swift` — add 3 Keychain key cases for Microsoft tokens
- `Sources/dBrief/App/AppSettings.swift` — replace `calendarIntegrationEnabled: Bool` with `calendarSource: CalendarSource`
- `Sources/dBrief/UI/SettingsGeneralTab.swift` — minimal compile fix in Task 2; full Calendar section redesign in Task 7
- `Sources/dBrief/UI/PostRecordingSheet.swift` — update `calendarIntegrationEnabled` reference; add Outlook fallback in Task 6
- `Sources/dBrief/App/DBriefApp.swift` — add `microsoftAuthService` to `AppContext`; update `RecordingManager.init` call; inject into environment
- `Sources/dBrief/Services/RecordingManager.swift` — accept `MicrosoftAuthService` in init; add `OutlookCalendarService`; switch on `calendarSource`
- `Sources/dBrief/Resources/Info.plist` — add `dbrief` custom URL scheme

---

## Task 1: CalendarSource enum + Keychain keys

**Files:**
- Create: `Sources/dBrief/Models/CalendarSource.swift`
- Modify: `Sources/dBrief/Utilities/KeychainHelper.swift`

- [ ] **Step 1: Create the CalendarSource enum**

Create `Sources/dBrief/Models/CalendarSource.swift` with this exact content:

```swift
import Foundation

enum CalendarSource: String, Codable, CaseIterable {
    case disabled
    case iCal
    case outlook
}
```

- [ ] **Step 2: Add Keychain key cases for Microsoft tokens**

In `Sources/dBrief/Utilities/KeychainHelper.swift`, the `KeychainSecretKey` enum currently ends at `case oneNote`. Add three new cases immediately after `oneNote`:

```swift
    case microsoftAccessToken = "microsoft.accessToken"
    case microsoftRefreshToken = "microsoft.refreshToken"
    case microsoftTokenExpiry = "microsoft.tokenExpiry"
```

The enum should now look like:
```swift
enum KeychainSecretKey: String, CaseIterable, Sendable {
    case notion = "integration.notion.token"
    case evernote = "integration.evernote.token"
    case googleKeep = "integration.googlekeep.token"
    case oneNote = "integration.onenote.token"
    case microsoftAccessToken = "microsoft.accessToken"
    case microsoftRefreshToken = "microsoft.refreshToken"
    case microsoftTokenExpiry = "microsoft.tokenExpiry"
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/dBrief/Models/CalendarSource.swift Sources/dBrief/Utilities/KeychainHelper.swift
git commit -m "feat(calendar): add CalendarSource enum and Microsoft Keychain keys"
```

---

## Task 2: AppSettings migration + compile fixes

Replace `calendarIntegrationEnabled: Bool` with `calendarSource: CalendarSource`. Migrate existing user preference. Fix the two files that reference the old property so the build stays green throughout.

**Files:**
- Modify: `Sources/dBrief/App/AppSettings.swift`
- Modify: `Sources/dBrief/UI/SettingsGeneralTab.swift`
- Modify: `Sources/dBrief/UI/PostRecordingSheet.swift`

- [ ] **Step 1: Update the Keys enum in AppSettings**

In `Sources/dBrief/App/AppSettings.swift`, find:
```swift
        static let calendarIntegrationEnabled = "calendarIntegrationEnabled"
```
Replace it with:
```swift
        static let calendarSource = "calendarSource"
```

- [ ] **Step 2: Replace the stored property**

Find:
```swift
    var calendarIntegrationEnabled: Bool {
        didSet { UserDefaults.standard.set(calendarIntegrationEnabled, forKey: Keys.calendarIntegrationEnabled) }
    }
```
Replace with:
```swift
    var calendarSource: CalendarSource {
        didSet { UserDefaults.standard.set(calendarSource.rawValue, forKey: Keys.calendarSource) }
    }
```

- [ ] **Step 3: Replace the init line**

Find:
```swift
        self.calendarIntegrationEnabled = defaults.object(forKey: Keys.calendarIntegrationEnabled) as? Bool ?? true
```
Replace with:
```swift
        if let raw = defaults.string(forKey: Keys.calendarSource),
           let source = CalendarSource(rawValue: raw) {
            self.calendarSource = source
        } else if let legacy = defaults.object(forKey: "calendarIntegrationEnabled") as? Bool {
            self.calendarSource = legacy ? .iCal : .disabled
        } else {
            self.calendarSource = .iCal
        }
```

- [ ] **Step 4: Fix SettingsGeneralTab (minimal compile fix)**

In `Sources/dBrief/UI/SettingsGeneralTab.swift`, replace the entire Calendar section (lines 68–82) with a minimal placeholder that compiles. The full redesign happens in Task 7. Replace:

```swift
            Section("Calendar") {
                Toggle("Pre-fill meeting info from Calendar", isOn: $settings.calendarIntegrationEnabled)
                    .disabled(!calendarGranted)

                if !calendarGranted {
                    Text("Grant Calendar access in the Permissions tab to enable this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Looks up the matching calendar event when recording starts and pre-fills title, participants, and agenda context.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.clear)
```

With:

```swift
            Section("Calendar") {
                Picker("Source", selection: $settings.calendarSource) {
                    Text("Off").tag(CalendarSource.disabled)
                    Text("iCal").tag(CalendarSource.iCal)
                    Text("Outlook (Microsoft)").tag(CalendarSource.outlook)
                }
            }
            .listRowBackground(Color.clear)
```

The `calendarGranted` variable declared at line 10 is still referenced by the existing code above, so leave it in place — it just becomes unused until Task 7 restores it.

- [ ] **Step 5: Fix PostRecordingSheet**

In `Sources/dBrief/UI/PostRecordingSheet.swift`, find:
```swift
                } else if appSettings.calendarIntegrationEnabled {
```
Replace with:
```swift
                } else if appSettings.calendarSource == .iCal {
```
(The `.outlook` fallback is wired in Task 6.)

- [ ] **Step 6: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds. You may see a warning about `calendarGranted` being unused — that's expected and resolves in Task 7.

- [ ] **Step 7: Commit**

```bash
git add Sources/dBrief/App/AppSettings.swift Sources/dBrief/UI/SettingsGeneralTab.swift Sources/dBrief/UI/PostRecordingSheet.swift
git commit -m "feat(calendar): replace calendarIntegrationEnabled with CalendarSource enum"
```

---

## Task 3: MicrosoftAuthService

PKCE OAuth2 flow, token lifecycle, account info. `@MainActor @Observable` so it integrates with SwiftUI environment and observation. Network calls are all `async` so `@MainActor` isolation doesn't block the thread.

**Files:**
- Create: `Sources/dBrief/Services/MicrosoftAuthService.swift`

- [ ] **Step 1: Create the file**

Create `Sources/dBrief/Services/MicrosoftAuthService.swift` with this exact content. Replace `YOUR-AZURE-CLIENT-ID` with the client ID from your Azure app registration (see Prerequisite section at top of plan).

```swift
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

private final class WebAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
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
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/Services/MicrosoftAuthService.swift
git commit -m "feat(calendar): add MicrosoftAuthService with PKCE OAuth2 flow"
```

---

## Task 4: OutlookCalendarService

Fetches events from the Microsoft Graph `calendarView` endpoint, maps them to `CalendarEvent`, and runs `CalendarMatcher` — identical outcome as `CalendarService` on the iCal path.

**Files:**
- Create: `Sources/dBrief/Services/OutlookCalendarService.swift`

- [ ] **Step 1: Create the file**

Create `Sources/dBrief/Services/OutlookCalendarService.swift` with this exact content:

```swift
import Foundation
import OSLog

actor OutlookCalendarService {
    private let authService: MicrosoftAuthService
    private let searchWindow: TimeInterval = 2 * 60 * 60  // ±2 hours
    private static let calendarViewURL = "https://graph.microsoft.com/v1.0/me/calendarView"

    init(authService: MicrosoftAuthService) {
        self.authService = authService
    }

    func findCurrentEvent(at date: Date) async -> CalendarEvent? {
        do {
            let token = try await authService.getValidAccessToken()
            return try await fetchEvents(at: date, token: token)
        } catch {
            Logger.calendar.error("Outlook calendar fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Private

    private func fetchEvents(at date: Date, token: String) async throws -> CalendarEvent? {
        var components = URLComponents(string: Self.calendarViewURL)!
        components.queryItems = [
            URLQueryItem(name: "startDateTime", value: graphDateString(date.addingTimeInterval(-searchWindow))),
            URLQueryItem(name: "endDateTime",   value: graphDateString(date.addingTimeInterval(searchWindow))),
            URLQueryItem(name: "$select",       value: "subject,bodyPreview,attendees,start,end"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("outlook.timezone=\"UTC\"", forHTTPHeaderField: "Prefer")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let result = try JSONDecoder().decode(CalendarViewResponse.self, from: data)
        let candidates = result.value.map { Self.makeCalendarEvent(from: $0) }
        return CalendarMatcher.selectBestMatch(from: candidates, at: date)
    }

    // MARK: - JSON types

    private struct CalendarViewResponse: Decodable {
        let value: [GraphEvent]
    }

    private struct GraphEvent: Decodable {
        let subject: String?
        let bodyPreview: String?
        let attendees: [GraphAttendee]?
        let start: GraphDateTimeZone?
        let end: GraphDateTimeZone?
    }

    private struct GraphAttendee: Decodable {
        let emailAddress: GraphEmailAddress?
    }

    private struct GraphEmailAddress: Decodable {
        let name: String?
    }

    private struct GraphDateTimeZone: Decodable {
        let dateTime: String?
    }

    // MARK: - Mapping

    private static func makeCalendarEvent(from event: GraphEvent) -> CalendarEvent {
        let names: [String] = (event.attendees ?? []).compactMap { attendee in
            let name = attendee.emailAddress?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? nil : name
        }
        return CalendarEvent(
            title: event.subject ?? "",
            attendees: names,
            body: event.bodyPreview ?? "",
            startDate: parseGraphDate(event.start?.dateTime),
            endDate: parseGraphDate(event.end?.dateTime)
        )
    }

    /// Graph calendarView returns UTC dates without 'Z': "2026-06-04T10:00:00.0000000"
    private static func parseGraphDate(_ string: String?) -> Date {
        guard let string else { return Date() }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSS"
        if let d = f.date(from: string) { return d }
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: string) ?? Date()
    }

    /// ISO 8601 format expected by Graph query parameters.
    private func graphDateString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/Services/OutlookCalendarService.swift
git commit -m "feat(calendar): add OutlookCalendarService using Microsoft Graph calendarView"
```

---

## Task 5: AppContext + RecordingManager wiring

Wire `MicrosoftAuthService` into `AppContext` so it's owned centrally and accessible to both `RecordingManager` and the Settings UI via SwiftUI environment.

**Files:**
- Modify: `Sources/dBrief/App/DBriefApp.swift`
- Modify: `Sources/dBrief/Services/RecordingManager.swift`

- [ ] **Step 1: Add microsoftAuthService to AppContext**

In `Sources/dBrief/App/DBriefApp.swift`, in the `AppContext` class body, add this property after `let audioPlayer = AudioPlayer()`:

```swift
    let microsoftAuthService = MicrosoftAuthService()
```

- [ ] **Step 2: Update RecordingManager init call in AppContext**

In `AppContext.init()`, find:
```swift
        self.recordingManager = RecordingManager(appState: appState, appSettings: appSettings, transcriptStore: transcriptStore)
```
Replace with:
```swift
        self.recordingManager = RecordingManager(appState: appState, appSettings: appSettings, transcriptStore: transcriptStore, microsoftAuthService: microsoftAuthService)
```

- [ ] **Step 3: Inject microsoftAuthService into SwiftUI environment**

`MicrosoftAuthService` needs to be in the environment so `SettingsGeneralTab` and `PostRecordingSheet` can access it. In `DBriefApp.swift`, find the Settings `WindowGroup` environment chain (around line 157–159):
```swift
                .environment(context.appSettings)
                .environment(context.recordingManager)
```
Add after `context.recordingManager`:
```swift
                .environment(context.microsoftAuthService)
```

Also add it to the main `MenuBarExtra` environment chain. Find the lines that inject into the menu bar popover (around line 120–123):
```swift
                .environment(context.appState)
                .environment(context.appSettings)
                .environment(context.recordingManager)
                .environment(context.audioPlayer)
```
Add after `context.audioPlayer`:
```swift
                .environment(context.microsoftAuthService)
```

- [ ] **Step 4: Update RecordingManager init signature**

In `Sources/dBrief/Services/RecordingManager.swift`, find the properties block (just after `private let calendarService = CalendarService()`) and add two new properties:

```swift
    private let microsoftAuthService: MicrosoftAuthService
    private let outlookCalendarService: OutlookCalendarService
```

Find the `init` method:
```swift
    init(appState: AppState, appSettings: AppSettings, transcriptStore: TranscriptStore) {
        self.appState = appState
        self.appSettings = appSettings
        self.transcriptStore = transcriptStore
    }
```
Replace with:
```swift
    init(appState: AppState, appSettings: AppSettings, transcriptStore: TranscriptStore, microsoftAuthService: MicrosoftAuthService) {
        self.appState = appState
        self.appSettings = appSettings
        self.transcriptStore = transcriptStore
        self.microsoftAuthService = microsoftAuthService
        self.outlookCalendarService = OutlookCalendarService(authService: microsoftAuthService)
    }
```

- [ ] **Step 5: Replace the calendar lookup in startRecording**

In `RecordingManager.startRecording()`, find:
```swift
        if appSettings.calendarIntegrationEnabled {
            let started = recording.date
            Task { [weak recording] in
                let event = await calendarService.findCurrentEvent(at: started)
                await MainActor.run { recording?.calendarEvent = event }
            }
        }
```
Replace with:
```swift
        let started = recording.date
        switch appSettings.calendarSource {
        case .iCal:
            Task { [weak recording] in
                let event = await calendarService.findCurrentEvent(at: started)
                await MainActor.run { recording?.calendarEvent = event }
            }
        case .outlook:
            Task { [weak recording] in
                let event = await outlookCalendarService.findCurrentEvent(at: started)
                await MainActor.run { recording?.calendarEvent = event }
            }
        case .disabled:
            break
        }
```

- [ ] **Step 6: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 7: Run all tests**

Run: `swift test`
Expected: All tests pass (the calendar path changes are not covered by unit tests — the pure `CalendarMatcher` tests still pass).

- [ ] **Step 8: Commit**

```bash
git add Sources/dBrief/App/DBriefApp.swift Sources/dBrief/Services/RecordingManager.swift
git commit -m "feat(calendar): wire MicrosoftAuthService into AppContext and RecordingManager"
```

---

## Task 6: PostRecordingSheet — Outlook fallback

When `calendarSource == .outlook` and `recording.calendarEvent` is still `nil` when the sheet appears (race between record start and sheet open), attempt one more lookup via `OutlookCalendarService`.

**Files:**
- Modify: `Sources/dBrief/UI/PostRecordingSheet.swift`

- [ ] **Step 1: Add environment property for MicrosoftAuthService**

In `Sources/dBrief/UI/PostRecordingSheet.swift`, near the other `@Environment` declarations at the top of the struct (around line 10–15), add:

```swift
    @Environment(MicrosoftAuthService.self) private var microsoftAuthService
```

- [ ] **Step 2: Add the Outlook fallback branch**

In `PostRecordingSheet`, find the calendar fallback block in `.onAppear` (introduced in Phase 1):
```swift
                } else if appSettings.calendarSource == .iCal {
                    let started = recording.date
                    Task { [weak recording] in
                        guard let event = await calendarService.findCurrentEvent(at: started) else { return }
                        await MainActor.run {
                            guard let recording else { return }
                            recording.calendarEvent = event
                            applyCalendarEvent(event, to: recording)
                        }
                    }
                }
```

Replace with:
```swift
                } else if appSettings.calendarSource == .iCal {
                    let started = recording.date
                    Task { [weak recording] in
                        guard let event = await calendarService.findCurrentEvent(at: started) else { return }
                        await MainActor.run {
                            guard let recording else { return }
                            recording.calendarEvent = event
                            applyCalendarEvent(event, to: recording)
                        }
                    }
                } else if appSettings.calendarSource == .outlook {
                    let started = recording.date
                    let outlookService = OutlookCalendarService(authService: microsoftAuthService)
                    Task { [weak recording] in
                        guard let event = await outlookService.findCurrentEvent(at: started) else { return }
                        await MainActor.run {
                            guard let recording else { return }
                            recording.calendarEvent = event
                            applyCalendarEvent(event, to: recording)
                        }
                    }
                }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/dBrief/UI/PostRecordingSheet.swift
git commit -m "feat(calendar): add Outlook fallback lookup in PostRecordingSheet"
```

---

## Task 7: SettingsGeneralTab — full Calendar section redesign

Replace the placeholder picker from Task 2 with the full source picker + contextual Outlook sign-in card.

**Files:**
- Modify: `Sources/dBrief/UI/SettingsGeneralTab.swift`

- [ ] **Step 1: Add MicrosoftAuthService environment property**

In `SettingsGeneralTab`, add after the existing `@Environment` properties:

```swift
    @Environment(MicrosoftAuthService.self) private var microsoftAuthService
```

- [ ] **Step 2: Add the sign-in state property**

Add a `@State` property for showing inline sign-in errors, after the struct opening:

```swift
    @State private var outlookSignInError: String?
```

- [ ] **Step 3: Replace the Calendar section**

Find and replace the entire Calendar section (the placeholder from Task 2):
```swift
            Section("Calendar") {
                Picker("Source", selection: $settings.calendarSource) {
                    Text("Off").tag(CalendarSource.disabled)
                    Text("iCal").tag(CalendarSource.iCal)
                    Text("Outlook (Microsoft)").tag(CalendarSource.outlook)
                }
            }
            .listRowBackground(Color.clear)
```

Replace with:
```swift
            Section("Calendar") {
                Picker("Source", selection: $settings.calendarSource) {
                    Text("Off").tag(CalendarSource.disabled)
                    Text("iCal").tag(CalendarSource.iCal)
                    Text("Outlook (Microsoft)").tag(CalendarSource.outlook)
                }

                switch settings.calendarSource {
                case .iCal:
                    if !calendarGranted {
                        Text("Grant Calendar access in the Permissions tab to enable this.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Looks up the matching calendar event when recording starts and pre-fills title, participants, and agenda context.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .outlook:
                    if microsoftAuthService.isSignedIn {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(microsoftAuthService.accountInfo?.displayName ?? "Microsoft Account")
                                    .fontWeight(.medium)
                                Text(microsoftAuthService.accountInfo?.email ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Sign out") {
                                microsoftAuthService.signOut()
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Button("Sign in with Microsoft") {
                                outlookSignInError = nil
                                Task {
                                    do {
                                        try await microsoftAuthService.signIn()
                                    } catch {
                                        outlookSignInError = error.localizedDescription
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            if let error = outlookSignInError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                case .disabled:
                    EmptyView()
                }
            }
            .listRowBackground(Color.clear)
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds with no warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/UI/SettingsGeneralTab.swift
git commit -m "feat(calendar): redesign Calendar section with source picker and Outlook sign-in card"
```

---

## Task 8: Info.plist — dbrief URL scheme

`ASWebAuthenticationSession` intercepts the OAuth redirect using a custom URL scheme. The scheme must be registered in `Info.plist`.

**Files:**
- Modify: `Sources/dBrief/Resources/Info.plist`

- [ ] **Step 1: Add the URL scheme**

In `Sources/dBrief/Resources/Info.plist`, add the following block before the closing `</dict>` tag. Place it near the other `NS...` keys:

```xml
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>com.dbrief.app</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>dbrief</string>
			</array>
		</dict>
	</array>
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/Resources/Info.plist
git commit -m "feat(calendar): add dbrief URL scheme for OAuth redirect"
```

---

## Task 9: Full verification

- [ ] **Step 1: Clean build**

Run: `swift build`
Expected: Build succeeds with no errors.

- [ ] **Step 2: Full test suite**

Run: `swift test`
Expected: All tests pass, including the existing `CalendarMatcherTests` (5) and `CalendarContextTests` (4).

- [ ] **Step 3: App bundle build**

Run: `make app`
Expected: Bundle assembles successfully with the `CFBundleURLTypes` entry visible in the embedded `Info.plist`.

Verify with:
```bash
/usr/libexec/PlistBuddy -c "Print CFBundleURLTypes" dBrief.app/Contents/Info.plist
```
Expected: Output includes `dbrief` under `CFBundleURLSchemes`.

- [ ] **Step 4: Manual sign-in smoke test**

1. Launch the app (`make run`).
2. Open Settings → General → Calendar section.
3. Set Source to "Outlook (Microsoft)".
4. Click "Sign in with Microsoft" — a browser sheet opens.
5. Complete sign-in with a Microsoft account (personal or work).
6. Sheet closes; Settings shows the account name + email + "Sign out" button.
7. Verify `isSignedIn` persists after quitting and relaunching the app (tokens in Keychain).

- [ ] **Step 5: Manual recording pre-fill smoke test**

1. With Outlook source selected and signed in, create a calendar event in Outlook spanning the current time.
2. Start a recording; stop it immediately.
3. Confirm `PostRecordingSheet` pre-fills the title (and participants, if attendees are set on the event).

- [ ] **Step 6: Update todo.md**

Mark "Calendar integration (Phase 2 — Outlook/Exchange)" as complete in `tasks/todo.md`.

---

## Self-Review Notes

- **Spec coverage:** `CalendarSource` enum (Task 1), `AppSettings` migration (Task 2), `MicrosoftAuthService` PKCE + Keychain + AccountInfo (Task 3), `OutlookCalendarService` Graph fetch + CalendarMatcher (Task 4), `AppContext` ownership + `RecordingManager` switch (Task 5), `PostRecordingSheet` fallback (Task 6), Settings picker + sign-in card (Task 7), URL scheme (Task 8). All spec sections covered.
- **Type consistency:** `CalendarSource` used consistently across all tasks. `MicrosoftAuthService.signIn()` (no parameters, uses `NSApp.windows` internally), `MicrosoftAuthService.signOut()`, `MicrosoftAuthService.getValidAccessToken() async throws -> String`, and `MicrosoftAuthService.isSignedIn: Bool` / `accountInfo: AccountInfo?` are referenced consistently in Tasks 3, 5, 6, 7.
- **`calendarGranted` variable:** The variable declared at line 10 of `SettingsGeneralTab` is restored to useful purpose in Task 7 (iCal branch shows the permission hint). No dangling dead code.
- **No unit tests:** `MicrosoftAuthService` and `OutlookCalendarService` involve network I/O and system APIs (Keychain, ASWebAuthenticationSession) with no practical unit-test seam. The pure core (`CalendarMatcher`) is already tested. Manual smoke test in Task 9 covers the integration path.
