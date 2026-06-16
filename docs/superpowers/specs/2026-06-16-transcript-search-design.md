# Transcript Search — Design

**Date:** 2026-06-16
**Status:** Approved (brainstorming → spec)
**Area:** Rich Transcript Viewer (`TranscriptDetailView` in `Sources/dBrief/UI/TranscriptWindowView.swift`)

## Problem

There is currently no way to search within a transcript. For long recordings, finding a
specific passage means scrolling and reading manually. We want an in-viewer search that
locates text quickly, highlights matches, and lets the user step between them.

## Scope

**In scope (v1):**
- Search the **transcript text** of a **finished recording** (the `.transcript` view mode).
- **Regex** queries (case-insensitive). A plain word is a valid regex, so there is no
  separate "plain vs regex" mode — the field is always interpreted as a regular expression.
- Native macOS toolbar search affordance (full field when wide, loupe when narrow).
- Highlight all matches, step prev/next, show an "n of m" counter, auto-scroll to current.

**Out of scope (v1):**
- Boolean operators (AND/OR/NOT) — explicitly dropped to keep v1 simple.
- Searching the **live** (in-progress) transcript.
- Searching the **summary**, **chat**, action items, or tags panes.
- Speaker-name matching.
- Case-sensitive / whole-word toggles (case-insensitive always).
- Persisting the query or any model/disk changes.

## UI / UX

Use the **native** SwiftUI search control rather than a custom Safari-style bar, because
the requested look (full search field when the window is wide, collapsing to a
magnifying-glass loupe button when the window is too narrow) is exactly the default
behavior of `NSSearchToolbarItem` that `.searchable(placement: .toolbar)` bridges to on
macOS. This works on macOS 14+ with no availability gating. (`searchToolbarBehavior(.minimize)`
is an iOS/iPadOS/visionOS-26 bottom-toolbar behavior and is **not** used here.)

- Attach to the transcript content:
  ```swift
  .searchable(text: $searchQuery,
              isPresented: $isSearchPresented,
              placement: .toolbar,
              prompt: "Search transcript")
  ```
- `⌘F` sets `isSearchPresented = true`. If the viewer is currently in `.summary` or `.chat`
  mode, focusing/typing search **auto-switches to the `.transcript` view** so matches are
  visible.
- `Esc` dismisses the field and clears highlights (native).
- **Navigation accessory:** when `searchQuery` is non-empty, a compact toolbar group shows a
  status label — `"n of m"`, `"No results"`, or `"Invalid pattern"` — plus up/down chevrons
  for previous/next. In a very narrow window these fold into the toolbar overflow (`···`)
  menu — standard native behavior.
- **Keyboard:** `⌘F` focuses search; `⏎` (`.onSubmit(of: .search)`) = next match; the macOS-standard
  `⌘G` = next and `⌘⇧G` = previous (registered as hidden zero-size buttons so they work even when
  the field has collapsed to a loupe). The chevrons mirror next/prev.

## Architecture

### 1. `TranscriptSearch` — pure, testable matching engine

A new pure helper (struct with a static `func`, following the codebase convention of pure
unit-tested helpers such as `LiveSegmentMerge`, `SpeakerMerge`, `MicReconfigurePlanner`).

- **Input:** the displayed turns as `(turnId: UUID, text: String)` pairs, plus the query
  string. (Searching the displayed `SpeakerTurn.text` — the same string the row renders —
  keeps highlight ranges trivially correct.)
- **Compilation:** query compiled as `NSRegularExpression` with `.caseInsensitive`.
- **Output:** an ordered `[Match]` walking turns top-to-bottom and matches left-to-right
  within each turn. Ranges are stored as **Character offsets** (not `Range<String.Index>`) so
  they map cleanly onto `AttributedString` indices in the view:
  ```swift
  struct Match: Equatable {
      let turnId: UUID
      let location: Int    // Character offset into that turn's text
      let length: Int      // Character length of the match
      let globalIndex: Int // 0-based position in the flat list
  }
  ```
- **Validity:** the engine exposes whether the pattern compiled (e.g. returns a result type
  carrying `isValid: Bool` alongside `matches: [Match]`). Invalid regex → `isValid == false`,
  `matches == []`. Empty/whitespace query → `isValid == true`, `matches == []`.

