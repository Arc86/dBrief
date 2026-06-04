# iCal / EventKit Calendar Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-correlate a recording with the matching macOS Calendar event at record-start time, pre-fill the meeting title and participants in PostRecordingSheet, and inject the event agenda into AI summary/action-item prompts.

**Architecture:** A pure matching function (`CalendarMatcher`) selects the best event from candidates by time overlap. An `actor CalendarService` wraps `EKEventStore`, queries a time window, and feeds candidates to the matcher. `RecordingManager` calls the service on record start, stores a `CalendarEvent` value type on the `Recording`, and prepends the event agenda to AI prompts. `PostRecordingSheet` silently pre-fills its fields. Settings gain a toggle and a Calendar permission row.

**Tech Stack:** Swift 6.2, EventKit (`EKEventStore`, macOS 14+ `requestFullAccessToEvents`), swift-testing, SwiftUI.

---

## File Structure

**Create:**
- `Sources/dBrief/Models/CalendarEvent.swift` — `Sendable` value type for a matched event
- `Sources/dBrief/Services/CalendarMatcher.swift` — pure, static best-match selection (testable core)
- `Sources/dBrief/Services/CalendarService.swift` — `actor` wrapping `EKEventStore`
- `Tests/dBriefTests/CalendarMatcherTests.swift` — matcher unit tests
- `Tests/dBriefTests/CalendarContextTests.swift` — prompt-augmentation + CalendarEvent tests

**Modify:**
- `Sources/dBrief/Models/Recording.swift` — add `var calendarEvent: CalendarEvent?`
- `Sources/dBrief/App/AppSettings.swift` — add `calendarIntegrationEnabled` key, property, load
- `Sources/dBrief/Services/RecordingManager.swift` — hold `CalendarService`, lookup on start, prompt injection helper
- `Sources/dBrief/UI/PostRecordingSheet.swift` — pre-fill on appear
- `Sources/dBrief/UI/SettingsGeneralTab.swift` — calendar toggle
- `Sources/dBrief/UI/SettingsPermissionsTab.swift` — Calendar permission row
- `Sources/dBrief/Resources/Info.plist` — `NSCalendarsFullAccessUsageDescription`

---

## Task 1: CalendarEvent value type

**Files:**
- Create: `Sources/dBrief/Models/CalendarEvent.swift`

- [ ] **Step 1: Create the model**

```swift
import Foundation

/// A calendar event matched to a recording, carrying only the fields dBrief needs.
/// EventKit types are never exposed outside `CalendarService`.
struct CalendarEvent: Sendable, Equatable {
    let title: String
    let attendees: [String]   // display names only
    let body: String          // notes / description / agenda
    let startDate: Date
    let endDate: Date

    /// Comma-separated attendee names, for pre-filling the participants field.
    var participantsText: String {
        attendees.joined(separator: ", ")
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/Models/CalendarEvent.swift
git commit -m "feat(calendar): add CalendarEvent value type"
```

---

## Task 2: CalendarMatcher pure matching logic (TDD)

The matcher is the testable core. `CalendarService` will feed it candidate events; it picks the best match by time, with no EventKit dependency.

