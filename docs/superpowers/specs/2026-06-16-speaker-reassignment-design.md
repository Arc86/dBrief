# Speaker Reassignment via Known-Name Picker

**Date:** 2026-06-16
**Status:** Approved (design); revised after code reconnaissance
**Branch:** `speaker-reassign`

## Problem

Clicking a speaker badge in the transcript opens a **free-text** rename field. But the
attendees are usually already known — from `recording.participants` (entered post-recording,
seeded from calendar) and from speakers already named in this transcript. Typing a name by
hand is slower and invites typos/inconsistency ("Alice" vs "alice" vs "Alise").

Separately, diarization sometimes **mis-splits or mis-attributes** speech: one real person
shows up as two speakers, or a run of speech is assigned to the wrong speaker. There is no
way to fix this today.

## Goal

Replace free-text rename with a **known-name picker** that also supports **reassignment**:

- Pick a speaker from a list of known people (existing transcript speakers + participants +
  calendar attendees), or add a new name inline.
- When the picked person differs from the current one, choose the **scope**: just this turn
  (the run of segments on screen), or every segment currently attributed to this speaker.
- Renaming a whole speaker becomes the special case "pick/add a name + scope = All", so the
  picker **subsumes** today's free-text rename — there is no separate rename UI left.

## Non-Goals

- No within-segment (word-level) speaker splitting. Reassignment is at `RichSegment`
  granularity; per-word `speaker` is not edited.
- No new diarization run (that already exists as "Re-run diarization").
- No persistence-model change. Reassignment only rewrites existing fields in the
  `.richtranscript.json` sidecar.
- No change to how `participants` are captured or to calendar matching.

## Key Constraints (from the codebase)

- **Single live entry point.** `TranscriptSegmentRow` and `SpeakerPillView` exist but have
  **zero instantiations** — dead code, left untouched. The finished-recording transcript in
  `TranscriptWindowView` renders **turn-based** rows (`transcriptRow(_ turn: SpeakerTurn)`),
  and the only rename UI is the `speakerLabel(id:isMe:)` SwiftUI `Menu` → "Rename…" → a sheet
  driven by `renamingSpeakerId` / `speakerRenameText` / `commitSpeakerRename` /
  `renameSpeaker`. That is the one path to replace.
- **`SpeakerTurn`** (`Models/SpeakerTurn.swift`) is a merged run of consecutive same-speaker
  `RichSegment`s; it exposes `.segments: [RichSegment]` (each with `id: UUID`, `speakerId`) and
  `.speakerId`. So a turn already carries the exact segment IDs to reassign for "this turn".
- **Display resolves `speakerId` → `displayName`** via `RichTranscript.speakerLabels`
  everywhere (turn cards, markdown, People list). A label edit is *already* transcript-wide;
  true per-occurrence changes require rewriting `RichSegment.speakerId`.
- **Reconstruction on reopen:** a finished recording reopened later is rebuilt minimally —
  `Recording.participants` is **not** restored from disk; only the `.richtranscript.json`
  sidecar (`speakerLabels`) survives. Calendar attendees are session-only and already flow
  into `participants` during processing. So the picker's reliable, persisted name source is
  the existing `speakerLabels`, augmented by `participants` / `calendarCandidates` when
  present in-session.
- **Pure-helper + TDD convention:** logic that can be pure (e.g. `MicReconfigurePlanner`,
  `CalendarMatcher`, `SpeakerMerge`) lives in a pure, unit-tested type. Reassignment logic
  follows suit.

## Data Model

**No schema change.** `RichSegment.speakerId: String?` and
`RichTranscript.speakerLabels: [SpeakerLabel{id, displayName}]` are sufficient.

- A **person** is identified by a `speakerId`. The display name is the matching
  `SpeakerLabel.displayName` (falls back to the raw id, e.g. "Speaker 2", when unlabeled).
- **Reassigning** segments = setting their `speakerId` to the target person's id.
- **Adding a new person** = minting a fresh `speakerId` + appending a `SpeakerLabel`. If the
  typed name case-insensitively matches an existing label, reuse that id (so "add" that
  collides becomes a merge, never a duplicate).

## Component 1 — `SpeakerReassignment` (pure, unit-tested)

New file `Sources/dBrief/Services/SpeakerReassignment.swift`. Pure types + static functions;
no I/O, no `@MainActor`. Unit-tested in `Tests/dBriefTests/SpeakerReassignmentTests.swift`.