The engine performs no SwiftUI work and has no dependency on view types, so it is fully
unit-testable.

### 1a. Prerequisite — stable `SpeakerTurn.id`

`RichTranscript.speakerTurns()` currently assigns each `SpeakerTurn` a fresh `UUID()` on every
call, and `displayedTurns` is a computed property re-evaluated multiple times per render. For
search to map matches to turns and scroll reliably (and to fix the existing latent churn that
the playback auto-scroll already depends on), change `SpeakerTurn.init` to derive its `id` from
its **first segment's** stable `RichSegment.id` (`segments.first?.id ?? UUID()`). This makes turn
identity deterministic across recomputations of the same transcript.

### 2. View integration — `TranscriptDetailView`

New `@State`:
- `searchQuery: String = ""`
- `isSearchPresented: Bool = false`
- `searchResult: TranscriptSearch.Result` (matches + isValid), recomputed (debounced) when
  `searchQuery` or `displayedTurns` change.
- `currentMatchIndex: Int = 0`

Behavior:
- A debounced recompute (~150–200 ms after the last keystroke) calls `TranscriptSearch` over
  `displayedTurns`. On a new non-empty result, `currentMatchIndex` resets to 0 and the view
  scrolls to the first match.
- Recompute also runs when `displayedTurns` changes (e.g. after diarization or a speaker
  rename rebuilds the turns), so stale matches never linger.
- Prev/next mutate `currentMatchIndex` with wraparound and call
  `proxy.scrollTo(match.turnId, anchor: .center)` — reusing the existing `ScrollViewReader`
  in `transcriptList`.

### 3. Highlighting

`transcriptRow`'s body currently renders `Text(turn.text)`. Change it to render an
`AttributedString` derived from `turn.text`:
- When `searchQuery` is empty (or search dismissed): render the plain string exactly as today
  (no behavioral change to the non-search path).
- When there are matches in this turn: apply a highlight background to every match range, and
  a stronger accent (foreground/background) to the range whose `globalIndex == currentMatchIndex`.
- Colors come from `TranscriptDesignTokens` (add a `searchHighlight` / `searchHighlightCurrent`
  pair, scheme-aware) to keep the glass UI consistent.

`textSelection(.enabled)` is preserved.

## Data flow

```
searchQuery (TextField via .searchable)
        │  (debounced)
        ▼
TranscriptSearch.search(turns: displayedTurns.map{($0.id,$0.text)}, query:)
        │
        ▼
TranscriptSearch.Result { isValid, matches: [Match] }
        ├──► counter label  ("n of m" / "No results" / "Invalid pattern")
        ├──► transcriptRow   (AttributedString highlight per turn)
        └──► prev/next + ⏎/⇧⏎ → currentMatchIndex → proxy.scrollTo(turnId)
```

## Error handling / edge cases

- **Invalid regex** (e.g. a lone `(`): counter shows "Invalid pattern"; no highlights; no
  crash (NSRegularExpression init failure handled).
- **No matches:** counter shows "No results"; no highlights.
- **Empty query / dismissed:** highlights cleared; rows render plain text.
- **Transcript changes mid-search** (diarize/rename): matches recomputed against new turns.
- **Mode switch:** typing in search forces `.transcript` mode so results are visible; search
  is a no-op concept in summary/chat.

## Testing

`Tests/dBriefTests/TranscriptSearchTests.swift` (swift-testing), covering:
- Literal substring match (single and multiple occurrences within one turn).
- Match ordering across multiple turns (top-to-bottom, left-to-right; `globalIndex` correct).
- Regex patterns: `\bword\b`, character classes, alternation.
- Case-insensitivity (`Budget` query matches `budget`).
- Invalid regex → `isValid == false`, `matches == []`.
- Empty / whitespace query → `isValid == true`, `matches == []`.
- No-match query → empty matches.

## Documentation

- Update `CLAUDE.md` "Rich Transcript Viewer" section to mention transcript search and the
  `TranscriptSearch` helper.
- Update `site/docs/` (and the NAV in `site/docs.js`) to document searching within a
  transcript.

## Non-goals / future

- Boolean operators, live-transcript search, cross-pane (summary/chat) search, and
  case/whole-word toggles are deliberately deferred; the `TranscriptSearch` engine is shaped
  so boolean scoping or a regex/literal toggle could be added later without reworking the UI.