**Files:**
- Create: `Sources/dBrief/Services/CalendarMatcher.swift`
- Test: `Tests/dBriefTests/CalendarMatcherTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import dBrief

struct CalendarMatcherTests {
    private func event(_ title: String, _ start: String, _ end: String) -> CalendarEvent {
        let f = ISO8601DateFormatter()
        return CalendarEvent(
            title: title,
            attendees: [],
            body: "",
            startDate: f.date(from: start)!,
            endDate: f.date(from: end)!
        )
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    @Test
    func picksActiveEventContainingTheReferenceTime() {
        let candidates = [
            event("Morning Standup", "2026-06-04T09:00:00Z", "2026-06-04T09:15:00Z"),
            event("Weekly Sync", "2026-06-04T10:00:00Z", "2026-06-04T11:00:00Z"),
        ]
        let match = CalendarMatcher.selectBestMatch(from: candidates, at: date("2026-06-04T10:30:00Z"))
        #expect(match?.title == "Weekly Sync")
    }

    @Test
    func prefersGreatestOverlapWhenMultipleActive() {
        let candidates = [
            event("Quick Chat", "2026-06-04T10:25:00Z", "2026-06-04T10:35:00Z"),  // 10 min, contains 10:30
            event("All Hands", "2026-06-04T10:00:00Z", "2026-06-04T11:00:00Z"),   // 60 min, contains 10:30
        ]
        let match = CalendarMatcher.selectBestMatch(from: candidates, at: date("2026-06-04T10:30:00Z"))
        #expect(match?.title == "All Hands")
    }

    @Test
    func fallsBackToNearestStartWithinFifteenMinutes() {
        let candidates = [
            event("Upcoming Review", "2026-06-04T10:40:00Z", "2026-06-04T11:00:00Z"),
        ]
        // No active event at 10:30, but one starts 10 min later.
        let match = CalendarMatcher.selectBestMatch(from: candidates, at: date("2026-06-04T10:30:00Z"))
        #expect(match?.title == "Upcoming Review")
    }

    @Test
    func returnsNilWhenNearestStartExceedsFifteenMinutes() {
        let candidates = [
            event("Later Meeting", "2026-06-04T11:00:00Z", "2026-06-04T12:00:00Z"),
        ]
        let match = CalendarMatcher.selectBestMatch(from: candidates, at: date("2026-06-04T10:30:00Z"))
        #expect(match == nil)
    }

    @Test
    func returnsNilForEmptyCandidates() {
        let match = CalendarMatcher.selectBestMatch(from: [], at: date("2026-06-04T10:30:00Z"))
        #expect(match == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter CalendarMatcherTests`
Expected: FAIL — "cannot find 'CalendarMatcher' in scope".

- [ ] **Step 3: Implement the matcher**

```swift
import Foundation

/// Pure best-match selection for calendar events. No EventKit dependency, fully testable.
enum CalendarMatcher {
    /// Window for the "starting soon" fallback when no event is currently active.
    static let fallbackWindow: TimeInterval = 15 * 60  // 15 minutes

    /// Selects the event that best corresponds to `date`.
    /// 1. Among events where startDate <= date <= endDate, pick the greatest overlap with `date`
    ///    (i.e. the longest event still running). 2. Otherwise pick the nearest event whose
    ///    startDate is within ±fallbackWindow of `date`. 3. Otherwise nil.
    static func selectBestMatch(from candidates: [CalendarEvent], at date: Date) -> CalendarEvent? {
        let active = candidates.filter { $0.startDate <= date && date <= $0.endDate }
        if !active.isEmpty {
            return active.max { lhs, rhs in
                lhs.endDate.timeIntervalSince(lhs.startDate) < rhs.endDate.timeIntervalSince(rhs.startDate)
            }
        }

        let upcoming = candidates
            .filter { abs($0.startDate.timeIntervalSince(date)) <= fallbackWindow }
            .min { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) }
        return upcoming
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter CalendarMatcherTests`
Expected: PASS — all 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Services/CalendarMatcher.swift Tests/dBriefTests/CalendarMatcherTests.swift
git commit -m "feat(calendar): add pure CalendarMatcher best-match logic with tests"
```

---

## Task 3: Calendar context prompt augmentation (TDD)

A pure helper that prepends the event agenda to an AI system prompt. Defined as a static function on `CalendarEvent` so both the test and `RecordingManager` can use it.

**Files:**
- Modify: `Sources/dBrief/Models/CalendarEvent.swift`
- Test: `Tests/dBriefTests/CalendarContextTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import dBrief

struct CalendarContextTests {
    private func makeEvent(body: String) -> CalendarEvent {
        CalendarEvent(
            title: "Weekly Sync",
            attendees: ["Alice", "Bob"],
            body: body,
            startDate: Date(),
            endDate: Date()
        )
    }

    @Test
    func participantsTextJoinsAttendees() {
        let event = makeEvent(body: "")
        #expect(event.participantsText == "Alice, Bob")
    }

    @Test
    func augmentingPrependsContextWhenBodyPresent() {
        let event = makeEvent(body: "Discuss Q2 roadmap and hiring.")
        let augmented = CalendarEvent.augment(prompt: "You are a helpful assistant.", with: event)
        #expect(augmented.contains("Meeting context from calendar:"))
        #expect(augmented.contains("Discuss Q2 roadmap and hiring."))
        #expect(augmented.hasSuffix("You are a helpful assistant."))
    }

    @Test
    func augmentingReturnsBasePromptWhenNoEvent() {
        let augmented = CalendarEvent.augment(prompt: "Base prompt.", with: nil)
        #expect(augmented == "Base prompt.")
    }

