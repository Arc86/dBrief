# Outlook / Microsoft Graph Calendar Integration — Design Spec

**Date:** 2026-06-04  
**Status:** Approved  
**Scope:** Add Microsoft Outlook calendar as an alternative source for the existing calendar pre-fill feature. Phase 2 of calendar integration; Phase 1 (iCal/EventKit) is complete and untouched.

---

## Goal

Allow users to choose Microsoft Outlook (via Microsoft Graph API) as their calendar source instead of macOS Calendar (iCal). When enabled, dBrief authenticates with a Microsoft account (PKCE OAuth2), fetches events from `/v1/me/calendarView` at record start, and populates `Recording.calendarEvent` exactly as the iCal path does — feeding the same `CalendarMatcher`, prompt injection, and `PostRecordingSheet` pre-fill already in place.

---

## Architecture

Three new files, changes to four existing ones. `CalendarService` (EventKit), `CalendarMatcher`, `CalendarEvent`, and all AI prompt injection call sites are **untouched**.

### New Files

| File | Purpose |
|------|---------|
| `Models/CalendarSource.swift` | `enum CalendarSource: String, Codable` with cases `.disabled`, `.iCal`, `.outlook` |
| `Services/MicrosoftAuthService.swift` | PKCE OAuth2 actor — token acquisition, refresh, Keychain storage, account info |
| `Services/OutlookCalendarService.swift` | Graph API actor — fetches events, maps to `CalendarEvent`, feeds `CalendarMatcher` |

### Modified Files

| File | Change |
|------|--------|
| `AppSettings.swift` | Replace `calendarIntegrationEnabled: Bool` with `calendarSource: CalendarSource`; migrate existing value on init |
| `RecordingManager.swift` | Add `MicrosoftAuthService` + `OutlookCalendarService`; switch on `calendarSource` at record start |
| `SettingsGeneralTab.swift` | Replace toggle with source picker + Outlook sign-in card |
| `Resources/Info.plist` | Add `dbrief` custom URL scheme for OAuth redirect |

---

## Prerequisites (Developer One-Time Setup)

Before shipping, register a public client app in Azure portal:

1. Go to portal.azure.com → Azure Active Directory → App registrations → New registration
2. Supported account types: "Accounts in any organizational directory and personal Microsoft accounts" (common endpoint)
3. Add redirect URI: `dbrief://oauth/callback` — platform: **Mobile and desktop applications**
4. Add API permissions: `Calendars.Read` (delegated) + `offline_access` (delegated)
5. No client secret — this is a public client using PKCE
6. Copy the Application (client) ID → hardcode as `MicrosoftAuthService.clientID`

---

## CalendarSource Enum

```swift
// Models/CalendarSource.swift
enum CalendarSource: String, Codable, CaseIterable {
    case disabled
    case iCal
    case outlook
}
```

---

## MicrosoftAuthService

```swift
actor MicrosoftAuthService {
    static let clientID = "<azure-app-client-id>"
    static let redirectURI = "dbrief://oauth/callback"
    static let scopes = "Calendars.Read offline_access"

    var isSignedIn: Bool                  // true when valid tokens exist in Keychain
    private(set) var accountInfo: AccountInfo?   // set after sign-in

    func signIn(presentingWindow: NSWindow?) async throws
    func signOut()
    func getValidAccessToken() async throws -> String
}

struct AccountInfo: Sendable {
    let displayName: String
    let email: String
}
```

### Sign-In Flow (PKCE)

1. Generate `codeVerifier`: 32 cryptographically random bytes → base64url-encoded string
2. Derive `codeChallenge`: SHA256(`codeVerifier`) → base64url-encoded string
3. Build authorization URL: `https://login.microsoftonline.com/common/oauth2/v2.0/authorize` with params `client_id`, `response_type=code`, `redirect_uri`, `scope`, `code_challenge`, `code_challenge_method=S256`
4. Present via `ASWebAuthenticationSession(url:callbackURLScheme:"dbrief")`
5. Extract `code` from the redirect URL query params
6. POST to `https://login.microsoftonline.com/common/oauth2/v2.0/token` with `grant_type=authorization_code`, `code`, `code_verifier`, `client_id`, `redirect_uri`
7. Decode response: `access_token`, `refresh_token`, `expires_in` → store all in Keychain via `KeychainHelper`
8. GET `https://graph.microsoft.com/v1.0/me?$select=displayName,mail` → populate `accountInfo`

### Token Refresh

`getValidAccessToken()`:
- Read stored expiry timestamp from Keychain
- If `Date() + 60s < expiry`: return cached access token immediately
- Otherwise: POST refresh token to `/token` with `grant_type=refresh_token`
- On success: store updated tokens, return new access token
- On failure (refresh revoked/expired): clear Keychain, set `isSignedIn = false`, throw

### Sign-Out

Clear all Keychain entries (`access_token`, `refresh_token`, `expiry`). Set `accountInfo = nil`.

### Keychain Keys

| Key | Value |
|-----|-------|
| `microsoft.accessToken` | Current access token |
| `microsoft.refreshToken` | Refresh token |
| `microsoft.tokenExpiry` | Expiry timestamp as ISO 8601 string |

### Error Handling

`signIn` throws on user cancellation (ASWebAuthenticationSession cancellation), network failure, or unexpected response shape. Callers (`OutlookCalendarService`, Settings UI) catch and handle appropriately. `getValidAccessToken` throws on refresh failure; `OutlookCalendarService` catches and returns `nil`.

---

## OutlookCalendarService

