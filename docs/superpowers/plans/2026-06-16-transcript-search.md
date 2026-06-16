# Transcript Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add in-viewer search to a finished recording's transcript — a native macOS adaptive toolbar search field (full field when wide, loupe when narrow) backed by a pure regex matching engine, with highlight-all, an "n of m" counter, and prev/next navigation.

**Architecture:** A pure, view-agnostic `TranscriptSearch` engine compiles the query as a case-insensitive `NSRegularExpression` and returns ordered Character-offset matches over the displayed turns. `TranscriptDetailView` binds the native `.searchable` toolbar field to a query, recomputes matches (debounced), highlights them per-row via `AttributedString`, and steps/scrolls through them. A small prerequisite makes `SpeakerTurn.id` stable so matches map to turns reliably.

**Tech Stack:** Swift 6.2, SwiftUI (`.searchable`, `AttributedString`, `ScrollViewReader`), `NSRegularExpression`, swift-testing.

**Working directory:** `/Users/jesper/Documents/Code/dBrief/.claude/worktrees/dBrief-transcript-search` (branch `worktree-dBrief-transcript-search`). All `swift build` / `swift test` / `git` commands run from there.

---

## File Structure

- **Modify** `Sources/dBrief/Models/SpeakerTurn.swift` — derive `id` from the first segment for stable turn identity.
- **Create** `Sources/dBrief/Services/TranscriptSearch.swift` — pure regex search engine (alongside the other pure transcript helper `SpeakerAssigner.swift`).
- **Modify** `Sources/dBrief/UI/TranscriptDesignTokens.swift` — add search-highlight colors.
- **Modify** `Sources/dBrief/UI/TranscriptWindowView.swift` — search state, recompute, highlighting, `.searchable`, toolbar accessory, keyboard shortcuts, scroll.
- **Create** `Tests/dBriefTests/SpeakerTurnTests.swift` — stable-id test.
- **Create** `Tests/dBriefTests/TranscriptSearchTests.swift` — engine tests.
- **Modify** `CLAUDE.md` — document search in the Rich Transcript Viewer section.
- **Modify** `site/docs/history/transcript-viewer.md` — user-facing search docs.

---

## Task 1: Stable `SpeakerTurn.id`

**Files:**
- Modify: `Sources/dBrief/Models/SpeakerTurn.swift:11-15`
- Test: `Tests/dBriefTests/SpeakerTurnTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/dBriefTests/SpeakerTurnTests.swift`:

```swift
import Foundation
@testable import dBrief
import Testing

struct SpeakerTurnTests {
    @Test("speakerTurns produces the same turn ids across repeated calls")
    func stableTurnIds() {
        let segments = [
            RichSegment(start: 0, end: 1, text: "Hello", originalText: "Hello", speakerId: "Speaker 1"),
            RichSegment(start: 1, end: 2, text: "there", originalText: "there", speakerId: "Speaker 1"),
            RichSegment(start: 2, end: 3, text: "Hi", originalText: "Hi", speakerId: "Speaker 2"),
        ]
        let transcript = RichTranscript(segments: segments)

        let first = transcript.speakerTurns()
        let second = transcript.speakerTurns()

        #expect(first.count == second.count)
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("a turn's id matches its first segment's id")
    func idDerivedFromFirstSegment() {
        let seg = RichSegment(start: 0, end: 1, text: "Hello", originalText: "Hello")
        let transcript = RichTranscript(segments: [seg])

        let turns = transcript.speakerTurns()

        #expect(turns.first?.id == seg.id)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpeakerTurnTests`
Expected: FAIL — `first.map(\.id) == second.map(\.id)` is false because each call assigns fresh `UUID()`s.

- [ ] **Step 3: Derive the turn id from the first segment**

In `Sources/dBrief/Models/SpeakerTurn.swift`, replace the initializer (lines 11-15):

```swift
    init(speakerId: String?, segments: [RichSegment]) {
        // Derive a stable id from the first segment so repeated `speakerTurns()`
        // calls (and re-renders) yield consistent turn identity — required for
        // match-to-turn mapping, scroll-to, and the playback auto-scroll.
        self.id = segments.first?.id ?? UUID()
        self.speakerId = speakerId
        self.segments = segments
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpeakerTurnTests`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Models/SpeakerTurn.swift Tests/dBriefTests/SpeakerTurnTests.swift
git commit -m "Make SpeakerTurn.id stable across speakerTurns() calls"
```

---

## Task 2: `TranscriptSearch` pure engine

**Files:**
- Create: `Sources/dBrief/Services/TranscriptSearch.swift`
- Test: `Tests/dBriefTests/TranscriptSearchTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/dBriefTests/TranscriptSearchTests.swift`:

```swift
import Foundation
@testable import dBrief
import Testing