    @Test
    func augmentingReturnsBasePromptWhenBodyBlank() {
        let event = makeEvent(body: "   \n  ")
        let augmented = CalendarEvent.augment(prompt: "Base prompt.", with: event)
        #expect(augmented == "Base prompt.")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter CalendarContextTests`
Expected: FAIL — "type 'CalendarEvent' has no member 'augment'".

- [ ] **Step 3: Add the augment helper to CalendarEvent**

Append to `Sources/dBrief/Models/CalendarEvent.swift` inside the struct (after `participantsText`):

```swift
    /// Prepends this event's agenda to a base AI system prompt. Returns the base prompt
    /// unchanged when `event` is nil or its body is blank.
    static func augment(prompt basePrompt: String, with event: CalendarEvent?) -> String {
        guard let body = event?.body,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return basePrompt
        }
        return "Meeting context from calendar:\n\(body)\n\n\(basePrompt)"
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter CalendarContextTests`
Expected: PASS — all 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Models/CalendarEvent.swift Tests/dBriefTests/CalendarContextTests.swift
git commit -m "feat(calendar): add prompt augmentation helper with tests"
```

---

## Task 4: CalendarService actor (EventKit wiring)

Wraps `EKEventStore`. Not unit-tested (requires real calendar access and system permission state); verified by building. The pure matching it relies on is already covered by Task 2.

**Files:**
- Create: `Sources/dBrief/Services/CalendarService.swift`

- [ ] **Step 1: Add a logger category**

Check `Sources/dBrief/Utilities/Logger+Extensions.swift` for an existing `Logger.recording` (used elsewhere in RecordingManager). If a `calendar` category does not exist, add one mirroring the existing pattern:

```swift
static let calendar = Logger(subsystem: subsystem, category: "calendar")
```

(If unsure of the exact `subsystem` constant, copy the surrounding line for `recording` and change the category string.)

- [ ] **Step 2: Create the service**

```swift
import Foundation
@preconcurrency import EventKit
import OSLog

/// Reads the user's macOS Calendar via EventKit and finds the event matching a recording's
/// start time. All EventKit access is serialized on this actor; only `CalendarEvent` value
/// types cross the isolation boundary.
actor CalendarService {
    private let store = EKEventStore()

    /// Window queried around the reference date when searching for candidate events.
    private let searchWindow: TimeInterval = 2 * 60 * 60  // ±2 hours

    nonisolated func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Requests full calendar access. Safe to call repeatedly. Returns the granted flag.
    @discardableResult
    func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            Logger.calendar.error("Calendar access request failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Finds the calendar event best matching `date`, or nil if none matches or access is denied.
    func findCurrentEvent(at date: Date) async -> CalendarEvent? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return nil
        }

        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-searchWindow),
            end: date.addingTimeInterval(searchWindow),
            calendars: nil
        )

