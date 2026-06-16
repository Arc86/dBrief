# Speaker Reassignment via Known-Name Picker

**Date:** 2026-06-16
**Status:** Approved (design)
**Branch:** `speaker-reassign`

## Problem

Clicking a speaker badge in the transcript opens a **free-text** rename field. But the
attendees are usually already known — from `recording.participants` (entered post-recording,
seeded from calendar) and from speakers already named in this transcript. Typing a name by
hand is slower and invites typos/inconsistency ("Alice" vs "alice" vs "Alise").

Separately, diarization sometimes **mis-splits or mis-attributes** speech: one real person
shows up as two speakers, or a single segment is assigned to the wrong speaker. There is no
way to fix this today.

## Goal

Replace free-text rename with a **known-name picker** that also supports **per-segment
reassignment**:

- Pick a speaker from a list of known people (existing transcript speakers + participants +
  calendar attendees), or add a new name inline.
- When the picked person differs from the current one, choose the **scope**: just this
  segment, or every segment currently attributed to this speaker.
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

- **Display resolves `speakerId` → `displayName`** via `RichTranscript.speakerLabels`
  everywhere (segment rows, turn cards, markdown). So a label edit is *already*
  transcript-wide; true per-segment changes require rewriting `RichSegment.speakerId`.
- **Reconstruction on reopen:** a finished recording reopened later is rebuilt minimally —
  `Recording.participants` is **not** restored from disk; only the `.richtranscript.json`
  sidecar (`speakerLabels`) survives. Calendar attendees are session-only and already flow
  into `participants` during processing. So the picker's reliable, persisted name source is
  the existing `speakerLabels`, augmented by `participants` / `calendarCandidates` when
  present in-session.
- **Three rename entry points exist today**, all funneling to free text:
  `TranscriptSegmentRow` popover (`.transcript` + `.segments` modes) and the
  `TranscriptWindowView` rename sheet (from the `SpeakerTurnCard` speaker menu). All three
  must move to the new picker.
- **Pure-helper + TDD convention:** logic that can be pure (e.g. `MicReconfigurePlanner`,
  `CalendarMatcher`, `SpeakerMerge`) lives in a pure, unit-tested type. Reassignment logic
  follows suit.

## Data Model

**No schema change.** `RichSegment.speakerId: String?` and
`RichTranscript.speakerLabels: [SpeakerLabel{id, displayName}]` are sufficient.

- A **person** is identified by a `speakerId`. The display name is the matching
  `SpeakerLabel.displayName` (falls back to the raw id, e.g. "Speaker 2", when unlabeled).
- **Reassigning** a segment = setting its `speakerId` to the target person's id.
- **Adding a new person** = minting a fresh `speakerId` + appending a `SpeakerLabel`. If the
  typed name case-insensitively matches an existing label, reuse that id (so "add" that
  collides becomes a merge, never a duplicate).

## Component 1 — `SpeakerReassignment` (pure, unit-tested)

New file `Sources/dBrief/Services/SpeakerReassignment.swift`. Pure `enum`/`struct` with
static functions; no I/O, no `@MainActor`. Unit-tested in
`Tests/dBriefTests/SpeakerReassignmentTests.swift`.

```swift
enum ReassignScope { case thisSegment, allOfSpeaker }

struct SpeakerCandidate: Identifiable, Equatable {
    var id: String          // speakerId; for a name-only candidate, a derived placeholder id
    var displayName: String
    var existingSpeakerId: String?  // non-nil when this name is already a transcript speaker
    var isCurrent: Bool             // matches the segment's current speaker
}

enum SpeakerReassignment {
    /// Ordered, de-duplicated candidate list for a given segment.
    /// Order: current speaker first, then other existing speakers (by first appearance),
    /// then participant/attendee names not yet tied to a speaker. Dedup by normalized name.
    static func candidates(
        in transcript: RichTranscript,
        forSegment segmentId: UUID,
        participants: [String],
        calendarAttendees: [String]
    ) -> [SpeakerCandidate]

    /// Reassign to an existing speakerId. Returns a new transcript.
    static func assign(
        _ transcript: RichTranscript,
        segmentId: UUID,
        toSpeakerId targetId: String,
        scope: ReassignScope
    ) -> RichTranscript

    /// Reassign to a new (or name-matched existing) person. `newId` is injected for
    /// deterministic tests. Returns the new transcript.
    static func assignNew(
        _ transcript: RichTranscript,
        segmentId: UUID,
        name: String,
        scope: ReassignScope,
        newId: String
    ) -> RichTranscript
}
```

**`assign` behavior**

1. Resolve the segment and its current `speakerId` (`origin`). If `origin == targetId`,
   return the transcript unchanged.
2. `thisSegment`: set that one segment's `speakerId = targetId`.
   `allOfSpeaker`: set `speakerId = targetId` on **every** segment whose `speakerId == origin`.
3. Ensure a `SpeakerLabel` exists for `targetId` (it should already).
4. **Orphan cleanup:** drop any `SpeakerLabel` whose id no longer appears on any segment —
   **except** never drop the target. (Keeps the People list honest after a full merge.)
5. **`meSpeakerId` transfer:** if `origin == meSpeakerId` and no segment retains `origin`
   after the change, move `meSpeakerId` to `targetId`.

**`assignNew` behavior**

- If `name` (normalized) matches an existing `SpeakerLabel.displayName`, delegate to `assign`
  with that label's id. Otherwise append `SpeakerLabel(id: newId, displayName: name.trimmed)`
  and apply the same scope rewrite + cleanup as `assign`.

**Candidate behavior**

- Existing speakers come from `speakerLabels` ∪ distinct `segment.speakerId`s (an unlabeled
  speaker still appears, displayed as its raw id).
