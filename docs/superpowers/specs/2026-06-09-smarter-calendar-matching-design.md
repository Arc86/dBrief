# Smarter Calendar Matching — Design

**Date:** 2026-06-09
**Status:** Approved (pending spec review)

## Problem

The calendar integration pre-fills the post-recording sheet (title, participants → diarization speaker names, agenda → AI prompt context) with a single matched event. When a recording overlaps multiple calendar events, the wrong one is frequently chosen.

Observed failure: a long personal "time block" overlapping a short real meeting was selected instead of the meeting. The matcher's tiebreak literally prefers the **longest** active event (`CalendarMatcher.selectBestMatch`, `lhs.duration < rhs.duration`), so an all-day-ish block beats the 30-minute meeting it overlaps.

Root cause: matching runs **once at recording start** against the start *instant* only. The recording's duration — which the user intuitively used to know the match was wrong ("the recording duration and meeting times don't support this") — never enters the decision.

## Goal

1. **Smarter automatic pick** — choose the event whose window best fits the actual recording span, not the longest one.
2. **Manual override** — let the user correct the pick from the overlapping candidates in the post-recording sheet.

## Approach (chosen)

Re-rank candidates by the **recording span** at finalization, where `[start, start+duration]` is known. Score events by tightness-of-fit (intersection-over-union) with penalties for all-day blocks and a bonus for events with attendees. Store the full ranked candidate list on the recording so the sheet can show a best-first override picker.

Rejected alternatives:
- **Fix the start-time tiebreak only** — simpler, but still can't use recording duration; weaker guess.
- **Pure manual picker** — most clicks, never gets smarter.

## Design

### 1. Data model

- **`CalendarEvent`** (`Models/CalendarEvent.swift`):
  - Add `let isAllDay: Bool`.
  - Conform to `Identifiable` with a computed `id` of `"\(title)|\(startDate.timeIntervalSince1970)|\(endDate.timeIntervalSince1970)"` so it can tag a SwiftUI picker.
- **`Recording`** (`Models/Recording.swift`):
  - Add `var calendarCandidates: [CalendarEvent] = []` alongside the existing `var calendarEvent: CalendarEvent?`.

### 2. Heuristic — `CalendarMatcher`

Replace "pick longest active event" with span-aware scoring. For recording span `[rs, re]` and event `[es, ee]`:

```
overlap   = max(0, min(re, ee) − max(rs, es))
recLen    = re − rs
evLen     = ee − es
IoU       = overlap / (recLen + evLen − overlap)        // 0 if union == 0

score     = IoU
          + (es ≤ rs && rs ≤ ee ? 0.10 : 0)             // contains-start bias
          + (event.attendees.isEmpty ? 0 : 0.15)         // real meetings have invitees
if event.isAllDay { score *= 0.10 }                      // sink personal/all-day blocks
```

**Candidate qualification:** an event qualifies if `overlap > 0` **or** its start is within `±fallbackWindow` (15 min) of `rs` — preserving the existing "starting soon" fallback for recordings begun just before a meeting.

**API:**
- `static func rankedMatches(from candidates: [CalendarEvent], recordingStart: Date, recordingEnd: Date) -> [CalendarEvent]` — qualifying candidates sorted by score descending (ties broken by larger overlap, then by `id` for determinism).
- `static func selectBestMatch(from candidates: [CalendarEvent], recordingStart: Date, recordingEnd: Date) -> CalendarEvent?` — first of `rankedMatches`, or nil.
- The old instant-based `selectBestMatch(from:at:)` is **removed**; both calendar services move to the span API.

**Worked example (the reported case):** recording 10:00–10:35 (35 min).
- Real meeting 10:00–10:30, has attendees: overlap 30, IoU = 30/35 ≈ 0.857, +0.10 (contains start) +0.15 (attendees) ≈ **1.11**.
- Personal block 09:00–17:00, no attendees, all-day: overlap 35, IoU = 35/28800 ≈ 0.001, ×0.10 ≈ **~0**.
→ real meeting wins decisively.

### 3. Service layer

`CalendarService` and `OutlookCalendarService` each replace `findCurrentEvent(at:)` with:

```
func findCandidates(recordingStart: Date, recordingEnd: Date) async -> [CalendarEvent]
```

Still queries the ±2h window (around `recordingStart`), maps to `CalendarEvent` (now incl. `isAllDay`), and returns `CalendarMatcher.rankedMatches(...)`. Outlook adds `isAllDay` to the Graph `$select` and `GraphEvent`.

### 4. Flow change

Move the lookup from `startRecording` to `stopRecording` (`Services/RecordingManager.swift`), after `recording.duration` is probed:

```
let span = (recording.date, recording.date.addingTimeInterval(recording.duration))
Task { [weak recording] in
    let ranked = await <service>.findCandidates(recordingStart: span.0, recordingEnd: span.1)
    await MainActor.run {
        guard let recording else { return }
        recording.calendarCandidates = ranked
        recording.calendarEvent = ranked.first
    }
}
```

Because `Recording` is `@Observable`, the post-recording sheet updates reactively when the (possibly network-latency Outlook) fetch returns, so the sheet still appears instantly. The start-time fetch in `startRecording` and the redundant fallback fetch in `PostRecordingSheet.onAppear` are both **removed**.

### 5. Manual override UI — `PostRecordingSheet`

When `recording.calendarCandidates` is non-empty (≥1), render a compact meeting picker (a `Menu`/`Picker`) above the participants field:
- Selection bound to `recording.calendarEvent`.
- Options listed best-first, each showing title + `start–end` time.
- A "None" option clears calendar context (`calendarEvent = nil`).
- On change, update `recording.calendarEvent` and re-apply title/participant prefill via the existing `applyCalendarEvent` guard — which only overwrites fields the user hasn't edited.

### 6. Tests

New `Tests/dBriefTests/CalendarMatcherTests.swift` (swift-testing):
- Personal-block overlap (long, no attendees, all-day) loses to short meeting with attendees.
- All-day penalty applied.
- Attendee tiebreak between otherwise-equal events.
- Contains-start bias resolves back-to-back overrun toward the event active at recording start.
- Tight-fit (IoU) ranking orders candidates correctly.
- ±15 min "starting soon" fallback still matches when nothing overlaps.
- Empty candidates → nil.

## Out of scope

- Re-querying the calendar if events change between record and finalize (recordings are minutes long; negligible).
- Availability/show-as (busy/free/tentative) signal — `isAllDay` + attendees + IoU cover the reported case; can revisit if needed.
- Any change to how the matched event feeds AI prompts or diarization (unchanged).