struct TranscriptSearchTests {
    private func turn(_ text: String, _ id: UUID = UUID()) -> (id: UUID, text: String) {
        (id: id, text: text)
    }

    private func substring(_ text: String, _ m: TranscriptSearch.Match) -> String {
        let chars = Array(text)
        return String(chars[m.location ..< (m.location + m.length)])
    }

    @Test("empty query yields no matches and is valid")
    func emptyQuery() {
        let result = TranscriptSearch.search(turns: [turn("Hello world")], query: "")
        #expect(result.isValid)
        #expect(result.matches.isEmpty)
    }

    @Test("whitespace-only query yields no matches and is valid")
    func whitespaceQuery() {
        let result = TranscriptSearch.search(turns: [turn("Hello world")], query: "   ")
        #expect(result.isValid)
        #expect(result.matches.isEmpty)
    }

    @Test("literal substring matches every occurrence in a turn")
    func multipleOccurrences() {
        let t = turn("the budget is the budget plan")
        let result = TranscriptSearch.search(turns: [t], query: "budget")
        #expect(result.isValid)
        #expect(result.matches.count == 2)
        #expect(result.matches[0].location == 4)
        #expect(result.matches[0].length == 6)
        #expect(substring(t.text, result.matches[0]) == "budget")
        #expect(substring(t.text, result.matches[1]) == "budget")
        #expect(result.matches.map(\.globalIndex) == [0, 1])
    }

    @Test("matches are ordered top-to-bottom across turns with sequential globalIndex")
    func orderingAcrossTurns() {
        let a = turn("alpha cat", UUID())
        let b = turn("cat beta cat", UUID())
        let result = TranscriptSearch.search(turns: [a, b], query: "cat")
        #expect(result.matches.count == 3)
        #expect(result.matches[0].turnId == a.id)
        #expect(result.matches[1].turnId == b.id)
        #expect(result.matches[2].turnId == b.id)
        #expect(result.matches.map(\.globalIndex) == [0, 1, 2])
    }

    @Test("search is case-insensitive")
    func caseInsensitive() {
        let result = TranscriptSearch.search(turns: [turn("Budget review")], query: "budget")
        #expect(result.matches.count == 1)
    }

    @Test("regex metacharacters work")
    func regexPattern() {
        let t = turn("cat category scatter")
        // \bcat\b should match only the standalone word "cat"
        let result = TranscriptSearch.search(turns: [t], query: "\\bcat\\b")
        #expect(result.matches.count == 1)
        #expect(substring(t.text, result.matches[0]) == "cat")
    }

    @Test("invalid regex is reported and yields no matches")
    func invalidRegex() {
        let result = TranscriptSearch.search(turns: [turn("Hello (world")], query: "(")
        #expect(result.isValid == false)
        #expect(result.matches.isEmpty)
    }

    @Test("no-match query yields empty valid result")
    func noMatch() {
        let result = TranscriptSearch.search(turns: [turn("Hello world")], query: "zzz")
        #expect(result.isValid)
        #expect(result.matches.isEmpty)
    }