        let ekEvents = store.events(matching: predicate)
        let candidates = ekEvents.map { Self.makeCalendarEvent(from: $0) }
        return CalendarMatcher.selectBestMatch(from: candidates, at: date)
    }

    /// Maps an EKEvent into our Sendable value type, extracting attendee display names.
    private static func makeCalendarEvent(from ekEvent: EKEvent) -> CalendarEvent {
        let names: [String] = (ekEvent.attendees ?? []).compactMap { participant in
            let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? nil : name
        }
        return CalendarEvent(
            title: ekEvent.title ?? "",
            attendees: names,
            body: ekEvent.notes ?? "",
            startDate: ekEvent.startDate ?? Date(),
            endDate: ekEvent.endDate ?? Date()
        )
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds. If `Logger.calendar` errors, confirm Step 1 added the category.

- [ ] **Step 4: Commit**

```bash
git add Sources/dBrief/Services/CalendarService.swift Sources/dBrief/Utilities/Logger+Extensions.swift
git commit -m "feat(calendar): add CalendarService actor wrapping EKEventStore"
```

---

## Task 5: Info.plist usage description + EventKit link check

**Files:**
- Modify: `Sources/dBrief/Resources/Info.plist`

- [ ] **Step 1: Add the usage description key**

Insert before the closing `</dict>` in `Info.plist`, keeping the existing alphabetical-ish grouping near the other `NS...UsageDescription` keys:

```xml
	<key>NSCalendarsFullAccessUsageDescription</key>
	<string>dBrief accesses your calendar to pre-fill meeting title, participants, and agenda context at recording time.</string>
```

- [ ] **Step 2: Confirm EventKit is already available**

EventKit is already imported in `Sources/dBrief/Services/IntegrationDispatchService.swift` (Reminders use `EKEventStore`), so no new SPM linker setting is required. Verify with:

Run: `grep -rn "import EventKit" Sources/dBrief/`
Expected: At least `IntegrationDispatchService.swift` and the new `CalendarService.swift`.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/Resources/Info.plist
git commit -m "feat(calendar): add NSCalendarsFullAccessUsageDescription"
```

---

## Task 6: Recording.calendarEvent property

**Files:**
- Modify: `Sources/dBrief/Models/Recording.swift`

- [ ] **Step 1: Add the property**

In `Recording`, add after the `participants` property (around line 21):

```swift
    /// Calendar event matched at record-start time, used to pre-fill fields and AI context.
    /// Not persisted to disk — only valid for the current session's processing run.
    var calendarEvent: CalendarEvent?
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds (the property has a default of nil via optional, no init change needed).

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/Models/Recording.swift
git commit -m "feat(calendar): add calendarEvent to Recording"
```

---

## Task 7: AppSettings calendarIntegrationEnabled toggle

**Files:**
- Modify: `Sources/dBrief/App/AppSettings.swift`

- [ ] **Step 1: Add the storage key**

In the `Keys` enum (after `parakeetModelVariant` around line 55):

```swift
        static let calendarIntegrationEnabled = "calendarIntegrationEnabled"
```

- [ ] **Step 2: Add the property**

Next to `callDetectionEnabled` (around line 437), add:

```swift
    var calendarIntegrationEnabled: Bool {
        didSet { UserDefaults.standard.set(calendarIntegrationEnabled, forKey: Keys.calendarIntegrationEnabled) }
    }
```

- [ ] **Step 3: Load it in init**

Near the `callDetectionEnabled` load line (around line 585), add:

```swift
        self.calendarIntegrationEnabled = defaults.object(forKey: Keys.calendarIntegrationEnabled) as? Bool ?? true
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/App/AppSettings.swift
git commit -m "feat(calendar): add calendarIntegrationEnabled setting"
```

---

## Task 8: RecordingManager — lookup on start + AI prompt injection

**Files:**
- Modify: `Sources/dBrief/Services/RecordingManager.swift`

- [ ] **Step 1: Add the CalendarService instance**

Next to the other service properties (around line 29, after `youtubeDownloadService`):

```swift
    private let calendarService = CalendarService()
```

- [ ] **Step 2: Look up the event on record start**

In `startRecording(associatedApp:)`, after `appState.currentRecording = recording` (line 83) and before the `audioCaptureManager.startRecording` call, add:

```swift
        if appSettings.calendarIntegrationEnabled {
            let started = recording.date
            Task { [weak recording] in
                let event = await calendarService.findCurrentEvent(at: started)
                await MainActor.run { recording?.calendarEvent = event }
            }
        }
```

This runs concurrently so calendar I/O never blocks the start of audio capture.

- [ ] **Step 3: Inject calendar context into Apple Intelligence prompts**

In `runAppleIntelligenceTasks`, replace the summary prompt argument (line 849) `systemPrompt: appSettings.effectiveSummaryPrompt` with:

```swift
                    systemPrompt: CalendarEvent.augment(prompt: appSettings.effectiveSummaryPrompt, with: recording.calendarEvent)
```

And the action-items prompt (line 861) `systemPrompt: appSettings.effectiveActionItemsPrompt` with:

```swift
                    systemPrompt: CalendarEvent.augment(prompt: appSettings.effectiveActionItemsPrompt, with: recording.calendarEvent)
```

(Leave the tags prompt unchanged — agenda context is not relevant to tag/sentiment classification.)

- [ ] **Step 4: Inject calendar context into remote endpoint prompts**

In the remote AI tasks function (the one using `aiService.generateSummary`, around line 982), replace `systemPrompt: appSettings.effectiveSummaryPrompt` with:

```swift
                    systemPrompt: CalendarEvent.augment(prompt: appSettings.effectiveSummaryPrompt, with: recording.calendarEvent)
```

And `systemPrompt: appSettings.effectiveActionItemsPrompt` (around line 995) with:

```swift
                    systemPrompt: CalendarEvent.augment(prompt: appSettings.effectiveActionItemsPrompt, with: recording.calendarEvent)
```

- [ ] **Step 5: Inject calendar context into the MLX path**

The MLX path (`runLocalQwenTasks`) calls `localAIPluginService.analyzeTranscriptStream(transcription, outputLanguage:)`, which produces summary + actions + tags in one combined pass with no separate system prompt. Prepend the agenda to the transcription it receives so the model has the context. Locate the `analyzeTranscriptStream(` call (around line 900) and change its first argument from `transcription` to a locally-prepared value. Immediately before the `withPluginStepAdapter` block, add:

```swift
        let contextualTranscription = CalendarEvent.augment(prompt: transcription, with: recording.calendarEvent)
```

Then in the `analyzeTranscriptStream(` call, pass `contextualTranscription` instead of `transcription`:

```swift
                let stream = await self.localAIPluginService.analyzeTranscriptStream(
                    contextualTranscription,
                    outputLanguage: self.appSettings.outputLanguage
                )
```

Note: `augment` prepends a "Meeting context from calendar:" block ahead of the transcript text, which is acceptable here since the MLX prompt treats its input as the source material to analyze.

- [ ] **Step 6: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 7: Run the full test suite**

Run: `swift test`
Expected: All tests pass (existing + the new CalendarMatcher/CalendarContext tests).

- [ ] **Step 8: Commit**

```bash
git add Sources/dBrief/Services/RecordingManager.swift
git commit -m "feat(calendar): look up event on record start and inject agenda into AI prompts"
```

---

## Task 9: PostRecordingSheet pre-fill

**Files:**
- Modify: `Sources/dBrief/UI/PostRecordingSheet.swift`

- [ ] **Step 1: Add a CalendarService instance and the prefill logic**

At the top of the `PostRecordingSheet` struct (after the `@State` declarations, around line 13), add:

```swift
    private let calendarService = CalendarService()
```

- [ ] **Step 2: Add the prefill helper method**

Add this method to `PostRecordingSheet` (near `applyFieldsToRecording`, around line 209):

```swift
    /// Pre-fills title and participants from a matched calendar event. Only overwrites the
    /// title if it is still the generic fallback, so a title the user already typed is preserved.
    private func applyCalendarEvent(_ event: CalendarEvent, to recording: Recording) {
        let current = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFallback = current.isEmpty
            || current == "meeting"
            || current == fallbackMeetingTitle(recording: recording)
        if isFallback, !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            meetingTitle = event.title
        }
        if participantsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !event.participantsText.isEmpty {
            participantsText = event.participantsText
        }
    }
```

- [ ] **Step 3: Wire it into onAppear**

In the existing `.onAppear` block (lines 167–178), after the `meetingTitle` assignment logic but still inside the closure, add a calendar pre-fill pass. Replace the trailing `}` closing the `if let recording` / `else` with the following so the calendar logic runs after the title is seeded:

```swift
            if let recording = appState.currentRecording {
                if let event = recording.calendarEvent {
                    applyCalendarEvent(event, to: recording)
                } else if appSettings.calendarIntegrationEnabled {
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
            }
```

Place this block immediately after the existing `if let recording = appState.currentRecording { ... } else { meetingTitle = "meeting" }` block, not replacing it.

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/UI/PostRecordingSheet.swift
git commit -m "feat(calendar): pre-fill title and participants from matched event"
```

---

## Task 10: Settings — Calendar permission row + integration toggle

**Files:**
- Modify: `Sources/dBrief/UI/SettingsPermissionsTab.swift`
- Modify: `Sources/dBrief/UI/SettingsGeneralTab.swift`

- [ ] **Step 1: Add EventKit import and calendar status state to the permissions tab**

At the top of `SettingsPermissionsTab.swift`, add `import EventKit` with the other imports. Add to the `@State` block (after `speechStatus`, line 10):

```swift
    @State private var calendarStatus: EKAuthorizationStatus = .notDetermined
```

- [ ] **Step 2: Add the Calendar permission row**

In the "Permissions Check" `Section`, after the Speech `PermissionRow` (line 37), add:

```swift
                PermissionRow(
                    title: "Calendar",
                    statusText: calendarStatusText,
                    statusStyle: calendarStatusStyle,
                    actionTitle: calendarActionTitle,
                    action: requestCalendar
                )
```

- [ ] **Step 3: Add a Calendar button to the "Manage Access" section**

After the Speech button (line 54), inside the same `HStack`:

```swift
                        Button("Calendar") {
                            openSystemSettingsPane("Privacy_Calendars")
                        }
                        .buttonStyle(.bordered)
```

- [ ] **Step 4: Add the status computed properties and request function**

Add alongside the speech equivalents (after `speechActionTitle`, around line 124):

```swift
    private var calendarStatusText: String {
        switch calendarStatus {
        case .fullAccess: "Granted"
        case .writeOnly: "Write-only"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not determined"
        @unknown default: "Unknown"
        }
    }

    private var calendarStatusStyle: Color {
        calendarStatus == .fullAccess ? .green : .orange
    }

    private var calendarActionTitle: String {
        calendarStatus == .fullAccess ? "Granted" : "Request"
    }

    private func requestCalendar() {
        guard calendarStatus != .fullAccess else { return }
        Task.detached {
            let store = EKEventStore()
            _ = try? await store.requestFullAccessToEvents()
            await MainActor.run {
                refreshStatuses()
            }
        }
    }
```

- [ ] **Step 5: Refresh calendar status in refreshStatuses()**

In `refreshStatuses()` (line 127), add:

```swift
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
```

- [ ] **Step 6: Add the integration toggle to SettingsGeneralTab**

In `SettingsGeneralTab.swift`, after the "Call Detection" `Section` (closes at line 64), add a new section:

```swift
            Section("Calendar") {
                Toggle("Pre-fill meeting info from Calendar", isOn: $settings.calendarIntegrationEnabled)
                    .disabled(EKEventStore.authorizationStatus(for: .event) != .fullAccess)

                if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
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

Add `import EventKit` at the top of `SettingsGeneralTab.swift`.

- [ ] **Step 7: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 8: Commit**

```bash
git add Sources/dBrief/UI/SettingsPermissionsTab.swift Sources/dBrief/UI/SettingsGeneralTab.swift
git commit -m "feat(calendar): add Calendar permission row and integration toggle"
```

---

## Task 11: Full verification

- [ ] **Step 1: Clean build**

Run: `swift build`
Expected: Build succeeds with no warnings related to the new code.

- [ ] **Step 2: Full test suite**

Run: `swift test`
Expected: All tests pass, including `CalendarMatcherTests` (5) and `CalendarContextTests` (4).

- [ ] **Step 3: App bundle build (validates Info.plist)**

Run: `make app`
Expected: Bundle assembles successfully with the new `NSCalendarsFullAccessUsageDescription` present.

- [ ] **Step 4: Manual smoke test (requires a real calendar event)**

1. Launch the app (`make run`).
2. In Settings → Permissions, grant Calendar access.
3. Create a calendar event in macOS Calendar spanning the current time.
4. Start a recording, stop it.
5. Confirm PostRecordingSheet pre-fills the meeting title (and participants, if attendees were on the event).
6. Confirm the toggle in Settings → General reflects/controls the behavior.

- [ ] **Step 5: Update CLAUDE.md (optional, if architecture docs warrant it)**

Consider adding a short "Calendar Integration" entry under "Other Services" in `CLAUDE.md` describing `CalendarService` + `CalendarMatcher`. Commit separately if done.

---

## Self-Review Notes

- **Spec coverage:** CalendarEvent (Task 1), CalendarService matching (Tasks 2+4), Recording.calendarEvent (Task 6), AppSettings toggle (Task 7), record-start lookup + sheet fallback (Tasks 8–9), title/participants/agenda fields (Tasks 8–9), permission row + toggle (Task 10), Info.plist key (Task 5). All spec sections covered.
- **MLX nuance:** The spec's "prepend to summary + action-item prompts" maps cleanly to the Apple Intelligence and remote paths (which take a `systemPrompt`). The MLX path runs one combined inference without a separate system prompt, so Task 8 Step 5 prepends the context to the transcription instead — documented inline.
- **Type consistency:** `CalendarEvent.augment(prompt:with:)`, `CalendarMatcher.selectBestMatch(from:at:)`, `CalendarService.findCurrentEvent(at:)`, and `CalendarEvent.participantsText` are referenced consistently across all tasks.
- **No persistence:** `Recording.calendarEvent` is intentionally session-only, matching the spec's out-of-scope list.