```swift
actor OutlookCalendarService {
    private let authService: MicrosoftAuthService
    private let searchWindow: TimeInterval = 2 * 60 * 60  // ±2 hours

    init(authService: MicrosoftAuthService)
    func findCurrentEvent(at date: Date) async -> CalendarEvent?
}
```

### Event Fetch

`GET https://graph.microsoft.com/v1.0/me/calendarView`

Query parameters:
- `startDateTime`: `date − 2h` formatted as ISO 8601
- `endDateTime`: `date + 2h` formatted as ISO 8601
- `$select`: `subject,bodyPreview,attendees,start,end`

Headers:
- `Authorization: Bearer <token>` (from `authService.getValidAccessToken()`)
- `Prefer: outlook.timezone="UTC"`

The `calendarView` endpoint automatically expands recurring event instances — no special handling required.

### JSON → CalendarEvent Mapping

| Graph field | CalendarEvent field |
|------------|-------------------|
| `subject` | `title` |
| `bodyPreview` | `body` |
| `attendees[].emailAddress.name` | `attendees[]` |
| `start.dateTime` | `startDate` |
| `end.dateTime` | `endDate` |

After mapping all events, calls `CalendarMatcher.selectBestMatch(from:at:)` — identical to the iCal path.

### Error Handling

Any failure (token error, network error, non-200 response, decode failure) is caught, logged via `Logger.calendar`, and returns `nil`. The recording proceeds without calendar pre-fill — same silent-failure behavior as the iCal path.

---

## AppSettings Changes

### CalendarSource property (replaces calendarIntegrationEnabled)

```swift
var calendarSource: CalendarSource {
    didSet { UserDefaults.standard.set(calendarSource.rawValue, forKey: Keys.calendarSource) }
}
```

Key: `"calendarSource"`.

### Migration in init

```swift
// Migrate from Phase 1 bool to Phase 2 enum
if let raw = defaults.string(forKey: Keys.calendarSource),
   let source = CalendarSource(rawValue: raw) {
    self.calendarSource = source
} else if let legacyEnabled = defaults.object(forKey: "calendarIntegrationEnabled") as? Bool {
    self.calendarSource = legacyEnabled ? .iCal : .disabled
} else {
    self.calendarSource = .iCal  // default
}
```

`calendarIntegrationEnabled` is removed from `AppSettings` entirely. Any remaining references in `SettingsGeneralTab` and `PostRecordingSheet` are updated to use `calendarSource`.

---

## AppContext Changes

`MicrosoftAuthService` is owned by `AppContext` (not `RecordingManager`) because both `RecordingManager` and the Settings UI need the same token-holding instance.

```swift
// AppContext.swift
let microsoftAuthService = MicrosoftAuthService()
```

Pass to `RecordingManager.init()` alongside existing `appState`/`appSettings` parameters. Inject into the SwiftUI environment alongside other services so `SettingsGeneralTab` and `PostRecordingSheet` can access it.

---

## RecordingManager Changes

### New properties (alongside existing `calendarService`)

```swift
private let microsoftAuthService: MicrosoftAuthService   // injected via init
private lazy var outlookCalendarService = OutlookCalendarService(authService: microsoftAuthService)
```

### Record-start lookup (replaces existing single-service call)

```swift
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

The fallback lookup in `PostRecordingSheet` mirrors the same switch.

---

## Settings UI

### SettingsGeneralTab — Calendar section

Replace the existing `Toggle` + hint with:

```
Section("Calendar") {
    Picker("Source", selection: $settings.calendarSource) {
        Text("Off").tag(CalendarSource.disabled)
        Text("iCal").tag(CalendarSource.iCal)
        Text("Outlook (Microsoft)").tag(CalendarSource.outlook)
    }

    // Contextual content below the picker:
    switch settings.calendarSource {
    case .iCal:
        // show iCal access hint if not .fullAccess (same text as before)
    case .outlook:
        // show sign-in card (see below)
    case .disabled:
        // nothing
    }
}
```

**Outlook sign-in card (when source = .outlook):**

- Not signed in: `Button("Sign in with Microsoft")` → calls `microsoftAuthService.signIn(presentingWindow:)`; shows inline error on failure
- Signed in: show `accountInfo.displayName` + `accountInfo.email` as secondary text; `Button("Sign out")` → calls `microsoftAuthService.signOut()`
- `MicrosoftAuthService` is passed into `SettingsGeneralTab` as an environment value (same pattern as other services)

### SettingsPermissionsTab

The existing Calendar permission row (iCal/EventKit) remains unconditional — it reflects a system-level permission that is informative regardless of which source is active.

---

## Info.plist

Add the `dbrief` URL scheme so `ASWebAuthenticationSession` can intercept the OAuth redirect:

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

---

## Data Flow

```
User presses Record
  └─ RecordingManager.startRecording()
       ├─ calendarSource == .iCal  → CalendarService.findCurrentEvent(at: now)
       ├─ calendarSource == .outlook → OutlookCalendarService.findCurrentEvent(at: now)
       │     └─ MicrosoftAuthService.getValidAccessToken()
       │          └─ Graph /v1/me/calendarView → map → CalendarMatcher.selectBestMatch
       └─ calendarSource == .disabled → skip

  └─ recording.calendarEvent set (or nil) — same as Phase 1

User presses Stop → PostRecordingSheet pre-fills title + participants (unchanged)
User presses Process → AI prompts augmented with event.body (unchanged)
```

---

## Out of Scope

- Multi-account Outlook support
- Shared / delegated calendar access
- Calendar filtering (which Outlook calendars to include)
- Tenant-specific Azure app (common endpoint covers personal + work accounts)
- Token error recovery UI (silent nil return)
- Persisting matched event to Recording JSON on disk
- Showing which event was matched in the recording UI