- Name-only candidates: each participant/attendee name whose normalized form is **not**
  already an existing speaker's display name. Their `id` is a derived placeholder
  (e.g. `"name:"+normalized`); selecting one routes through `assignNew`.
- Normalization for dedup = trimmed, case-insensitive (reuse/extend an existing normalizer
  if present; otherwise local).

## Component 2 — `SpeakerAssignPicker` (shared UI)

New file `Sources/dBrief/UI/SpeakerAssignPicker.swift`. A popover body reused by every entry
point. Inputs: `candidates: [SpeakerCandidate]`, `currentSpeakerSegmentCount: Int`,
`currentDisplayName: String`, and a completion
`onChoose(_ choice: SpeakerChoice, _ scope: ReassignScope)` where
`SpeakerChoice = .existing(id) | .new(name)`.

Two-step popover:

1. **Pick step** — vertical list of candidates: color dot
   (`TranscriptDesignTokens.speakerColor(for:)`), name, checkmark on `isCurrent`. A divider,
   then an "Add someone…" row that reveals an inline `TextField` (submit = confirm).
2. **Scope step** — shown only when the chosen person differs from current **and** the current
   speaker has >1 segment. Two buttons: **[This segment only]** and
   **[All N from "<current>"]**. If the current speaker has a single segment, skip this step
   and apply immediately (scope is moot).

Layout mirrors the approved mock:

```
┌─ Assign speaker ─────┐
 ● Alice        ✓
 ● Bob
 ● Speaker 3
 ─────────────────────
 ＋ Add someone…
└──────────────────────┘
   then: [This segment] [All]
```

Styling matches existing transcript popovers (compact, `.roundedBorder` field, small control
sizes).

## Component 3 — Wiring

**`TranscriptSegmentRow`**
- Replace `onRenameSpeaker: (String, String) -> Void` with
  `onAssignSpeaker: (_ segmentId: UUID, _ choice: SpeakerChoice, _ scope: ReassignScope) -> Void`.
- Add inputs: `candidates: [SpeakerCandidate]` and `currentSpeakerSegmentCount: Int` for the
  row's speaker.
- Both display modes (`.transcript`, `.segments`) present `SpeakerAssignPicker` in the popover
  instead of the free-text `speakerRenamePopover`. Remove `speakerRenameText` /
  `speakerRenamePopover` / `commitRename`.

**`TranscriptWindowView`**
- Build candidates via `SpeakerReassignment.candidates(in:forSegment:participants:calendarAttendees:)`,
  sourcing `participants` from `recording.participants` and `calendarAttendees` from
  `recording.calendarCandidates` (attendee display names; empty after reopen — acceptable).
- New `assignSpeaker(segmentId:choice:scope:)` that calls the pure helper (`assign` or
  `assignNew` with a freshly minted `UUID().uuidString` id), then the **existing**
  `richTranscript = updated` → `saveTranscript(updated)` → `recomputeSearch()` path.
- The `SpeakerTurnCard` speaker `Menu`: replace "Rename…" with "Reassign / rename…" that opens
  the same picker; its default scope is **`allOfSpeaker`** (a turn spans multiple segments —
  the natural unit there is the whole speaker). "This is me" / "Clear this is me" stay.
- Delete the old rename sheet (`renamingSpeakerId`, `speakerRenameText`, `commitSpeakerRename`,
  `renameSpeaker`) once both callers use the picker. `setMeSpeaker` is unchanged.

## Data Flow

```
click speaker badge
        ↓
SpeakerAssignPicker  (candidates from SpeakerReassignment.candidates)
        ↓  onChoose(choice, scope)
TranscriptWindowView.assignSpeaker(segmentId, choice, scope)
        ↓
SpeakerReassignment.assign / assignNew   → new RichTranscript
        ↓
richTranscript = updated → saveTranscript(updated) → recomputeSearch()
        ↓
TranscriptStore writes .richtranscript.json   (markdown/People list re-derive from labels)
```

## Edge Cases

- **No-op pick** (chose the current speaker): close picker, no write.
- **Single-segment speaker:** skip the scope step; apply directly.
- **Full merge empties a speaker:** orphaned `SpeakerLabel` removed; `meSpeakerId` transferred
  if it was the emptied speaker.
- **Add-name collides with an existing label** (case-insensitive): reuse that speaker's id
  (becomes a merge), never a duplicate label.
- **Unlabeled raw speakers** ("Speaker 2") are valid pick targets and valid origins.
- **Reopened recording with no participants:** candidate list = existing speakers only; the
  feature still works, just with fewer suggested names. "Add someone…" always available.
- **Live transcript:** speaker reassignment is offered only on the finished-recording
  transcript (same as today's rename), not in live mode.

## Testing

`Tests/dBriefTests/SpeakerReassignmentTests.swift` (swift-testing), all against the pure helper:

- `assign` `thisSegment` changes only the target segment's `speakerId`.
- `assign` `allOfSpeaker` rewrites every segment of the origin speaker.
- No-op when target == origin.
- Orphan label removed after a full merge; target label retained.
- `meSpeakerId` transfers when its speaker is fully merged away; untouched otherwise.
- `assignNew` mints a label with the injected id; collision (case-insensitive) reuses the
  existing id instead of duplicating.
- `candidates` ordering (current first), dedup by normalized name, name-only candidates
  excluded when already an existing speaker, `isCurrent` flagged correctly.

UI is exercised manually (build + run): pick existing, add new, both scopes, turn-card entry,
both display modes.

## Docs

Update `CLAUDE.md` (Speaker Diarization / Rich Transcript Viewer sections) and `site/docs/`
(+ NAV in `site/docs.js`) to describe the picker + per-segment reassignment, replacing the
"free-text rename popover" description.
