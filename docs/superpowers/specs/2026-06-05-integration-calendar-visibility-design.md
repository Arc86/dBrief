# Integration & Calendar Visibility — Design Spec

**Date:** 2026-06-05
**Status:** Approved (design)
**Scope:** Single sub-project decomposed from a larger feature request. Other sub-projects (model settings UX, diarization everywhere, transcript library + viewer redesign, voice library) are deferred to `tasks/todo.md`.

## Goal

Hide integration destinations and a calendar source that are not yet trusted to work, so users only see options that reliably function:

- **Hard-hide** four untested integrations: Notion, Evernote, Google Keep, Microsoft OneNote.
- **Keep visible** the four trusted ones: Obsidian, Apple Notes, Apple Reminders, Webhook.
- **Self-detecting Outlook**: the Outlook (Microsoft) calendar source appears only when a real Azure client ID is configured. Today `MicrosoftAuthService.clientID` is the placeholder `"YOUR-AZURE-CLIENT-ID"`, so Outlook cannot work and must be hidden. When a real ID is set, Outlook reappears with no further code changes.

## Guiding principle

**One source of truth per area, consulted by both the UI and the runtime.** Hiding only in the UI would leave a previously-enabled integration silently dispatching in the background. Since these integrations are hidden precisely because they are untested, *hidden* must mean both *not shown* and *not dispatched*.

## Design

### 1. Integrations — hard-hide the untested four

**Source of truth.** Add a static list of available destinations to `IntegrationDestination` in `Sources/dBrief/Models/Integrations.swift`:

```swift
/// Destinations currently exposed to users. Untested integrations
/// (Notion, Evernote, Google Keep, OneNote) are omitted until verified.
/// Re-enable one by adding its case back to this list.
static let available: [IntegrationDestination] = [
    .obsidian, .appleNotes, .appleReminders, .webhook,
]
```

The `IntegrationDestination` enum itself keeps all eight cases (config structs, dispatch code, and persisted settings remain intact). Only visibility/dispatch gating changes.

**UI.** `Sources/dBrief/UI/SettingsIntegrationsTab.swift` currently iterates a private hardcoded `integrationOrder` array containing all eight cases (lines 9–18, used in the `ForEach` at line 24). Replace that array's contents with `IntegrationDestination.available` (or drop the local array and iterate `IntegrationDestination.available` directly). The four untested rows no longer render. `NavigationLink` destinations for hidden cases become unreachable — acceptable; the detail-view `switch` may keep handling all cases.

**Dispatch.** `Sources/dBrief/Services/IntegrationDispatchService.dispatch(...)` (lines 12–77) guards each destination on `snapshot.config.X.enabled`. Add an availability guard so a stale previously-enabled hidden integration will not fire. Cleanest: gate each `if` on availability, e.g.

```swift
if IntegrationDestination.available.contains(.notion), snapshot.config.notion.enabled { … }
```

Apply to `.notion`, `.evernote`, `.googleKeep`, `.oneNote`. The four trusted destinations are unaffected (they are in `available`). Re-enabling later = add the case back to `available`; both UI and dispatch follow automatically.

### 2. Outlook — self-detecting calendar source

**Configuration flag.** Add to `MicrosoftAuthService` (`Sources/dBrief/Services/MicrosoftAuthService.swift`, near `clientID` at line 22):

```swift
static let placeholderClientID = "YOUR-AZURE-CLIENT-ID"
static var isConfigured: Bool {
    !clientID.isEmpty && clientID != placeholderClientID
}
```

**Picker.** In `Sources/dBrief/UI/SettingsGeneralTab.swift` the Calendar `Picker` (lines 71–76) hardcodes three `Text(...).tag(...)` rows. Render the Outlook row conditionally:

```swift
Picker("Source", selection: $settings.calendarSource) {
    Text("Off").tag(CalendarSource.disabled)
    Text("iCal").tag(CalendarSource.iCal)
    if MicrosoftAuthService.isConfigured {
        Text("Outlook (Microsoft)").tag(CalendarSource.outlook)
    }
}
```

The `switch settings.calendarSource` below (lines 78–129) keeps its `.outlook` case; it simply won't be selectable while unconfigured.

**Safety coercion.** A user may have previously persisted `calendarSource == .outlook`. Once Outlook is hidden, a stored `.outlook` must not drive calendar lookups against the placeholder. Add an effective-source resolution that treats `.outlook` as `.disabled` when `!MicrosoftAuthService.isConfigured`.

- Implementation: a computed `effectiveCalendarSource` (mirroring the existing effective-settings pattern) used by the calendar lookup path, or coerce at the point where `calendarSource` is read for lookup. Do **not** silently rewrite the stored value — coerce at read time so the original selection returns if a client ID is later added.

`CalendarSource` enum (`Sources/dBrief/Models/CalendarSource.swift`) is unchanged — all three cases remain.

### 3. Out of scope (YAGNI)

- No new user-facing settings or toggles.
- No Power User Mode gate (chosen: hard-hide for the four integrations).
- No data migration or cleanup of persisted configs/tokens for hidden integrations — they remain on disk, dormant.
- No changes to the integration config structs, dispatch send-methods, or OAuth flows themselves.

## Testing

Pure logic, unit-testable with swift-testing (`Tests/dBriefTests/`):

1. `IntegrationDestination.available` contains exactly Obsidian, Apple Notes, Apple Reminders, Webhook — and none of Notion/Evernote/Google Keep/OneNote.
2. `MicrosoftAuthService.isConfigured` is `false` for the placeholder and empty string, `true` for a real-looking client ID. (Note: `clientID` is a compile-time `static let`; test `isConfigured`'s predicate logic — extract the comparison into a small testable helper if needed to avoid depending on the constant's current value.)
3. Effective-calendar-source coercion: persisted `.outlook` resolves to `.disabled` when unconfigured, and to `.outlook` when configured; `.iCal` and `.disabled` pass through unchanged.

Manual verification: build and run; confirm Settings → Integrations shows only the four trusted destinations, and the Calendar source picker omits Outlook while the placeholder client ID is in place.

## Files touched

| File | Change |
|------|--------|
| `Models/Integrations.swift` | Add `IntegrationDestination.available` |
| `UI/SettingsIntegrationsTab.swift` | Iterate `available` instead of hardcoded eight |
| `Services/IntegrationDispatchService.swift` | Availability guard on `.notion/.evernote/.googleKeep/.oneNote` |
| `Services/MicrosoftAuthService.swift` | Add `isConfigured` / `placeholderClientID` |
| `UI/SettingsGeneralTab.swift` | Conditionally render Outlook picker row |
| `App/AppSettings.swift` (or effective-settings extension) | Effective calendar-source coercion |
| `Tests/dBriefTests/` | New tests for the three pure-logic points |
