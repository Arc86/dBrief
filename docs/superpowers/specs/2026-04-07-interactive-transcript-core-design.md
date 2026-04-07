# Interactive Transcript Core — Design Spec
**Date:** 2026-04-07
**Sub-project:** 1 of 3 (Speaker Diarization and Filler Word Removal follow)

## Overview

Introduce a rich interactive transcript system to dBrief. This is the foundational sub-project that all subsequent transcript features (speaker diarization, filler word removal) build on. It delivers: a dedicated transcript window, word-level audio sync, inline segment editing, and starred segments.

## Scope

**In scope:**
- `RichTranscript` data model with word-token granularity
- `TranscriptStore` actor for sidecar persistence (`*.transcript.json`)
- `RichTranscriptBuilder` converting `TranscriptionResult → RichTranscript`
- Transcript window (`WindowGroup(for: UUID.self)`) with audio player, segment list, token highlighting
- Audio/transcript sync (segment-level always; word-level when backend provides timestamps)
- Inline segment editing with auto-save
- Starred segments with toolbar filter

**Out of scope (future sub-projects):**
- Auto speaker diarization (Sub-project 2)
- Manual speaker name assignment (Sub-project 2)
- Filler word detection and removal (Sub-project 3)

## Data Model

`TranscriptionResult` is unchanged — it remains the raw engine output. `RichTranscript` is the enriched derivative, persisted separately.

```swift
struct RichTranscript: Codable, Sendable {
    var version: Int                    // schema version, currently 1
    var segments: [RichSegment]
    var speakerLabels: [SpeakerLabel]   // empty until Sub-project 2
}

struct RichSegment: Codable, Sendable, Identifiable {
    var id: UUID
    var start: Double
    var end: Double
    var text: String                    // current text (may differ from original after edits)
    var originalText: String            // immutable — used for future revert
    var tokens: [RichToken]             // empty when engine didn't return word timestamps
    var speakerId: String?              // nil until Sub-project 2
    var isStarred: Bool
    var isEdited: Bool
}

struct RichToken: Codable, Sendable {
    var text: String
    var start: Double?                  // nil when word timestamps unavailable
    var end: Double?
    var isFillerWord: Bool              // always false in Sub-project 1; used by Sub-project 3
}

struct SpeakerLabel: Codable, Sendable {
    var id: String
    var displayName: String
}
```

### Sidecar file

Path: `<finalizedAudioURL-without-extension>.transcript.json`, written alongside the audio file. `Recording` gains a computed `transcriptSidecarURL: URL?` property (returns nil when `finalizedAudioURL` is nil).

## New Components

### `TranscriptionResult.Segment` extension

`TranscriptionResult.Segment` must be extended to optionally carry word-level data from backends that support it:

```swift
struct Segment: Codable, Sendable {
    let start: Double
    let end: Double
    let text: String
    let words: [Word]?          // new — nil when backend doesn't provide word timestamps

    struct Word: Codable, Sendable {
        let word: String
        let start: Double
        let end: Double
    }
}
```

`TranscriptionService` (remote Whisper endpoint) passes `timestamp_granularities[]=word` in requests and maps the response `words` array. `WhisperKitTranscriptionService` maps WhisperKit's existing per-word timing data. `LocalTranscriptionService` (Apple Speech) leaves `words` nil — Apple's `SFTranscriptionSegment` provides substring timestamps that don't map cleanly to word tokens.

### `RichTranscriptBuilder`

Pure struct, no async. Single method:

```swift
func build(from result: TranscriptionResult) -> RichTranscript
```

Converts each `TranscriptionResult.Segment` to a `RichSegment`. If `segment.words` is non-nil and non-empty, maps each `Word` to a `RichToken` with timestamps; otherwise leaves `tokens` empty. All flags default to `false`.

### `TranscriptStore` actor

Owned by `AppContext`, injected into the environment. Responsibilities: read and write `RichTranscript` to disk.

```swift
actor TranscriptStore {
    func load(for recording: Recording) async throws -> RichTranscript
    func save(_ transcript: RichTranscript, for recording: Recording) async throws
}
```

`Recording` gains `var richTranscript: RichTranscript?` as an in-memory cache, populated lazily when the transcript window first opens.

### `RecordingManager` change

After transcription completes (before AI analysis begins), call `RichTranscriptBuilder().build(from:)` and `TranscriptStore.save()`. This ensures the sidecar exists for any recording that has a transcript, regardless of whether AI succeeds.

## Transcript Window

### Registration

