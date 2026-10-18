# TickTick integration (OAuth)

Date: 2026-10-11 · Branch: `ui/redesign` · Issue: #69 (first destination) · Status: approved design, awaiting spec review

## Goal

After a recording is processed, every action item becomes a task in a TickTick list the user chose. The user connects with **Sign in with TickTick** (OAuth), not a pasted token.

Success: a user signs in once, picks a list, and from then on each processed meeting's action items appear in that list. A failed or interrupted send never produces duplicate tasks, and an expired sign-in shows up as "Needs setup" instead of failing silently.

### Decisions already made

| Question | Decision |
|---|---|
| Auth | OAuth2 authorization-code flow. |
| Client secret | Compiled into the app, like the Azure client ID. The secret can be extracted from the binary, but only lets someone pose as dBrief on the consent screen; it grants no access without a user's approval. Rotate it in the TickTick developer portal if abused. |
| What is sent | All action items, automatically, through the existing delivery pipeline (same model as Apple Reminders). No per-meeting selection UI. |

### Out of scope

- Choosing individual action items, or a manual "Send to TickTick" button.
- Due dates, priority, tags, reminders. Action items are plain strings with no reliable dates.
- Two-way sync (completing a task in TickTick changes nothing in dBrief).
- Personal API token entry.
- The other destinations listed in #69 (Teams, Slack, Docs, Todoist, Confluence, Notion).

## TickTick API facts (from `developer.ticktick.com/docs/openapi.md`, 2026-10-11)

- Authorize: `GET https://ticktick.com/oauth/authorize?client_id&scope&state&redirect_uri&response_type=code`. Scopes: `tasks:read tasks:write`.
- Token: `POST https://ticktick.com/oauth/token`, `application/x-www-form-urlencoded`, client ID + secret as **HTTP Basic** auth; body `code`, `grant_type=authorization_code`, `scope`, `redirect_uri`. Response contains `access_token`.
- **No PKCE.** **No refresh token is documented.** Token lifetime is undocumented.
- Revoke: `POST https://api.ticktick.com/oauth/revoke` with `token`.
- API base `https://api.ticktick.com`, header `Authorization: Bearer <token>`.
- Lists: `GET /open/v1/project` → `[{id, name, closed, …}]`.
- List contents: `GET /open/v1/project/{projectId}/data` → includes `tasks`.
- Create: `POST /open/v1/task` with `title` (required), `projectId` (required), `content`. Returns the task with `id`. No client-supplied idempotency key.

`tasks:read` is needed for the list picker and the duplicate check.

## Design

### 1. Sign-in — `Services/TickTickAuthService.swift`

Modelled on `MicrosoftAuthService` (`ASWebAuthenticationSession`, `dbrief` URL scheme already registered in `Info.plist`).

- `@MainActor` service with `signIn()`, `signOut()`, `accessToken() throws -> String`, `isSignedIn`, `accountLabel`.
- `clientID` / `clientSecret` are read from the app bundle's `Info.plist` keys `DBTickTickClientID` / `DBTickTickClientSecret`. **They are never committed to git.** `make app` (and `beta`, `dmg`, `notarize`) fill these keys from the environment variables `TICKTICK_CLIENT_ID` / `TICKTICK_CLIENT_SECRET`, or from a gitignored `packaging/secrets.env` when present; when neither is set the keys are left empty. `static func isConfigured(clientID:) -> Bool` (non-empty) mirrors `MicrosoftAuthService.isConfigured`. Consequence: `swift run`, Homebrew-from-source and CI builds have no credentials, so TickTick is hidden there; only release/beta builds made on a machine with the secrets show it.
- Redirect URI: `http://127.0.0.1:47213/ticktick/callback` (loopback). The TickTick portal rejected the planned `dbrief://oauth/ticktick` (2026-10-11), so the fallback below is in use: the authorize page opens in the default browser and a one-shot listener bound to 127.0.0.1 answers the redirect; 5-minute timeout, cancellable from Settings. A random `state` is generated per attempt and must match on callback; mismatch or a missing `code` fails the sign-in.
- Code exchange: pure request builder `TickTickOAuth.tokenRequest(code:clientID:clientSecret:redirectURI:) -> URLRequest` (Basic header, form body), and pure `TickTickOAuth.authorizeURL(clientID:redirectURI:state:)`. Both unit-tested.
- Storage: access token in Keychain under a new `KeychainSecretKey.tickTickAccessToken`. No expiry is stored (none is documented).
- Account label: TickTick's Open API has no profile endpoint, so the row shows "Connected" rather than an email.
- Sign out: best-effort `POST /oauth/revoke`, then delete the Keychain item regardless of the revoke result.
- **Expired token:** any `401` from the API deletes the stored token and sets a `ticktick.sessionExpired` UserDefaults flag (cleared on successful sign-in). Settings then shows **Needs setup** with "Your TickTick sign-in expired. Sign in again." The delivery itself fails normally (see §4).
- **Redirect fallback:** if the TickTick developer portal rejects a custom-scheme redirect, switch to a loopback redirect (`http://127.0.0.1:<port>/callback`, one-shot local listener). This is decided during the manual registration step and does not change any other section.

### 2. Settings — Integrations → TickTick