The helper is **segment-ID-general** (works for one segment or a turn's set), so the same code
backs both the turn UI today and any future per-segment UI.

```swift
enum ReassignScope { case theseSegments, allOfSpeaker }

enum SpeakerChoice: Equatable {
    case existing(speakerId: String)
    case new(name: String)
}

struct SpeakerCandidate: Identifiable, Equatable {
    let id: String              // existing speakerId, or "name:"+normalized for a name-only entry
    let displayName: String
    let existingSpeakerId: String?  // non-nil when this name is already a transcript speaker
    let isCurrent: Bool             // matches the turn's current speaker
}

enum SpeakerReassignment {
    /// Ordered, de-duplicated candidate list for a turn whose current speaker is `currentSpeakerId`.
    /// Order: current speaker first, then other existing speakers (by first appearance in
    /// `segments`), then participant/attendee names not already an existing speaker. Dedup by
    /// normalized (trimmed, case-insensitive) name.
    static func candidates(
        in transcript: RichTranscript,
        currentSpeakerId: String?,
        participants: [String],
        calendarAttendees: [String]
    ) -> [SpeakerCandidate]

    /// Count of segments whose speakerId == speakerId (drives "All N" label + scope skip).
    static func segmentCount(in transcript: RichTranscript, speakerId: String?) -> Int

    /// Apply a choice to a set of segments. Returns a new transcript.
    /// `newId` is used only for `.new` names that don't collide with an existing label;
    /// inject it (`UUID().uuidString` in the app, a fixed string in tests) for determinism.
    static func apply(
        _ choice: SpeakerChoice,
        to transcript: RichTranscript,
        segmentIds: Set<UUID>,
        scope: ReassignScope,
        newId: String
    ) -> RichTranscript
}
```

**`apply` behavior**

1. **Resolve the target id:**
   - `.existing(id)` → `id`.
   - `.new(name)` → if `name` (normalized) matches an existing `SpeakerLabel.displayName`,
     use that label's id; otherwise append `SpeakerLabel(id: newId, displayName: name.trimmed)`
     and use `newId`. A blank/whitespace name returns the transcript unchanged.
2. **Determine the origin speaker** = the `speakerId` of the first segment in `segmentIds`
   (all of a turn's segments share one speakerId). If `origin == targetId`, return unchanged.
3. **Rewrite:**
   - `.theseSegments`: set `speakerId = targetId` on segments whose id ∈ `segmentIds`.
   - `.allOfSpeaker`: set `speakerId = targetId` on **every** segment whose `speakerId == origin`.
4. **Orphan cleanup:** drop any `SpeakerLabel` whose id no longer appears on any segment —
   **except** never drop the target's label. (Keeps the People list honest after a full merge.)
5. **`meSpeakerId` transfer:** if `origin == meSpeakerId` and no segment retains `origin`
   after the rewrite, move `meSpeakerId` to `targetId`.

**`candidates` behavior**

- Existing speakers = distinct `segment.speakerId`s (non-nil), each shown with its label
  displayName (or the raw id when unlabeled). `existingSpeakerId` set, `id` = that speakerId.
- Name-only candidates = each `participants`/`calendarAttendees` name whose normalized form is
  **not** already an existing speaker's display name. `existingSpeakerId == nil`,
  `id = "name:"+normalized`.
- `isCurrent == (existingSpeakerId == currentSpeakerId)`.
- Normalization = `trimmingCharacters(in: .whitespacesAndNewlines)` + `lowercased()`.

## Component 2 — `SpeakerAssignPicker` (shared UI)

New file `Sources/dBrief/UI/SpeakerAssignPicker.swift`. A popover body. Inputs:

```swift
struct SpeakerAssignPicker: View {
    let candidates: [SpeakerCandidate]
    let currentDisplayName: String
    let speakerSegmentCount: Int     // segments for the current speaker (for "All N" + skip)
    let turnSegmentCount: Int        // segments in the tapped turn (for "This turn" wording)
    let onChoose: (SpeakerChoice, ReassignScope) -> Void
    let onCancel: () -> Void
}
```

Two-step popover (local `@State` step machine):

1. **Pick step** — vertical list of `candidates`: color dot
   (`TranscriptDesignTokens.speakerColor(for: candidate.existingSpeakerId)`), name, checkmark
   on `isCurrent`. A divider, then an "Add someone…" row that reveals an inline `TextField`
   (`.roundedBorder`, submit = confirm). Selecting `isCurrent` just calls `onCancel` (no-op).
2. **Scope step** — entered only when the chosen person differs from current **and**
   `speakerSegmentCount > turnSegmentCount` (i.e. the speaker has segments outside this turn).
   Two buttons: **[This turn]** (or "[This segment]" when `turnSegmentCount == 1`) →
   `onChoose(choice, .theseSegments)`, and **[All N from "<current>"]** →
   `onChoose(choice, .allOfSpeaker)`. Otherwise skip the step and call
   `onChoose(choice, .allOfSpeaker)` immediately (the turn already is the whole speaker).

Layout mirrors the approved mock:

```
┌─ Assign speaker ─────┐
 ● Alice        ✓
 ● Bob
 ● Speaker 3
 ─────────────────────
 ＋ Add someone…
└──────────────────────┘
   then: [This turn] [All]
```

Styling matches existing transcript popovers (compact, small control sizes, `.padding(12)`).

## Component 3 — Wiring `TranscriptWindowView`

- Add `@State private var assigningTurn: SpeakerTurn?` (replaces `renamingSpeakerId` /
  `speakerRenameText`). Remove the old rename sheet (the `.sheet`/popover bound via the
  `IdentifiedString` adapter at ~L194), `commitSpeakerRename`, and `renameSpeaker`.
- Change `speakerLabel(id:isMe:)` to `speakerLabel(turn:isMe:)` (callsite at L419 passes the
  turn; `id` derives from `turn.speakerId`). Its `Menu`:
  - "Reassign / rename…" → `assigningTurn = turn` (opens the picker popover anchored on the
    label). "This is me" / "Clear "This is me"" unchanged (`setMeSpeaker`).
- Attach `.popover(item: $assigningTurn)` (make a small `Identifiable` wrapper or use the
  existing `IdentifiedString` pattern keyed by turn id) presenting `SpeakerAssignPicker` with:
  - `candidates = SpeakerReassignment.candidates(in: transcript, currentSpeakerId: turn.speakerId, participants: recording.participants, calendarAttendees: attendeeNames)`
  - `attendeeNames` = display names from `recording.calendarCandidates` (flattened attendees;
    empty after reopen — acceptable).
  - `currentDisplayName = displayName(for: turn.speakerId ?? "")`
  - `speakerSegmentCount = SpeakerReassignment.segmentCount(in: transcript, speakerId: turn.speakerId)`
  - `turnSegmentCount = turn.segments.count`
  - `onChoose = { choice, scope in assignSpeaker(turn: turn, choice: choice, scope: scope) }`
  - `onCancel = { assigningTurn = nil }`
- New `assignSpeaker(turn:choice:scope:)`:
  ```swift
  private func assignSpeaker(turn: SpeakerTurn, choice: SpeakerChoice, scope: ReassignScope) {
      guard var transcript = richTranscript else { return }
      let ids = Set(turn.segments.map(\.id))
      transcript = SpeakerReassignment.apply(choice, to: transcript,
                                             segmentIds: ids, scope: scope,
                                             newId: UUID().uuidString)
      richTranscript = transcript
      saveTranscript(transcript)
      recomputeSearch()
      assigningTurn = nil
  }
  ```
  (`saveTranscript(_:)` at L950 and `recomputeSearch()` at L872 already exist.)

## Data Flow

```
click speaker badge (turn)
        ↓
Menu → "Reassign / rename…"  → assigningTurn = turn
        ↓  .popover(item:)
SpeakerAssignPicker  (candidates from SpeakerReassignment.candidates)
        ↓  onChoose(choice, scope)
TranscriptWindowView.assignSpeaker(turn, choice, scope)
        ↓
SpeakerReassignment.apply(...)  → new RichTranscript
        ↓
richTranscript = updated → saveTranscript(updated) → recomputeSearch()
        ↓
TranscriptStore writes .richtranscript.json   (turn cards/markdown/People re-derive from labels)
```

## Edge Cases

- **No-op pick** (chose the current speaker): close picker, no write.
- **Whole-speaker turn** (`speakerSegmentCount == turnSegmentCount`): skip the scope step;
  apply as `allOfSpeaker`.
- **Full merge empties a speaker:** orphaned `SpeakerLabel` removed; `meSpeakerId` transferred
  if it was the emptied speaker.
- **Add-name collides with an existing label** (case-insensitive): reuse that speaker's id
  (becomes a merge), never a duplicate label. Blank name = no-op.
- **Unlabeled raw speakers** ("Speaker 2") are valid pick targets and valid origins.
- **Reopened recording with no participants:** candidate list = existing speakers only; the
  feature still works. "Add someone…" always available.
- **Live transcript:** reassignment is offered only on the finished-recording transcript (the
  live turn rows have no speaker menu today), unchanged.

## Testing

`Tests/dBriefTests/SpeakerReassignmentTests.swift` (swift-testing), all against the pure helper:

- `apply(.existing, theseSegments)` changes only the given segment ids.
- `apply(.existing, allOfSpeaker)` rewrites every segment of the origin speaker.
- No-op when target == origin.
- Orphan label removed after a full merge; target label retained.
- `meSpeakerId` transfers when its speaker is fully merged away; untouched otherwise.
- `apply(.new(name), …)` mints a label with the injected `newId`; collision (case-insensitive)
  reuses the existing id instead of duplicating; blank name is a no-op.
- `segmentCount` correctness.
- `candidates`: current first, dedup by normalized name, name-only excluded when already an
  existing speaker, `isCurrent` flagged, `existingSpeakerId` populated correctly.

UI is exercised manually (build + run): pick existing, add new, both scopes, whole-speaker
turn (scope skipped), no-op pick.

## Docs

Update `CLAUDE.md` (Speaker Diarization / Rich Transcript Viewer sections) and `site/docs/`
(+ NAV in `site/docs.js`) to describe the picker + turn/all-speaker reassignment, replacing the
"post-hoc rename popover" description.