A new `WindowGroup(for: UUID.self)` scene in `DBriefApp`, keyed by `recording.id`. SwiftUI deduplicates: opening the same recording twice focuses the existing window. Minimum window size: 700×500.

### Layout (top to bottom)

1. **Title bar** — recording title, date, duration (SwiftUI `.navigationTitle` + toolbar)
2. **Audio player bar** — play/pause button, scrubber with current/total time display; powered by existing `AudioPlayer`
3. **Toolbar** — "All" / "⭐ Starred" filter toggle, search icon (placeholder for now), export icon
4. **Transcript body** — `ScrollView` + `ScrollViewReader` containing a `LazyVStack` of segment rows

### Segment row

Each `RichSegment` renders as a rounded card:
- **Header:** speaker badge (`Speaker 1` placeholder until Sub-project 2), timestamp button (seeks on tap), star button (☆/★), edit button (✎) — star and edit revealed on hover
- **Body (display mode):** inline token flow — each `RichToken` is a tappable `Text` span; clicking seeks to `token.start ?? segment.start`
- **Body (edit mode):** `TextEditor` replacing the token flow; Esc cancels, changes auto-saved with 0.5s debounce

### Segment visual states

| State | Appearance |
|-------|-----------|
| Default | Neutral rounded card |
| Currently playing | Blue tint background + blue border |
| Starred | Gold tint background + gold border |
| Editing | Blue border, `TextEditor` visible |
| Hovered | Subtle border, star/edit controls visible |

## Audio / Transcript Sync

`AudioPlayer` gains `@Published var currentTime: TimeInterval`, updated by a 50ms CADisplayLink-driven timer while playing.

The transcript window observes `currentTime` and on each tick:
1. Finds the `RichSegment` where `segment.start ≤ currentTime < segment.end` — applies the "playing" visual state
2. Within that segment, if tokens have timestamps, finds the `RichToken` where `token.start ≤ currentTime < token.end` — applies a highlighted style to that word
3. Calls `scrollViewProxy.scrollTo(segment.id, anchor: .center)` to keep the active segment visible

**Seeking:** clicking a timestamp label or token calls `audioPlayer.seek(to: timestamp)`. Clicking the scrubber seeks via the existing `AudioPlayer` interface.

## Entry Points

- **ResultsView action bar:** "View Transcript" button, enabled when `recording.richTranscript != nil` (sidecar exists). Opens the window via `openWindow(value: recording.id)`.
- **RecordingHistoryView:** a "Transcript" action chip in the expandable row, visible for any recording whose `transcriptSidecarURL` exists on disk.

## Editing

Tapping ✎ on a segment switches it to edit mode: `TextEditor` replaces the token flow, pre-filled with `segment.text`. On edit:
- `segment.text` is updated
- `segment.isEdited = true`
- `segment.tokens` is cleared (word timestamps no longer match edited text)
- `TranscriptStore.save()` is called after a 0.5s debounce
- Esc reverts to display mode without saving uncommitted changes

## Starred Segments

- Tapping ☆ toggles `segment.isStarred` and triggers `TranscriptStore.save()`
- Toolbar "⭐ Starred" filter hides all non-starred segments
- The `ResultsView` and `RecordingHistoryView` do not surface starred counts in this sub-project (deferred to a future polish pass)

## Error Handling

| Scenario | Behavior |
|----------|----------|
| No finalized audio file | Window opens; audio player shows disabled state with "Audio file not found" |
| No word timestamps | Tokens array is empty; segment renders as plain paragraph; clicking seeks to `segment.start` |
| Sidecar load failure | Empty state with "Transcript unavailable" + "Rebuild" button; rebuild re-runs `RichTranscriptBuilder` from in-memory `TranscriptionResult` |
| `TranscriptStore.save()` failure | Non-fatal; logs error via `Logger.recording`; user is not interrupted |

## Testing

- `RichTranscriptBuilder` unit tests: segments with word timestamps → tokens populated; segments without → empty tokens; `originalText` matches input `text`
- `TranscriptStore` tests: round-trip encode/decode of `RichTranscript`; load of missing file throws; schema version field preserved
- These join the existing `WhisperPipelineTests.swift` pattern in `Tests/dBriefTests/`

## Sub-project Dependencies

| Sub-project | What it needs from this spec |
|-------------|------------------------------|
| Speaker Diarization (2) | `RichSegment.speakerId`, `RichTranscript.speakerLabels`, `SpeakerLabel` model, transcript window to display/edit speaker badges |
| Filler Word Removal (3) | `RichToken.isFillerWord` flag, token-level rendering (to visually strike or hide filler tokens) |