    @Test("zero-length regex matches are ignored")
    func zeroLengthMatchesIgnored() {
        let result = TranscriptSearch.search(turns: [turn("Hello world")], query: "x*")
        #expect(result.matches.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TranscriptSearchTests`
Expected: FAIL — `TranscriptSearch` is not defined (compile error).

- [ ] **Step 3: Implement the engine**

Create `Sources/dBrief/Services/TranscriptSearch.swift`:

```swift
import Foundation

/// Pure, view-agnostic regex search over the displayed transcript turns.
///
/// Each turn is identified by its `id` and searched by its rendered `text`, so
/// match offsets line up exactly with what `transcriptRow` displays. The query
/// is interpreted as a case-insensitive regular expression — a plain word is a
/// valid regex matching literally, so there is no separate "plain vs regex" mode.
enum TranscriptSearch {

    /// A single regex match within one turn's text, expressed in Character offsets
    /// so it maps cleanly onto `AttributedString` indices in the view layer.
    struct Match: Equatable {
        let turnId: UUID
        let location: Int     // Character offset of the match start within the turn text
        let length: Int       // Character length of the match
        let globalIndex: Int  // 0-based position in the flat, ordered match list
    }

    /// Outcome of a search: whether the pattern compiled, plus the ordered matches.
    struct Result: Equatable {
        var isValid: Bool
        var matches: [Match]

        static let empty = Result(isValid: true, matches: [])
    }

    /// Searches `turns` (id + displayed text) for `query`.
    ///
    /// Matches are ordered top-to-bottom across turns and left-to-right within
    /// each turn, with `globalIndex` numbering them 0..<count. An empty or
    /// whitespace-only query returns no matches but stays `isValid`. A pattern
    /// that fails to compile returns `isValid == false` and no matches.
    /// Zero-length matches (e.g. `x*`) are skipped so highlighting can't loop.
    static func search(turns: [(id: UUID, text: String)], query: String) -> Result {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        guard let regex = try? NSRegularExpression(pattern: query, options: [.caseInsensitive]) else {
            return Result(isValid: false, matches: [])
        }

        var matches: [Match] = []
        var globalIndex = 0
        for turn in turns {
            let text = turn.text
            if text.isEmpty { continue }
            let full = NSRange(text.startIndex..<text.endIndex, in: text)
            regex.enumerateMatches(in: text, options: [], range: full) { result, _, _ in
                guard let result, result.range.length > 0,
                      let range = Range(result.range, in: text) else { return }
                let location = text.distance(from: text.startIndex, to: range.lowerBound)
                let length = text.distance(from: range.lowerBound, to: range.upperBound)
                matches.append(Match(turnId: turn.id, location: location, length: length, globalIndex: globalIndex))
                globalIndex += 1
            }
        }
        return Result(isValid: true, matches: matches)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TranscriptSearchTests`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Services/TranscriptSearch.swift Tests/dBriefTests/TranscriptSearchTests.swift
git commit -m "Add pure TranscriptSearch regex matching engine"
```

---

## Task 3: Search-highlight design tokens

**Files:**
- Modify: `Sources/dBrief/UI/TranscriptDesignTokens.swift:78` (after the Typography section)

- [ ] **Step 1: Add the highlight color tokens**

In `Sources/dBrief/UI/TranscriptDesignTokens.swift`, insert after the `secondaryText` function (after line 77, before the `// MARK: - Speaker accent colours` comment):

```swift

    // MARK: - Search highlight

    /// Background behind every match of the active search query.
    static func searchHighlight(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.yellow.opacity(0.32) : Color.yellow.opacity(0.45)
    }

    /// Background behind the currently-focused match (the one prev/next lands on).
    static func searchHighlightCurrent(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.orange.opacity(0.70) : Color.orange.opacity(0.65)
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Builds without errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/UI/TranscriptDesignTokens.swift
git commit -m "Add search-highlight color tokens"
```

---

## Task 4: Search state, recompute, and per-row highlighting

This task adds the search state and the `AttributedString` highlight, but **not** yet the `.searchable` field or toolbar controls (Task 5). After this task, search state exists and `transcriptRow` renders highlights when `searchResult` is populated, but nothing populates it from the UI yet — that's fine; Task 5 wires the inputs.

**Files:**
- Modify: `Sources/dBrief/UI/TranscriptWindowView.swift` (state block ~lines 32-48; `transcriptRow` ~lines 359-393; add helpers near the Actions section)

- [ ] **Step 1: Add search state**

In `TranscriptDetailView`, add these `@State` properties next to the existing ones (e.g. after line 39 `@State private var isGenerating = false`):

```swift
    // Transcript search (finished-recording transcript only)
    @State private var searchQuery = ""
    @State private var isSearchPresented = false
    @State private var searchResult = TranscriptSearch.Result.empty
    @State private var matchesByTurn: [UUID: [TranscriptSearch.Match]] = [:]
    @State private var currentMatchIndex = 0
    @State private var searchDebounce: Task<Void, Never>?
    /// Bumped to ask the transcript `ScrollViewReader` to scroll to the current match.
    @State private var searchScrollTick = 0
```

- [ ] **Step 2: Add the recompute + navigation helpers**

Add these methods inside `TranscriptDetailView` (place them just before `// MARK: - Persistence`, i.e. before `private func saveTranscript`):

```swift
    // MARK: - Search

    /// True while the user has an active (non-blank) query.
    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Status text for the toolbar accessory.
    private var searchCounterLabel: String {
        guard isSearching else { return "" }
        if !searchResult.isValid { return "Invalid pattern" }
        if searchResult.matches.isEmpty { return "No results" }
        return "\(currentMatchIndex + 1) of \(searchResult.matches.count)"
    }

    /// Recomputes matches over the currently displayed turns. Keeps
    /// `currentMatchIndex` in bounds; callers decide when to reset it to 0.
    private func recomputeSearch() {
        let turns = displayedTurns.map { (id: $0.id, text: $0.text) }
        let result = TranscriptSearch.search(turns: turns, query: searchQuery)
        searchResult = result
        matchesByTurn = Dictionary(grouping: result.matches, by: \.turnId)
        if result.matches.isEmpty {
            currentMatchIndex = 0
        } else if currentMatchIndex >= result.matches.count {
            currentMatchIndex = result.matches.count - 1
        }
    }

    /// Debounced recompute triggered on each keystroke; resets to the first match.
    private func scheduleSearchRecompute() {
        searchDebounce?.cancel()
        searchDebounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            if Task.isCancelled { return }
            currentMatchIndex = 0
            recomputeSearch()
            // Surface results: jump to the transcript view if elsewhere.
            if isSearching, mode != .transcript { mode = .transcript }
            searchScrollTick &+= 1
        }
    }

    private func gotoNextMatch() {
        guard !searchResult.matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % searchResult.matches.count
        searchScrollTick &+= 1
    }

    private func gotoPrevMatch() {
        guard !searchResult.matches.isEmpty else { return }
        let n = searchResult.matches.count
        currentMatchIndex = (currentMatchIndex - 1 + n) % n
        searchScrollTick &+= 1
    }

    /// Builds the row text with search highlights. Returns plain (un-highlighted)
    /// text when there is no active query or no matches in this turn.
    private func highlightedText(_ turn: SpeakerTurn) -> AttributedString {
        var attr = AttributedString(turn.text)
        guard isSearching, let turnMatches = matchesByTurn[turn.id], !turnMatches.isEmpty else {
            return attr
        }
        let chars = attr.characters
        let count = chars.count
        for match in turnMatches {
            guard match.location >= 0, match.location + match.length <= count else { continue }
            let lower = chars.index(chars.startIndex, offsetBy: match.location)
            let upper = chars.index(lower, offsetBy: match.length)
            attr[lower..<upper].backgroundColor = match.globalIndex == currentMatchIndex
                ? TranscriptDesignTokens.searchHighlightCurrent(scheme: colorScheme)
                : TranscriptDesignTokens.searchHighlight(scheme: colorScheme)
        }
        return attr
    }
```

- [ ] **Step 3: Use the highlighted text in `transcriptRow`**

In `transcriptRow` (around line 382), replace:

```swift
                Text(turn.text)
                    .font(.system(size: CGFloat(fontSize)))
                    .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: colorScheme))
                    .lineSpacing(CGFloat(fontSize) * 0.4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
```

with:

```swift
                Text(highlightedText(turn))
                    .font(.system(size: CGFloat(fontSize)))
                    .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: colorScheme))
                    .lineSpacing(CGFloat(fontSize) * 0.4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
```

- [ ] **Step 4: Recompute search when the transcript changes**

So matches never go stale after a rebuild, add `recomputeSearch()` calls:

In `runDiarization()`, immediately after `richTranscript = updated` (around line 703):
```swift
            richTranscript = updated
            recomputeSearch()
```

In `rebuildTranscript()`, after `richTranscript = built` (around line 889):
```swift
        richTranscript = built
        loadFailed = false
        recomputeSearch()
```

At the very end of `loadTranscript()` (after the `if resumedChat { ... } else { ... }` block, around line 883), add:
```swift
        recomputeSearch()
```

- [ ] **Step 5: Build to verify it compiles**

Run: `swift build`
Expected: Builds without errors. (Highlights won't appear yet — no UI populates `searchQuery`; that's Task 5.)

- [ ] **Step 6: Commit**

```bash
git add Sources/dBrief/UI/TranscriptWindowView.swift
git commit -m "Add transcript search state, recompute, and row highlighting"
```

---

## Task 5: Native `.searchable` field, toolbar controls, keyboard, and scroll

**Files:**
- Modify: `Sources/dBrief/UI/TranscriptWindowView.swift` (`body` ~lines 90-174; `transcriptList` ~lines 330-349; `toolbarContent` ~lines 256-291; add a private `ViewModifier` at end of file)

- [ ] **Step 1: Add a gating ViewModifier for the search field**

`.searchable` should appear only for finished recordings (not the live view). Add this private modifier at the end of `Sources/dBrief/UI/TranscriptWindowView.swift`, after the `IdentifiedString` struct:

```swift
/// Applies the native macOS toolbar search field only when `enabled` (finished
/// recordings). On macOS the field shows full-width when the toolbar has room and
/// collapses to a magnifying-glass loupe when the window is narrow — no extra code.
private struct TranscriptSearchableModifier: ViewModifier {
    let enabled: Bool
    @Binding var query: String
    @Binding var isPresented: Bool
    let onSubmitSearch: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .searchable(text: $query,
                            isPresented: $isPresented,
                            placement: .toolbar,
                            prompt: "Search transcript")
                .onSubmit(of: .search, onSubmitSearch)
        } else {
            content
        }
    }
}
```

- [ ] **Step 2: Attach the search field, query observer, and keyboard shortcuts in `body`**

In `body`, add these modifiers to the outer `VStack(spacing: 0) { ... }` — place them right after the existing `.task { await loadTranscript() }` (line 120) and before the first `.onChange`:

```swift
        .modifier(TranscriptSearchableModifier(
            enabled: !isLive,
            query: $searchQuery,
            isPresented: $isSearchPresented,
            onSubmitSearch: gotoNextMatch))
        .background(findShortcuts)
        .onChange(of: searchQuery) { _, _ in scheduleSearchRecompute() }
        .onChange(of: isSearchPresented) { _, presented in
            if !presented {
                searchQuery = ""
                searchDebounce?.cancel()
                recomputeSearch()
            }
        }
```

- [ ] **Step 3: Add the hidden keyboard-shortcut buttons**

Add this computed property inside `TranscriptDetailView` (next to the other search helpers from Task 4):

```swift
    /// Zero-size buttons that register Find keyboard shortcuts without adding any
    /// visible UI (the `.searchable` field is the only visible search affordance):
    /// ⌘F focuses search, ⌘G / ⌘⇧G step next/previous match.
    private var findShortcuts: some View {
        Group {
            Button("") { if !isLive { isSearchPresented = true } }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { gotoNextMatch() }
                .keyboardShortcut("g", modifiers: .command)
            Button("") { gotoPrevMatch() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
```

- [ ] **Step 4: Add the prev/next/counter toolbar accessory**

In `toolbarContent`, inside the existing `ToolbarItemGroup(placement: .primaryAction)` (after the opening brace at line 256, before the Copy button), add:

```swift
            if isSearching {
                Text(searchCounterLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Search matches")
                Button { gotoPrevMatch() } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(searchResult.matches.isEmpty)
                .help("Previous match (⌘⇧G)")
                Button { gotoNextMatch() } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(searchResult.matches.isEmpty)
                .help("Next match (⌘G)")
                Divider()
            }
```

- [ ] **Step 5: Scroll to the current match in `transcriptList`**

In `transcriptList`, add an `.onChange(of: searchScrollTick)` to the `List` inside the `ScrollViewReader`, right after the existing `.onChange(of: audioPlayer.currentTime)` block (around line 347):

```swift
            .onChange(of: searchScrollTick) { _, _ in
                guard searchResult.matches.indices.contains(currentMatchIndex) else { return }
                let turnId = searchResult.matches[currentMatchIndex].turnId
                withAnimation { proxy.scrollTo(turnId, anchor: .center) }
            }
```

- [ ] **Step 6: Build and run the full test suite**

Run: `swift build && swift test`
Expected: Builds; all tests pass (including the 268 existing + the new `SpeakerTurnTests` and `TranscriptSearchTests`).

- [ ] **Step 7: Manual smoke test**

Run: `make run`
Verify in a finished recording's transcript:
1. Wide window → a search field shows top-right; narrow the window → it collapses to a loupe button.
2. `⌘F` focuses the field. Typing a word highlights all matches (yellow) and accents the current one (orange); counter shows "1 of N".
3. `⌘G` / `⌘⇧G` and the up/down chevrons step matches, scrolling each into view; `⏎` advances.
4. A regex like `\baction\b` matches whole words; a bad pattern like `(` shows "Invalid pattern".
5. `Esc` clears highlights and the query.
6. Typing while on the Summary/Chat view switches to the Transcript view.

- [ ] **Step 8: Commit**

```bash
git add Sources/dBrief/UI/TranscriptWindowView.swift
git commit -m "Wire native searchable field, navigation, and highlight scroll"
```

---

## Task 6: Documentation

**Files:**
- Modify: `CLAUDE.md` (Rich Transcript Viewer section)
- Modify: `site/docs/history/transcript-viewer.md` (Toolbar actions table + a Search section)

- [ ] **Step 1: Update CLAUDE.md**

In `CLAUDE.md`, find the "### Rich Transcript Viewer" section's bullet list and add a bullet after the `TranscriptAnalysisView` line:

```markdown
- **Transcript search** — `TranscriptDetailView` hosts a native `.searchable(placement: .toolbar)` field (macOS shows a full search field when wide, collapsing to a loupe button when the window is narrow). The query is a case-insensitive regex evaluated by the pure, unit-tested `TranscriptSearch` engine (`Services/TranscriptSearch.swift`, `TranscriptSearchTests`) over the displayed `SpeakerTurn`s; matches are highlighted per-row via `AttributedString`, with an "n of m" toolbar counter and ⌘G / ⌘⇧G (and up/down chevron) prev/next navigation that scrolls each match into view. Finished-recording transcript only (not live/summary/chat).
```

- [ ] **Step 2: Update the user-facing docs page**

In `site/docs/history/transcript-viewer.md`, add a new `## Searching the transcript` section immediately before the `## Toolbar actions` section:

```markdown
## Searching the transcript

Use the **search field** in the toolbar (or press **⌘F**) to find text in a long transcript. When the window is wide the search field shows in full; when it's narrow it collapses to a magnifying-glass button — click it to search.

- Every match is highlighted, and the match you're currently on is highlighted more strongly.
- The toolbar shows a **"3 of 12"** counter. Use the **up/down arrows** next to it — or **⌘G** (next) and **⌘⇧G** (previous), or **Return** for next — to jump between matches. Each jump scrolls the match into view.
- Search understands **regular expressions**, so `\baction\b` matches the whole word "action" only. Plain words work as you'd expect. An invalid pattern shows "Invalid pattern".
- Press **Esc** to close search and clear the highlights.

Search covers the transcript text of a finished recording. It isn't available for the live (in-progress) transcript or the Summary/Chat views.
```

Then add a row to the existing **Toolbar actions** table, after the **Chat** row:

```markdown
| **Search** | Find text in the transcript (⌘F); ⌘G / ⌘⇧G step matches |
```

- [ ] **Step 3: Verify the NAV is unchanged**

No `site/docs.js` change is needed — search lives inside the existing `history/transcript-viewer` page, which is already in the nav. Confirm:

Run: `grep -n "history/transcript-viewer" site/docs.js`
Expected: the existing entry on/near line 76 is present (no edit required).

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md site/docs/history/transcript-viewer.md
git commit -m "Document transcript search"
```

---

## Self-Review Notes

- **Spec coverage:** regex engine (Task 2) ✓; native adaptive `.searchable` field/loupe (Task 5) ✓; highlight all + current (Task 4) ✓; counter + prev/next + scroll (Task 5) ✓; ⌘F / ⌘G / ⌘⇧G / ⏎ (Task 5) ✓; invalid-pattern + no-results states (Tasks 2, 4) ✓; auto-switch to transcript on type (Task 4) ✓; finished-only gating (Task 5) ✓; stable turn id prerequisite (Task 1) ✓; tests (Tasks 1, 2) ✓; docs (Task 6) ✓.
- **Type consistency:** `TranscriptSearch.Match { turnId, location, length, globalIndex }`, `TranscriptSearch.Result { isValid, matches }`, and `TranscriptSearch.Result.empty` are used identically in the engine, tests, and view. `highlightedText`, `recomputeSearch`, `scheduleSearchRecompute`, `gotoNextMatch`, `gotoPrevMatch`, `searchScrollTick`, `matchesByTurn`, `searchResult`, `currentMatchIndex`, `isSearching`, `searchCounterLabel`, `findShortcuts` are defined once (Task 4 / Task 5) and referenced consistently.
- **No live-mode regression:** search modifier is gated by `enabled: !isLive`; `findShortcuts` no-ops `⌘F` when live; live view renders from `liveRichTranscript`, untouched.
