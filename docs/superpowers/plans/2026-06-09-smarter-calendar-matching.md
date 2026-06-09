# Smarter Calendar Matching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Match the right calendar event to a recording by scoring how tightly each event's window fits the actual recording span, and let the user override the pick from the post-recording sheet.

**Architecture:** Move the calendar lookup from recording *start* to recording *stop* (where duration is known). Rank candidate events by intersection-over-union with the recording span, penalizing all-day blocks and rewarding events with attendees. Store the ranked candidates on the `Recording` so the post-recording sheet can render a best-first override picker.

**Tech Stack:** Swift 6.2, SwiftUI, swift-testing, EventKit, Microsoft Graph.

---

## File Structure

- `Sources/dBrief/Models/CalendarEvent.swift` — add `isAllDay`, conform to `Identifiable` (Task 1).
- `Sources/dBrief/Services/CalendarMatcher.swift` — span-aware scoring API (Task 2).
- `Tests/dBriefTests/CalendarMatcherTests.swift` — new test suite (Task 2).
- `Sources/dBrief/Models/Recording.swift` — add `calendarCandidates` (Task 3).
- `Sources/dBrief/Services/CalendarService.swift` — `findCandidates`, populate `isAllDay` (Tasks 1, 4, 5).
- `Sources/dBrief/Services/OutlookCalendarService.swift` — `findCandidates`, `isAllDay` in Graph (Tasks 1, 4, 5).
- `Sources/dBrief/Services/RecordingManager.swift` — move lookup to `stopRecording` (Task 4).
- `Sources/dBrief/UI/PostRecordingSheet.swift` — override picker, remove fallback fetch (Task 5).

Each task leaves the package compiling (`swift build`) and tests passing (`swift test`).

---

## Task 1: Extend `CalendarEvent` with `isAllDay` and `Identifiable`

**Files:**
- Modify: `Sources/dBrief/Models/CalendarEvent.swift`
- Modify: `Sources/dBrief/Services/CalendarService.swift:47-59` (mapper)
- Modify: `Sources/dBrief/Services/OutlookCalendarService.swift:30,53-59,75-87` (mapper + Graph type + `$select`)

- [ ] **Step 1: Add `isAllDay` and `Identifiable` to `CalendarEvent`**

Replace the struct declaration and stored properties in `Sources/dBrief/Models/CalendarEvent.swift` (lines 5-11) with:

```swift
struct CalendarEvent: Sendable, Equatable, Identifiable {
    let title: String
    let attendees: [String]   // display names only
    let body: String          // notes / description / agenda
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool

    /// Stable identity for SwiftUI selection. Calendar sources don't expose a uid here,
    /// so derive it from the fields that distinguish overlapping events.
    var id: String {
        "\(title)|\(startDate.timeIntervalSince1970)|\(endDate.timeIntervalSince1970)"
    }
```

Leave `participantsText` and `augment(prompt:with:)` unchanged below.

- [ ] **Step 2: Populate `isAllDay` in the EventKit mapper**

In `Sources/dBrief/Services/CalendarService.swift`, update `makeCalendarEvent(from:)` (the `return CalendarEvent(...)` at lines 52-58) to:

```swift
        return CalendarEvent(
            title: ekEvent.title ?? "",
            attendees: names,
            body: ekEvent.notes ?? "",
            startDate: ekEvent.startDate ?? Date(),
            endDate: ekEvent.endDate ?? Date(),
            isAllDay: ekEvent.isAllDay
        )
```

- [ ] **Step 3: Add `isAllDay` to the Graph request, type, and mapper**

In `Sources/dBrief/Services/OutlookCalendarService.swift`:

Update the `$select` query item (line 30) to include `isAllDay`:

```swift
            URLQueryItem(name: "$select",       value: "subject,bodyPreview,attendees,start,end,isAllDay"),
```

Add the field to `GraphEvent` (struct at lines 53-59):

```swift
    private struct GraphEvent: Decodable {
        let subject: String?
        let bodyPreview: String?
        let attendees: [GraphAttendee]?
        let start: GraphDateTimeZone?
        let end: GraphDateTimeZone?
        let isAllDay: Bool?
    }
```

Update the mapper `return CalendarEvent(...)` (lines 80-86) to:

```swift
        return CalendarEvent(
            title: event.subject ?? "",
            attendees: names,
            body: event.bodyPreview ?? "",
            startDate: parseGraphDate(event.start?.dateTime),
            endDate: parseGraphDate(event.end?.dateTime),
            isAllDay: event.isAllDay ?? false
        )
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: Build complete with no errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Models/CalendarEvent.swift Sources/dBrief/Services/CalendarService.swift Sources/dBrief/Services/OutlookCalendarService.swift
git commit -m "feat(calendar): add isAllDay and Identifiable to CalendarEvent

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Span-aware scoring in `CalendarMatcher` (TDD)

**Files:**
- Create: `Tests/dBriefTests/CalendarMatcherTests.swift`
- Modify: `Sources/dBrief/Services/CalendarMatcher.swift`

The new API is added alongside the existing instant-based `selectBestMatch(from:at:)`, which stays until Task 5 (its callers are migrated there).

- [ ] **Step 1: Write the failing tests**

Create `Tests/dBriefTests/CalendarMatcherTests.swift`:

```swift
import Testing
import Foundation
@testable import dBrief

struct CalendarMatcherTests {
    /// Builds an event with fixed clock times on an arbitrary fixed day.
    private func event(
        _ title: String,
        _ start: TimeInterval,
        _ end: TimeInterval,
        attendees: [String] = [],
        allDay: Bool = false
    ) -> CalendarEvent {
        let base = Date(timeIntervalSinceReferenceDate: 0)  // fixed, deterministic
        return CalendarEvent(
            title: title,
            attendees: attendees,
            body: "",
            startDate: base.addingTimeInterval(start),
            endDate: base.addingTimeInterval(end),
            isAllDay: allDay
        )
    }