- `IntegrationDestination.tickTick` added; included in `available` only when `TickTickAuthService.isConfigured(clientID:)` is true.
- `TickTickConfig { enabled: Bool, projectID: String?, projectName: String? }` in `IntegrationSettings`.
- `IntegrationSettings` gets a custom `init(from:)` using `decodeIfPresent` for `tickTick` (and defaulting it), so settings saved before this change still decode instead of falling back to defaults.
- `configurationDigests` gains a `tickTick` entry hashing `enabled` + `projectID` (credentials excluded, as for the others).
- Detail page in `UI/SettingsIntegrationsTab.swift`, built from the standard Settings components:
  - Account row: "Sign in with TickTick" (`.settingsPrimary`) or "Connected · Sign out".
  - List row: a `Picker` filled from `GET /open/v1/project` (open lists only, sorted by name), with **Inbox** (`projectId = "inbox"`) as the first entry and the default. Loaded when the page appears and after sign-in; shows an inline error with Retry on failure.
  - The existing "Test connection" row: loads the lists (`GET /open/v1/project`). It creates nothing.
  - State pill: **Off** when disabled; **Needs setup** when enabled but not signed in (including an expired sign-in); **On** otherwise. Summary text: "One task per action item · list “<name>”" (Inbox when none chosen).
- Icon: SF Symbol `checkmark.square` (no third-party logo asset; `checklist` is already Reminders').

### 3. What gets sent — `IntegrationDispatchService.sendToTickTick`

- One task per non-empty action item, in the bundle's order, into `projectID` (fallback `"inbox"`).
- `title`: the action item text, trimmed.
- `content`: `From “<meeting title>” · <date, medium style> — added by dBrief (ref <first 8 hex of the batch id>)`. The `(ref …)` is the duplicate-check marker (§4); the localized date is never compared.
- Skipped up front (status `skipped`) when there are no action items, exactly like Reminders.
- Routed through the existing `sendInRecordingContext` switch, `testConnection` switch, privacy tracing and frozen-config check. HTTP goes through the existing `performJSONRequest` bearer helper.
- Pure builder `TickTickTaskRequest.body(title:content:projectID:)` for the JSON payload.

### 4. Partial sends and duplicates

TickTick creates tasks one at a time, so a send can stop part-way.

- `IntegrationDeliveryBatch.Delivery` gains `var createdItems: [Int: String]? = nil` (action-item index → TickTick task id). Optional, so existing delivery records decode unchanged.
- `IntegrationDispatchResult` gains `var createdItems: [Int: String]? = nil`. `sendToTickTick` returns every created index → id on success **and** on failure; the coordinator copies it onto the delivery when it saves the attempt's result. A retry skips indices already in `createdItems`.
- **Lost response or crash mid-attempt:** an item can exist in TickTick without being in `createdItems` (response lost, or the app quit before the attempt's result was saved). So on every retry (`delivery.attempts > 1`), before creating any item, `sendToTickTick` loads `GET /open/v1/project/{projectId}/data` once and treats an existing task with the same `title` **and** this batch's `(ref …)` in its content as already created (records its id, does not create). Each existing task can match only one item.
- Definite failures: `401` → token deleted, `sessionExpired` set, delivery fails. Other 4xx/5xx → delivery fails. The existing coordinator turns failures into `uncertain` and keeps its current user confirmation before retrying; that shared behaviour is not changed.
- On full success, `remoteID` is the created task ids joined by commas (as Reminders does).

### 5. Error handling summary

| Situation | Result |
|---|---|
| Not signed in (or sign-in expired) | Pill "Needs setup". `prepareBatch` leaves TickTick out of the batch when no token is stored, the same as a disabled destination, so nothing is queued for it. |
| 401 during send or list load | Token deleted, `sessionExpired` set; pill "Needs setup", account row says the sign-in expired; delivery fails. |
| Network failure mid-send | Delivery `uncertain`; completed items kept in `createdItems`; retry resumes and de-duplicates. |
| Sign-in cancelled by user | No state change, no error alert. |
| State mismatch / missing code / token exchange error | Inline error on the account row; nothing stored. |

### 6. Testing

Unit tests (swift-testing, URLProtocol-style fake network, no TickTick account):

- Credentials: `isConfigured` false for empty, true for a value; the Makefile leaves the plist keys empty when no secrets are provided (checked by grepping the assembled `Info.plist` in a build step, not a unit test).

- `TickTickOAuthTests`: authorize URL parameters and encoding; token request has Basic auth header, form body, correct redirect; token response parsing; state mismatch rejected.
- `TickTickDeliveryTests`: one task per item with expected title/content/projectId; empty items → skipped; resume skips indices in `createdItems`; retry finds an existing task and does not create it; 401 calls the session-expired hook; not signed in → TickTick left out of the batch.
- `IntegrationSettings` decoding: JSON saved without a `tickTick` key still decodes with all other destinations intact.
- `IntegrationDeliveryBatch`: a legacy record without `createdItems` decodes.
- `IntegrationVisibilityTests`: TickTick hidden with the placeholder client ID, visible with a real one.

Manual (needs the user):

1. Register a "dBrief" app at `developer.ticktick.com/manage` with redirect `http://127.0.0.1:47213/ticktick/callback`; supply client ID and secret.
2. In the beta build: sign in, pick a list, process a recording with action items, confirm tasks appear once; kill the network mid-send, retry, confirm no duplicates.

## Estimate

About 4–5 working days of implementation, plus about 20 minutes of the user's time for app registration and the live check.
