# iCal / EventKit Calendar Integration — Design Spec

**Date:** 2026-06-04  
**Status:** Approved  
**Scope:** Auto-correlate a recording with the matching calendar event at start time; pre-fill PostRecordingSheet fields; inject meeting context into AI prompts.

---

## Goal

When the user starts recording, dBrief looks up the current (or nearest upcoming) calendar event via EventKit and:
1. Pre-fills the meeting title field in `PostRecordingSheet`.
2. Pre-fills the participants field with attendee names.
3. Passes the event description/agenda as context to the AI summary and action-item prompts.

Phase 1 covers **macOS Calendar (iCal)** only. Outlook / Microsoft Graph is a future phase.

---

## New Components

### `Models/CalendarEvent.swift`

Lightweight `Sendable` value type. No EventKit types exposed outside the service.

```swift
struct CalendarEvent: Sendable {
    let title: String
    let attendees: [String]   // display names only
    let body: String          // notes / description / agenda
    let startDate: Date
    let endDate: Date
}
```

### `Services/CalendarService.swift`

`actor CalendarService` — owns the `EKEventStore`, performs all calendar work off the main actor.

**API:**
```swift
func requestAccess() async         // calls requestFullAccessToEvents; idempotent
func authorizationStatus() -> EKAuthorizationStatus
func findCurrentEvent(at date: Date) async -> CalendarEvent?
```

**Matching logic in `findCurrentEvent`:**
1. Query all calendars (`.event` entity) for events in the window `[date − 2h, date + 2h]`.
2. **Primary match**: event where `startDate ≤ date ≤ endDate` — pick the one with the greatest overlap duration if multiple qualify.
3. **Fallback**: if no event is currently active, pick the nearest event whose `startDate` is within ±15 minutes of `date`.
4. Return `nil` if no match or if authorization status is not `.fullAccess`.

---

## Modified Components

### `Models/Recording.swift`

Add one optional property:

```swift
var calendarEvent: CalendarEvent?
```

Not persisted to disk — only used within the current session's processing pipeline.

### `App/AppSettings.swift`

New stored boolean, default `true`:

```swift
var calendarIntegrationEnabled: Bool
```

Key: `"calendarIntegrationEnabled"`.

### `Services/RecordingManager.swift`

- Hold a `CalendarService` instance (initialized in `RecordingManager.init`, mirroring the pattern for other services).
- In `startRecording()`: if `appSettings.calendarIntegrationEnabled`, call `calendarService.findCurrentEvent(at: Date())` and assign to `recording.calendarEvent`.
- In the AI processing path (before dispatching summary / action-item prompts): if `recording.calendarEvent?.body` is non-empty, prepend the following to the prompt:

  ```
  Meeting context from calendar:
  <event.body>
  ```

  Applied to both `summaryPrompt` and `actionItemsPrompt` as a prefix. No new settings needed.

### `UI/PostRecordingSheet.swift`

In `.onAppear`, after setting `meetingTitle` from the existing fallback logic:

1. If `recording.calendarEvent` is non-nil:
   - Overwrite `meetingTitle` with `event.title` **only if** the current value is the generic fallback (`"meeting"` or the associated-app name).
   - Overwrite `participantsText` with `event.attendees.joined(separator: ", ")` if attendees are present.
2. If `recording.calendarEvent` is nil and `calendarIntegrationEnabled` is true:
   - Attempt one more `calendarService.findCurrentEvent(at: recording.startDate)` call.
   - Apply the same pre-fill logic if a match is found.

All fields remain fully editable — no indicator or badge shown.

### `UI/SettingsPermissionsTab.swift`

Add a **Calendar** `PermissionRow` in the "Permissions Check" section, after Speech Recognition:

- Status: derived from `EKEventStore.authorizationStatus(for: .event)` (`.fullAccess` → "Granted", `.denied` → "Denied", `.notDetermined` → "Not determined", `.restricted` → "Restricted").
- Request button: calls `EKEventStore().requestFullAccessToEvents()` then refreshes status.
- "Open System Settings" button with anchor `Privacy_Calendars`.

### `UI/SettingsGeneralTab.swift` (or wherever call detection toggle lives)

Add a toggle row:

> **Pre-fill meeting info from Calendar**  
> Looks up the matching calendar event when recording starts and pre-fills title, participants, and agenda context.

Disabled and greyed out if calendar permission is not `.fullAccess`.

### `Resources/Info.plist`

Add one key:

```xml
<key>NSCalendarsFullAccessUsageDescription</key>
<string>dBrief accesses your calendar to pre-fill meeting title, participants, and agenda context at recording time.</string>
```

---

## Data Flow Summary

```
User presses Record
  └─ RecordingManager.startRecording()
       └─ CalendarService.findCurrentEvent(at: now)   [if enabled + authorized]
            └─ result stored on recording.calendarEvent

User presses Stop
  └─ PostRecordingSheet.onAppear
       ├─ if recording.calendarEvent != nil → pre-fill title + participants
       └─ if nil → one more lookup, apply if found

User presses Process
  └─ RecordingManager builds AI prompts
       └─ if calendarEvent.body non-empty → prepend as context to summary + action-item prompts
```

---

## Error Handling

- **Permission denied**: `findCurrentEvent` returns `nil` silently. Fields behave as today. No error surfaced to the user.
- **No matching event**: returns `nil`. Fields behave as today.
- **EKEventStore throws**: caught inside `CalendarService`; logged via `Logger.recording`; returns `nil`.
- **Empty attendees list**: `participantsText` left as-is (empty or whatever the user typed).

---

## Out of Scope (Phase 1)

- Microsoft Outlook / Graph API calendar
- Persisting the matched event to the Recording's JSON metadata on disk
- Showing which event was matched in the UI
- Automatic profile selection based on calendar event metadata