    private let base = Date(timeIntervalSinceReferenceDate: 0)
    private func t(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    private let hour: TimeInterval = 3600
    private let minute: TimeInterval = 60

    @Test("Personal time block loses to the real meeting it overlaps")
    func personalBlockLoses() {
        // Recording 10:00–10:35.
        let rs = t(10 * hour)
        let re = t(10 * hour + 35 * minute)
        let meeting = event("Standup", 10 * hour, 10.5 * hour, attendees: ["Alice", "Bob"])
        let block = event("Focus time", 9 * hour, 17 * hour, allDay: true)
        let best = CalendarMatcher.selectBestMatch(
            from: [block, meeting], recordingStart: rs, recordingEnd: re
        )
        #expect(best == meeting)
    }

    @Test("All-day event is penalized below a same-overlap timed event")
    func allDayPenalized() {
        let rs = t(14 * hour)
        let re = t(14 * hour + 30 * minute)
        let timed = event("Review", 14 * hour, 14.5 * hour)
        let allDay = event("Holiday", 14 * hour, 14.5 * hour, allDay: true)
        let best = CalendarMatcher.selectBestMatch(
            from: [allDay, timed], recordingStart: rs, recordingEnd: re
        )
        #expect(best == timed)
    }

    @Test("Among identical windows, the one with attendees wins")
    func attendeeTiebreak() {
        let rs = t(9 * hour)
        let re = t(9.5 * hour)
        let withPeople = event("1:1", 9 * hour, 9.5 * hour, attendees: ["Carol"])
        let solo = event("Hold", 9 * hour, 9.5 * hour)
        let best = CalendarMatcher.selectBestMatch(
            from: [solo, withPeople], recordingStart: rs, recordingEnd: re
        )
        #expect(best == withPeople)
    }

    @Test("Back-to-back overrun favors the meeting active at recording start")
    func containsStartBias() {
        // Recording 10:50–11:10 straddles A (10:00–11:00) and B (11:00–12:00).
        let rs = t(10 * hour + 50 * minute)
        let re = t(11 * hour + 10 * minute)
        let a = event("Meeting A", 10 * hour, 11 * hour, attendees: ["Alice"])
        let b = event("Meeting B", 11 * hour, 12 * hour, attendees: ["Bob"])
        let best = CalendarMatcher.selectBestMatch(
            from: [b, a], recordingStart: rs, recordingEnd: re
        )
        #expect(best == a)
    }

    @Test("Tighter-fitting event ranks ahead of a looser one")
    func tightFitRanking() {
        let rs = t(13 * hour)
        let re = t(13.5 * hour)
        let tight = event("Sync", 13 * hour, 13.5 * hour, attendees: ["A"])
        let loose = event("Workshop", 11 * hour, 15 * hour, attendees: ["A"])
        let ranked = CalendarMatcher.rankedMatches(
            from: [loose, tight], recordingStart: rs, recordingEnd: re
        )
        #expect(ranked.first == tight)
        #expect(ranked.count == 2)
    }

    @Test("Starting-soon fallback matches an event just after recording start")
    func startingSoonFallback() {
        // 2-second recording started 10 min before the meeting; no overlap.
        let rs = t(9 * hour + 50 * minute)
        let re = t(9 * hour + 50 * minute + 2)
        let soon = event("Kickoff", 10 * hour, 11 * hour, attendees: ["A"])
        let best = CalendarMatcher.selectBestMatch(
            from: [soon], recordingStart: rs, recordingEnd: re
        )
        #expect(best == soon)
    }

    @Test("No qualifying events returns nil")
    func noMatch() {
        let rs = t(10 * hour)
        let re = t(10.5 * hour)
        let far = event("Lunch", 13 * hour, 14 * hour)
        let best = CalendarMatcher.selectBestMatch(
            from: [far], recordingStart: rs, recordingEnd: re
        )
        #expect(best == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter CalendarMatcherTests`
Expected: FAIL — `selectBestMatch(from:recordingStart:recordingEnd:)` and `rankedMatches(...)` do not exist.

- [ ] **Step 3: Implement the span-aware API**

Replace the entire body of `Sources/dBrief/Services/CalendarMatcher.swift` with:

```swift
import Foundation

/// Pure best-match selection for calendar events. No EventKit dependency, fully testable.
enum CalendarMatcher {
    /// Window for the "starting soon" fallback when an event does not overlap the recording.
    static let fallbackWindow: TimeInterval = 15 * 60  // 15 minutes

    /// Candidate events that plausibly belong to the recording span `[recordingStart, recordingEnd]`,
    /// ranked best-first. An event qualifies if it overlaps the recording or starts within
    /// ±`fallbackWindow` of the recording start. Scoring favors a tight fit (intersection-over-union),
    /// an event that was active at recording start, and events with attendees; all-day blocks are sunk.
    static func rankedMatches(
        from candidates: [CalendarEvent],
        recordingStart rs: Date,
        recordingEnd re: Date
    ) -> [CalendarEvent] {
        let recLen = max(0, re.timeIntervalSince(rs))

        let scored: [(event: CalendarEvent, score: Double, overlap: Double)] = candidates.compactMap { event in
            let es = event.startDate
            let ee = event.endDate
            let overlap = max(0, min(re, ee).timeIntervalSince(max(rs, es)))
            let qualifies = overlap > 0 || abs(es.timeIntervalSince(rs)) <= fallbackWindow
            guard qualifies else { return nil }

            let evLen = max(0, ee.timeIntervalSince(es))
            let union = recLen + evLen - overlap
            var score = union > 0 ? overlap / union : 0          // intersection-over-union
            if es <= rs && rs <= ee { score += 0.10 }            // active when recording began
            if !event.attendees.isEmpty { score += 0.15 }        // real meetings have invitees
            if event.isAllDay { score *= 0.10 }                  // sink personal/all-day blocks
            return (event, score, overlap)
        }

        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.overlap != rhs.overlap { return lhs.overlap > rhs.overlap }
            return lhs.event.id < rhs.event.id
        }.map(\.event)
    }

    /// The single best event for the recording span, or nil if none qualifies.
    static func selectBestMatch(
        from candidates: [CalendarEvent],
        recordingStart: Date,
        recordingEnd: Date
    ) -> CalendarEvent? {
        rankedMatches(from: candidates, recordingStart: recordingStart, recordingEnd: recordingEnd).first
    }

    /// Legacy instant-based match. Still used by the calendar services until they migrate to
    /// `findCandidates`. Removed in the same change that migrates them.
    static func selectBestMatch(from candidates: [CalendarEvent], at date: Date) -> CalendarEvent? {
        let active = candidates.filter { $0.startDate <= date && date <= $0.endDate }
        if !active.isEmpty {
            return active.max { lhs, rhs in
                lhs.endDate.timeIntervalSince(lhs.startDate) < rhs.endDate.timeIntervalSince(rhs.startDate)
            }
        }
        return candidates
            .filter { abs($0.startDate.timeIntervalSince(date)) <= fallbackWindow }
            .min { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter CalendarMatcherTests`
Expected: PASS — all 7 tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Services/CalendarMatcher.swift Tests/dBriefTests/CalendarMatcherTests.swift
git commit -m "feat(calendar): span-aware ranked matching with IoU scoring

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Store ranked candidates on `Recording`

**Files:**
- Modify: `Sources/dBrief/Models/Recording.swift:24`

- [ ] **Step 1: Add the `calendarCandidates` property**

In `Sources/dBrief/Models/Recording.swift`, immediately after the `calendarEvent` declaration (line 24), add:

```swift
    /// All calendar events that plausibly match this recording, ranked best-first by
    /// `CalendarMatcher`. Drives the override picker in the post-recording sheet.
    /// Not persisted to disk — session-only.
    var calendarCandidates: [CalendarEvent] = []
```

The default value means the `init` need not change.

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build complete with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/Models/Recording.swift
git commit -m "feat(calendar): store ranked calendar candidates on Recording

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `findCandidates` services + move lookup to `stopRecording`

**Files:**
- Modify: `Sources/dBrief/Services/CalendarService.swift` (add `findCandidates`)
- Modify: `Sources/dBrief/Services/OutlookCalendarService.swift` (add `findCandidates` + `fetchCandidates`)
- Modify: `Sources/dBrief/Services/RecordingManager.swift:99-113` (remove start-time fetch) and `:147-156` (add stop-time fetch)

`findCurrentEvent` stays on both services for now — the post-recording sheet's fallback still calls it; both are removed in Task 5.

- [ ] **Step 1: Add `findCandidates` to `CalendarService`**

In `Sources/dBrief/Services/CalendarService.swift`, add this method right after `findCurrentEvent(at:)` (after line 44):

```swift
    /// Ranked calendar events plausibly matching the recording span, best-first. Empty if access denied.
    func findCandidates(recordingStart: Date, recordingEnd: Date) async -> [CalendarEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return []
        }

        let predicate = store.predicateForEvents(
            withStart: recordingStart.addingTimeInterval(-searchWindow),
            end: recordingEnd.addingTimeInterval(searchWindow),
            calendars: nil
        )

        let candidates = store.events(matching: predicate).map { Self.makeCalendarEvent(from: $0) }
        return CalendarMatcher.rankedMatches(
            from: candidates, recordingStart: recordingStart, recordingEnd: recordingEnd
        )
    }
```

- [ ] **Step 2: Add `findCandidates` + `fetchCandidates` to `OutlookCalendarService`**

In `Sources/dBrief/Services/OutlookCalendarService.swift`, add right after `findCurrentEvent(at:)` (after line 21):

```swift
    /// Ranked calendar events plausibly matching the recording span, best-first. Empty on failure.
    func findCandidates(recordingStart: Date, recordingEnd: Date) async -> [CalendarEvent] {
        do {
            let token = try await authService.getValidAccessToken()
            return try await fetchCandidates(
                recordingStart: recordingStart, recordingEnd: recordingEnd, token: token
            )
        } catch {
            Logger.calendar.error("Outlook calendar fetch failed: \(error.localizedDescription)")
            return []
        }
    }

    private func fetchCandidates(
        recordingStart: Date,
        recordingEnd: Date,
        token: String
    ) async throws -> [CalendarEvent] {
        var components = URLComponents(string: Self.calendarViewURL)!
        components.queryItems = [
            URLQueryItem(name: "startDateTime", value: graphDateString(recordingStart.addingTimeInterval(-searchWindow))),
            URLQueryItem(name: "endDateTime",   value: graphDateString(recordingEnd.addingTimeInterval(searchWindow))),
            URLQueryItem(name: "$select",       value: "subject,bodyPreview,attendees,start,end,isAllDay"),
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
        return CalendarMatcher.rankedMatches(
            from: candidates, recordingStart: recordingStart, recordingEnd: recordingEnd
        )
    }
```

- [ ] **Step 3: Remove the start-time fetch in `RecordingManager.startRecording`**

In `Sources/dBrief/Services/RecordingManager.swift`, delete the calendar switch block at lines 99-113:

```swift
        let started = recording.date
        switch appSettings.effectiveCalendarSource {
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

(Leave the surrounding `appState.currentRecording = recording` above and `try await audioCaptureManager.startRecording(...)` below intact.)

- [ ] **Step 4: Add the stop-time fetch in `RecordingManager.stopRecording`**

In the same file, inside the `if let recording = appState.currentRecording { ... }` block of `stopRecording()`, after the meeting-title default at lines 153-155 and before the block's closing brace (line 156), add:

```swift

            // Match calendar events now that the recording's true span is known. The lookup
            // runs detached so the sheet appears immediately; `recording` is @Observable, so
            // the picker populates reactively when the (possibly networked) fetch returns.
            let calendarStart = recording.date
            let calendarEnd = recording.date.addingTimeInterval(recording.duration)
            switch appSettings.effectiveCalendarSource {
            case .iCal:
                Task { [weak recording] in
                    let ranked = await calendarService.findCandidates(
                        recordingStart: calendarStart, recordingEnd: calendarEnd
                    )
                    await MainActor.run {
                        guard let recording else { return }
                        recording.calendarCandidates = ranked
                        recording.calendarEvent = ranked.first
                    }
                }
            case .outlook:
                Task { [weak recording] in
                    let ranked = await outlookCalendarService.findCandidates(
                        recordingStart: calendarStart, recordingEnd: calendarEnd
                    )
                    await MainActor.run {
                        guard let recording else { return }
                        recording.calendarCandidates = ranked
                        recording.calendarEvent = ranked.first
                    }
                }
            case .disabled:
                break
            }
```

- [ ] **Step 5: Build to verify it compiles**

Run: `swift build`
Expected: Build complete with no errors. (`findCurrentEvent` remains referenced only by `PostRecordingSheet`.)

- [ ] **Step 6: Commit**

```bash
git add Sources/dBrief/Services/CalendarService.swift Sources/dBrief/Services/OutlookCalendarService.swift Sources/dBrief/Services/RecordingManager.swift
git commit -m "feat(calendar): match candidates by recording span at finalization

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Override picker in `PostRecordingSheet` + remove legacy fetch paths

**Files:**
- Modify: `Sources/dBrief/UI/PostRecordingSheet.swift` (add picker, remove fallback fetch, add prefill helpers)
- Modify: `Sources/dBrief/Services/CalendarService.swift` (remove `findCurrentEvent`)
- Modify: `Sources/dBrief/Services/OutlookCalendarService.swift` (remove `findCurrentEvent` + `fetchEvents`)
- Modify: `Sources/dBrief/Services/CalendarMatcher.swift` (remove legacy `selectBestMatch(from:at:)`)

- [ ] **Step 1: Insert the meeting picker into the sheet body**

In `Sources/dBrief/UI/PostRecordingSheet.swift`, find the `Divider()` at line 56 and insert the picker immediately *before* it:

```swift
            if let recording = appState.currentRecording, !recording.calendarCandidates.isEmpty {
                LabeledContent("Meeting:") {
                    Picker("Meeting", selection: calendarSelection(recording)) {
                        Text("None").tag(String?.none)
                        ForEach(recording.calendarCandidates) { event in
                            Text(pickerLabel(event)).tag(Optional(event.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                Text("Pick the meeting this recording belongs to. Fills the title, participants, and AI context.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

```

- [ ] **Step 2: Replace the `onAppear` calendar fetch with reactive prefill**

In the same file, replace the second `if let recording = appState.currentRecording { ... }` block inside `.onAppear` — the one spanning lines 180-205 (which contains the iCal/outlook fallback `Task`s) — with:

```swift
            if let recording = appState.currentRecording, let event = recording.calendarEvent {
                applyCalendarEvent(event, to: recording)
            }
```

Then attach an `.onChange` right after the `.onAppear { ... }` closing brace (after line 206) so async-arriving matches still prefill:

```swift
        .onChange(of: appState.currentRecording?.calendarEvent?.id) { _, _ in
            guard let recording = appState.currentRecording,
                  let event = recording.calendarEvent else { return }
            applyCalendarEvent(event, to: recording)
        }
```

- [ ] **Step 3: Add the picker helper methods**

In the same file, add these methods alongside the existing `applyCalendarEvent(_:to:)` (after line 254, inside the struct):

```swift
    /// Two-way binding between the picker and `recording.calendarEvent`, keyed by event id.
    private func calendarSelection(_ recording: Recording) -> Binding<String?> {
        Binding(
            get: { recording.calendarEvent?.id },
            set: { newID in
                let event = recording.calendarCandidates.first { $0.id == newID }
                selectCalendarEvent(event, to: recording)
            }
        )
    }

    /// Explicit user pick: overwrite title and participants from the chosen event
    /// (distinct from the auto-fill guard in `applyCalendarEvent`). `nil` clears context
    /// without wiping fields the user may have typed.
    private func selectCalendarEvent(_ event: CalendarEvent?, to recording: Recording) {
        recording.calendarEvent = event
        guard let event else { return }
        if !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            meetingTitle = event.title
        }
        participantsText = event.participantsText
    }

    private func pickerLabel(_ event: CalendarEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(untitled)" : event.title
        return "\(title)  \(formatter.string(from: event.startDate))–\(formatter.string(from: event.endDate))"
    }
```

- [ ] **Step 4: Remove the now-unused `calendarService` property**

In the same file, delete the stored property at line 15:

```swift
    private let calendarService = CalendarService()
```

(The sheet no longer fetches calendar data itself; `RecordingManager` owns that.)

- [ ] **Step 5: Build to verify the sheet compiles**

Run: `swift build`
Expected: Build fails only with "value of type 'CalendarService' has no member 'findCurrentEvent'" IF any reference remains — there should be none in the sheet now. If the build is clean, proceed; the legacy service methods are still present and will be removed next.

Expected (clean): Build complete with no errors.

- [ ] **Step 6: Remove `findCurrentEvent` from `CalendarService`**

In `Sources/dBrief/Services/CalendarService.swift`, delete the entire `findCurrentEvent(at:)` method (lines 30-44):

```swift
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
```

- [ ] **Step 7: Remove `findCurrentEvent` + `fetchEvents` from `OutlookCalendarService`**

In `Sources/dBrief/Services/OutlookCalendarService.swift`, delete `findCurrentEvent(at:)` (lines 13-21) and the now-unused `fetchEvents(at:token:)` method (lines 25-45). Keep `fetchCandidates`, the JSON types, `makeCalendarEvent`, `parseGraphDate`, and `graphDateString`.

- [ ] **Step 8: Remove the legacy matcher overload**

In `Sources/dBrief/Services/CalendarMatcher.swift`, delete the legacy `selectBestMatch(from:at:)` method added with a "Legacy instant-based match" comment in Task 2. The span-based `selectBestMatch` and `rankedMatches` remain.

- [ ] **Step 9: Build and run the full test suite**

Run: `swift build && swift test`
Expected: Build complete; all tests pass (including `CalendarMatcherTests`). No "unused"/"no member" errors.

- [ ] **Step 10: Commit**

```bash
git add Sources/dBrief/UI/PostRecordingSheet.swift Sources/dBrief/Services/CalendarService.swift Sources/dBrief/Services/OutlookCalendarService.swift Sources/dBrief/Services/CalendarMatcher.swift
git commit -m "feat(calendar): meeting override picker; drop legacy instant match

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Final verification

- [ ] **Build the app bundle** — Run: `make app` — Expected: bundle assembles without errors.
- [ ] **Manual smoke (optional, requires Calendar access):** Record a short clip overlapping a long personal time block and a real meeting. Confirm the post-recording sheet selects the real meeting and the "Meeting:" picker lists both best-first, with "None" available.

---

## Notes for the implementer

- **Concurrency:** `CalendarService` and `OutlookCalendarService` are `actor`s; `findCandidates` is `async`. The `Task { [weak recording] in ... await MainActor.run { ... } }` pattern in `stopRecording` mirrors the existing start-time code that was removed — keep the `await MainActor.run` hop because `Recording` is `@MainActor`.
- **Why manual pick overwrites but auto-fill guards:** `applyCalendarEvent` (existing) only fills empty/fallback fields, so an async auto-match never clobbers what the user typed. `selectCalendarEvent` (new) is an explicit user action, so it overwrites title + participants from the chosen event. Selecting "None" clears `calendarEvent` only and leaves typed fields alone.
- **No persistence changes:** `calendarEvent`/`calendarCandidates` are session-only, consistent with the existing comment on `calendarEvent`.
