# Transcript Viewer Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the flat-list transcript UI with a premium glass-card aesthetic — frosted surfaces, consistent speaker pills, and merged speaker turns — that adapts automatically to system light/dark mode.

**Architecture:** Add a design-token layer (`TranscriptDesignTokens`) and a reusable `SpeakerPillView` component. Introduce a `SpeakerTurn` model that merges consecutive same-speaker segments, and a `SpeakerTurnCard` view that renders turns using the new tokens. Wire the new components into the existing `TranscriptWindowView`, `TranscriptSidePanel`, `TranscriptPlayerBar`, and `TranscriptChatView` — replacing their backgrounds and speaker representations without changing any data-persistence or AI logic.

**Tech Stack:** Swift 6.2, SwiftUI, macOS 14+, `swift-testing` (already present), `@Environment(\.colorScheme)` for adaptive styling, `Material` API for frosted-glass surfaces.

**Spec:** `docs/superpowers/specs/2026-04-15-transcript-viewer-redesign-design.md`

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `Sources/dBrief/Utilities/Color+Hex.swift` | `Color(hex:)` initializer used by design tokens |
| Create | `Sources/dBrief/UI/TranscriptDesignTokens.swift` | All color, material, spacing, and shadow constants |
| Create | `Sources/dBrief/UI/SpeakerPillView.swift` | Canonical colored-pill speaker badge — used everywhere |
| Create | `Sources/dBrief/Models/SpeakerTurn.swift` | `SpeakerTurn` struct + `RichTranscript.speakerTurns()` |
| Create | `Tests/dBriefTests/SpeakerTurnTests.swift` | Unit tests for merging logic |
| Create | `Sources/dBrief/UI/SpeakerTurnCard.swift` | Glass card view for a single speaker turn |
| Modify | `Sources/dBrief/UI/TranscriptWindowView.swift` | Gradient background, glass toolbar, use `SpeakerTurnCard` |
| Modify | `Sources/dBrief/UI/TranscriptSidePanel.swift` | Glass sidebar, `SpeakerPillView` in People section |
| Modify | `Sources/dBrief/UI/TranscriptPlayerBar.swift` | Frosted-glass bar |
| Modify | `Sources/dBrief/UI/TranscriptChatView.swift` | Command-palette layout with glass input + chip grid |

---

## Task 1: Color hex extension

**Files:**
- Create: `Sources/dBrief/Utilities/Color+Hex.swift`

- [ ] **Step 1: Create the file**

```swift
// Sources/dBrief/Utilities/Color+Hex.swift
import SwiftUI

extension Color {
    /// Initialise from a 6-digit hex string (with or without leading `#`).
    /// Example: `Color(hex: "ff453a")`
    init(hex: String) {
        var hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var rgbValue: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgbValue)
        let r = Double((rgbValue & 0xff0000) >> 16) / 255
        let g = Double((rgbValue & 0x00ff00) >> 8) / 255
        let b = Double(rgbValue & 0x0000ff) / 255
        self.init(red: r, green: g, blue: b)
    }
}
```

- [ ] **Step 2: Verify build**

```bash
swift build 2>&1 | grep -E "error:|warning:" | head -20
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/Utilities/Color+Hex.swift
git commit -m "feat: add Color(hex:) initializer"
```

---

## Task 2: Design tokens

**Files:**
- Create: `Sources/dBrief/UI/TranscriptDesignTokens.swift`

- [ ] **Step 1: Create the file**

```swift
// Sources/dBrief/UI/TranscriptDesignTokens.swift
import SwiftUI

/// All visual constants for the transcript viewer. Use these instead of
/// hard-coded colours or sizes so future surfaces can reuse the same tokens.
enum TranscriptDesignTokens {

    // MARK: - Window background

    static func windowBackground(scheme: ColorScheme) -> LinearGradient {
        let colors: [Color] = scheme == .dark
            ? [Color(hex: "1c1c2e"), Color(hex: "26263a")]
            : [Color(hex: "e8e8ed"), Color(hex: "d8d8e0")]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - Structural surfaces (toolbar, player bar)

    static func structureFill(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.55)
    }

    static func structureBorder(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.08)
    }

    // MARK: - Sidebar

    static func sidebarFill(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.20) : Color.white.opacity(0.35)
    }

    // MARK: - Content cards

    static func cardFill(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.60)
    }

    static func cardBorder(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.white.opacity(0.80)
    }

    static func cardShadowColor(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.25) : Color.black.opacity(0.06)
    }

    static func cardShadowRadius(scheme: ColorScheme) -> CGFloat {
        scheme == .dark ? 6 : 4
    }

    // MARK: - Chip (Chat tab template buttons)

    static func chipFill(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.50)
    }

    static func chipBorder(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    // MARK: - Typography

    static func bodyText(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.88) : Color(hex: "1d1d1f")
    }

    static func timestampText(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.30) : Color.black.opacity(0.35)
    }

    static func sectionLabel(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.30) : Color.black.opacity(0.40)
    }

    static func secondaryText(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.35) : Color.black.opacity(0.50)
    }

    // MARK: - Speaker accent colours

    /// Fixed palette; index assigned round-robin by hashing the speaker ID.
    static let speakerAccents: [Color] = [
        Color(hex: "ff453a"), // red
        Color(hex: "0a84ff"), // blue
        Color(hex: "ff9f0a"), // orange
        Color(hex: "30d158"), // green
        Color(hex: "bf5af2"), // purple
        Color(hex: "5ac8fa"), // teal
    ]

    /// Deterministic colour for a speaker ID. Always returns the same colour
    /// for the same ID within a session.
    static func speakerColor(for speakerId: String?) -> Color {
        guard let id = speakerId, !id.isEmpty else { return speakerAccents[0] }
        let hash = abs(id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) })
        return speakerAccents[hash % speakerAccents.count]
    }

    // MARK: - Shape & spacing

    static let cardCornerRadius: CGFloat = 10
    static let pillCornerRadius: CGFloat = 20
    static let cardGap: CGFloat = 8
    static let scrollPadding: CGFloat = 14
    static let cardPadding = EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13)
}
```

- [ ] **Step 2: Verify build**

```bash
swift build 2>&1 | grep "error:" | head -20
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/UI/TranscriptDesignTokens.swift
git commit -m "feat: add TranscriptDesignTokens for glass UI system"
```

---

## Task 3: SpeakerPillView

**Files:**
- Create: `Sources/dBrief/UI/SpeakerPillView.swift`

- [ ] **Step 1: Create the file**

```swift
// Sources/dBrief/UI/SpeakerPillView.swift
import SwiftUI

/// Canonical speaker badge used in transcript cards, segment headers,
/// and the sidebar People list. Never vary the style — one component everywhere.
struct SpeakerPillView: View {
    let speakerId: String?
    let displayName: String
    /// Optional tap handler. If nil the pill is non-interactive.
    var action: (() -> Void)? = nil

    private var color: Color {
        TranscriptDesignTokens.speakerColor(for: speakerId)
    }

    var body: some View {
        pillLabel
            .ifLet(action) { view, handler in
                Button(action: handler) { view }.buttonStyle(.plain)
            }
    }

    private var pillLabel: some View {
        Text(displayName.uppercased())
            .font(.system(size: 9, weight: .bold))
            .kerning(0.5)
            .foregroundColor(.white)
            .padding(.vertical, 2)
            .padding(.horizontal, 8)
            .background(color)
            .clipShape(Capsule())
    }
}

// MARK: - View helper

private extension View {
    /// Apply a modifier only when an optional value is non-nil.
    @ViewBuilder
    func ifLet<T, Modified: View>(
        _ value: T?,
        transform: (Self, T) -> Modified
    ) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}
```

- [ ] **Step 2: Verify build**

```bash
swift build 2>&1 | grep "error:" | head -20
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/UI/SpeakerPillView.swift
git commit -m "feat: add SpeakerPillView component"
```

---

## Task 4: SpeakerTurn model (TDD)

**Files:**
- Create: `Tests/dBriefTests/SpeakerTurnTests.swift` ← write first
- Create: `Sources/dBrief/Models/SpeakerTurn.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/dBriefTests/SpeakerTurnTests.swift
import Testing
@testable import dBrief

@Suite("SpeakerTurn merging")
struct SpeakerTurnTests {

    // Helper: build a minimal RichSegment without spelling out every default.
    private func seg(
        _ text: String,
        speaker: String?,
        start: Double = 0,
        end: Double = 1
    ) -> RichSegment {
        RichSegment(
            id: .init(),
            start: start,
            end: end,
            text: text,
            originalText: text,
            tokens: [],
            speakerId: speaker,
            isStarred: false,
            isEdited: false
        )
    }

    @Test func emptyTranscriptProducesNoTurns() {
        let t = RichTranscript(version: 1, segments: [], speakerLabels: [])
        #expect(t.speakerTurns().isEmpty)
    }

    @Test func singleSegmentIsOneTurn() {
        let t = RichTranscript(version: 1, segments: [seg("Hello", speaker: "A")], speakerLabels: [])
        let turns = t.speakerTurns()
        #expect(turns.count == 1)
        #expect(turns[0].text == "Hello")
        #expect(turns[0].speakerId == "A")
    }

    @Test func consecutiveSameSpeakerMerged() {
        let t = RichTranscript(version: 1, segments: [
            seg("Hello", speaker: "A", start: 0, end: 1),
            seg("world", speaker: "A", start: 1, end: 2),
        ], speakerLabels: [])
        let turns = t.speakerTurns()
        #expect(turns.count == 1)
        #expect(turns[0].text == "Hello world")
        #expect(turns[0].startTime == 0)
        #expect(turns[0].endTime == 2)
    }

    @Test func differentSpeakersNotMerged() {
        let t = RichTranscript(version: 1, segments: [
            seg("Hi", speaker: "A"),
            seg("Hey", speaker: "B"),
        ], speakerLabels: [])
        #expect(t.speakerTurns().count == 2)
    }

    @Test func alternatingTurnsPreserved() {
        let t = RichTranscript(version: 1, segments: [
            seg("A1", speaker: "A"),
            seg("B1", speaker: "B"),
            seg("A2", speaker: "A"),
        ], speakerLabels: [])
        let turns = t.speakerTurns()
        #expect(turns.count == 3)
        #expect(turns[0].speakerId == "A")
        #expect(turns[1].speakerId == "B")
        #expect(turns[2].speakerId == "A")
        #expect(turns[2].text == "A2")
    }

    @Test func nilSpeakerEachSegmentOwnTurn() {
        let t = RichTranscript(version: 1, segments: [
            seg("one", speaker: nil),
            seg("two", speaker: nil),
        ], speakerLabels: [])
        #expect(t.speakerTurns().count == 2)
    }

    @Test func trailingRunMerged() {
        // Last run must be appended even without a following different speaker.
        let t = RichTranscript(version: 1, segments: [
            seg("A1", speaker: "A"),
            seg("B1", speaker: "B"),
            seg("B2", speaker: "B"),
        ], speakerLabels: [])
        let turns = t.speakerTurns()
        #expect(turns.count == 2)
        #expect(turns[1].text == "B1 B2")
    }

    @Test func turnTimingSpansAllSegments() {
        let t = RichTranscript(version: 1, segments: [
            seg("w1", speaker: "A", start: 5, end: 10),
            seg("w2", speaker: "A", start: 10, end: 15),
            seg("w3", speaker: "A", start: 15, end: 20),
        ], speakerLabels: [])
        let turn = t.speakerTurns()[0]
        #expect(turn.startTime == 5)
        #expect(turn.endTime == 20)
    }
}
```

- [ ] **Step 2: Run tests — expect failure (type doesn't exist yet)**

```bash
swift test --filter SpeakerTurnTests 2>&1 | tail -10
```
Expected: compile error — `SpeakerTurn` and `speakerTurns()` are not defined yet.

- [ ] **Step 3: Create the model**

```swift
// Sources/dBrief/Models/SpeakerTurn.swift
import Foundation

/// A merged run of consecutive `RichSegment`s from the same speaker.
/// Used for display only — the underlying segments are preserved for seeking,
/// editing, and persistence.
struct SpeakerTurn: Identifiable, Sendable {
    let id: UUID
    let speakerId: String?
    let segments: [RichSegment]

    init(speakerId: String?, segments: [RichSegment]) {
        self.id = UUID()
        self.speakerId = speakerId
        self.segments = segments
    }

    /// Playback start time (from first segment).
    var startTime: Double { segments.first?.start ?? 0 }

    /// Playback end time (from last segment).
    var endTime: Double { segments.last?.end ?? 0 }

    /// Full display text — segments joined with a single space.
    var text: String { segments.map(\.text).joined(separator: " ") }
}

extension RichTranscript {
    /// Returns segments merged into speaker turns.
    ///
    /// Consecutive segments that share the same non-nil `speakerId` are combined.
    /// Segments with `speakerId == nil` each become their own turn (no merging).
    func speakerTurns() -> [SpeakerTurn] {
        guard !segments.isEmpty else { return [] }

        var turns: [SpeakerTurn] = []
        var bucket: [RichSegment] = [segments[0]]

        for segment in segments.dropFirst() {
            let canMerge = segment.speakerId != nil
                && segment.speakerId == bucket.last?.speakerId
            if canMerge {
                bucket.append(segment)
            } else {
                turns.append(SpeakerTurn(speakerId: bucket[0].speakerId, segments: bucket))
                bucket = [segment]
            }
        }
        turns.append(SpeakerTurn(speakerId: bucket[0].speakerId, segments: bucket))
        return turns
    }
}
```

- [ ] **Step 4: Run tests — expect all pass**

```bash
swift test --filter SpeakerTurnTests 2>&1 | tail -15
```
Expected: `Test run with 8 tests passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Models/SpeakerTurn.swift Tests/dBriefTests/SpeakerTurnTests.swift
git commit -m "feat: add SpeakerTurn model with speaker-turn merging"
```

---

## Task 5: SpeakerTurnCard view

**Files:**
- Create: `Sources/dBrief/UI/SpeakerTurnCard.swift`

This is the main card component. It renders one `SpeakerTurn` with the glass aesthetic. It does not support inline editing — that's out of scope for this redesign.

- [ ] **Step 1: Create the file**

```swift
// Sources/dBrief/UI/SpeakerTurnCard.swift
import SwiftUI

struct SpeakerTurnCard: View {
    let turn: SpeakerTurn
    let speakerLabels: [SpeakerLabel]
    let isActive: Bool
    let showSpeakerNames: Bool
    let fontSize: Int
    let onSeek: (Double) -> Void
    let onRenameSpeaker: (String, String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var showingSpeakerRename = false
    @State private var speakerRenameText = ""

    private var displayName: String {
        guard let id = turn.speakerId else { return "Speaker" }
        return speakerLabels.first(where: { $0.id == id })?.displayName ?? id
    }

    private var timeRangeLabel: String {
        "\(formatTime(turn.startTime)) – \(formatTime(turn.endTime))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            bodyText
        }
        .padding(TranscriptDesignTokens.cardPadding)
        .background(cardBackground)
        .overlay(cardBorderOverlay)
        .shadow(
            color: TranscriptDesignTokens.cardShadowColor(scheme: colorScheme),
            radius: TranscriptDesignTokens.cardShadowRadius(scheme: colorScheme),
            x: 0,
            y: 1
        )
    }

    // MARK: - Subviews

    private var headerRow: some View {
        HStack(spacing: 6) {
            if showSpeakerNames {
                SpeakerPillView(speakerId: turn.speakerId, displayName: displayName) {
                    speakerRenameText = displayName
                    showingSpeakerRename = true
                }
                .popover(isPresented: $showingSpeakerRename, arrowEdge: .bottom) {
                    speakerRenamePopover
                }
            }
            Text(timeRangeLabel)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(TranscriptDesignTokens.timestampText(scheme: colorScheme))
        }
    }

    private var bodyText: some View {
        Text(turn.text)
            .font(.system(size: CGFloat(fontSize)))
            .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: colorScheme))
            .lineSpacing(CGFloat(fontSize) * 0.65)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onSeek(turn.startTime) }
    }

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: TranscriptDesignTokens.cardCornerRadius)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: TranscriptDesignTokens.cardCornerRadius)
                .fill(TranscriptDesignTokens.cardFill(scheme: colorScheme))
        }
    }

    private var cardBorderOverlay: some View {
        RoundedRectangle(cornerRadius: TranscriptDesignTokens.cardCornerRadius)
            .stroke(
                isActive
                    ? Color.accentColor.opacity(0.55)
                    : TranscriptDesignTokens.cardBorder(scheme: colorScheme),
                lineWidth: 1
            )
    }

    // MARK: - Speaker rename popover

    private var speakerRenamePopover: some View {
        VStack(spacing: 8) {
            Text("Rename Speaker")
                .font(.caption.bold())
            TextField("Name", text: $speakerRenameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .onSubmit { commitRename() }
            HStack {
                Button("Cancel") { showingSpeakerRename = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Save") { commitRename() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
    }

    private func commitRename() {
        let name = speakerRenameText.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, let id = turn.speakerId {
            onRenameSpeaker(id, name)
        }
        showingSpeakerRename = false
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
```

- [ ] **Step 2: Verify build**

```bash
swift build 2>&1 | grep "error:" | head -20
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/UI/SpeakerTurnCard.swift
git commit -m "feat: add SpeakerTurnCard with glass aesthetic"
```

---

## Task 6: Wire TranscriptWindowView

**Files:**
- Modify: `Sources/dBrief/UI/TranscriptWindowView.swift`

Three changes: (1) gradient window background, (2) glass toolbar, (3) replace segment scroll with turn scroll using `SpeakerTurnCard`.

- [ ] **Step 1: Add gradient background to the root VStack**

Locate the `body` property. The outer `VStack(spacing: 0)` (line 47) currently has no background. Add a `ZStack` wrapper so the gradient sits behind everything:

Replace:
```swift
VStack(spacing: 0) {
    toolbar

    Divider()

    HStack(spacing: 0) {
```
With:
```swift
ZStack {
    // Gradient window background
    Group {
        if #available(macOS 14, *) {
            TranscriptDesignTokens.windowBackground(scheme: colorScheme)
                .ignoresSafeArea()
        }
    }

    VStack(spacing: 0) {
        toolbar

        Divider()

        HStack(spacing: 0) {
```

And close the ZStack after the closing brace of `VStack`. Also add `@Environment(\.colorScheme) private var colorScheme` near the other `@Environment` declarations at the top of the struct.

The full body with the wrapper looks like this:

```swift
var body: some View {
    if let recording {
        ZStack {
            Group {
                if #available(macOS 14, *) {
                    TranscriptDesignTokens.windowBackground(scheme: colorScheme)
                        .ignoresSafeArea()
                }
            }

            VStack(spacing: 0) {
                toolbar

                Divider()

                HStack(spacing: 0) {
                    mainContent(for: recording)

                    if showSidePanel, let _ = richTranscript {
                        Divider()
                        sidePanelPane(for: recording)
                    }
                }
            }
        }
        .navigationTitle(recording.generatedTitle ?? recording.meetingTitleDraft)
        .frame(minWidth: 700, minHeight: 500)
        .task(id: recordingId) {
            await loadTranscript(for: recording)
        }
        .onChange(of: viewMode) { _, newMode in
            if newMode == .chat, chatService == nil {
                buildChatService(for: recording)
            }
        }
    } else {
        Text("No recording selected")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

Add to the property declarations:
```swift
@Environment(\.colorScheme) private var colorScheme
```

- [ ] **Step 2: Apply glass styling to the toolbar**

Find the `toolbar` computed property. Replace the `.background(Color(nsColor: .windowBackgroundColor))` line at the end of the `HStack`:

```swift
// Remove this line:
.background(Color(nsColor: .windowBackgroundColor))

// Replace with:
.background(
    TranscriptDesignTokens.structureFill(scheme: colorScheme)
        .background(.ultraThinMaterial)
)
```

Also replace the search field's background. The existing code has two separate modifiers — remove both and replace together:
```swift
// Remove both of these lines:
.background(Color(nsColor: .controlBackgroundColor))
.clipShape(RoundedRectangle(cornerRadius: 6))

// Replace with:
.background {
    ZStack {
        RoundedRectangle(cornerRadius: 6).fill(.ultraThinMaterial)
        RoundedRectangle(cornerRadius: 6).fill(TranscriptDesignTokens.cardFill(scheme: colorScheme))
    }
}
.clipShape(RoundedRectangle(cornerRadius: 6))
```

- [ ] **Step 3: Add displayedTurns computed property**

Add this computed property alongside `displayedSegments`:

```swift
private var displayedTurns: [SpeakerTurn] {
    guard let t = richTranscript else { return [] }
    let turns = t.speakerTurns()
    guard !searchText.isEmpty else { return turns }
    let q = searchText.lowercased()
    return turns.filter { turn in
        turn.text.lowercased().contains(q)
    }
}
```

- [ ] **Step 4: Replace segmentScrollView to use SpeakerTurnCard**

Replace the entire `segmentScrollView` computed property:

```swift
private var segmentScrollView: some View {
    ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: TranscriptDesignTokens.cardGap) {
                ForEach(displayedTurns) { turn in
                    SpeakerTurnCard(
                        turn: turn,
                        speakerLabels: richTranscript?.speakerLabels ?? [],
                        isActive: isTurnActive(turn),
                        showSpeakerNames: showSpeakerNames,
                        fontSize: fontSize,
                        onSeek: { time in seek(to: time, in: recording!) },
                        onRenameSpeaker: { id, name in
                            renameSpeaker(speakerId: id, displayName: name, in: recording!)
                        }
                    )
                    .id(turn.id)
                }

                if displayedTurns.isEmpty && !searchText.isEmpty {
                    Text("No results for \"\(searchText)\"")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(24)
                }
            }
            .padding(TranscriptDesignTokens.scrollPadding)
        }
        .onChange(of: audioPlayer.currentTime) { _, newTime in
            currentTime = newTime
            guard viewMode != .chat,
                  let active = displayedTurns.first(where: { newTime >= $0.startTime && newTime < $0.endTime })
            else { return }
            withAnimation { proxy.scrollTo(active.id, anchor: .center) }
        }
    }
}
```

- [ ] **Step 5: Add isTurnActive helper**

Add alongside `isSegmentActive`:

```swift
private func isTurnActive(_ turn: SpeakerTurn) -> Bool {
    currentTime >= turn.startTime && currentTime < turn.endTime
}
```

- [ ] **Step 6: Verify build**

```bash
swift build 2>&1 | grep "error:" | head -20
```
Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add Sources/dBrief/UI/TranscriptWindowView.swift
git commit -m "feat: wire SpeakerTurnCard and glass background into TranscriptWindowView"
```

---

## Task 7: Redesign TranscriptSidePanel

**Files:**
- Modify: `Sources/dBrief/UI/TranscriptSidePanel.swift`

Two changes: (1) glass sidebar background, (2) replace dot+name rows with `SpeakerPillView`.

- [ ] **Step 1: Add colorScheme environment**

Add at the top of the `TranscriptSidePanel` struct body (alongside the existing `@State` vars):

```swift
@Environment(\.colorScheme) private var colorScheme
```

- [ ] **Step 2: Replace the sidebar background**

Find the `.background(Color(nsColor: .windowBackgroundColor))` modifier on the `ScrollView` and replace it:

```swift
// Remove:
.background(Color(nsColor: .windowBackgroundColor))

// Replace with:
.background(
    TranscriptDesignTokens.sidebarFill(scheme: colorScheme)
        .background(.ultraThinMaterial)
)
```

- [ ] **Step 3: Replace speakerRow with pill-based row**

Replace the entire `speakerRow(for:)` function:

```swift
@ViewBuilder
private func speakerRow(for speakerId: String) -> some View {
    let displayName = speakerDisplayName(for: speakerId)
    let isRenaming = renamingId == speakerId

    HStack(spacing: 8) {
        if isRenaming {
            TextField("Name", text: $renameText, onCommit: { commitRename(speakerId: speakerId) })
                .textFieldStyle(.plain)
                .font(.caption)
                .onKeyPress(.escape) {
                    renamingId = nil
                    return .handled
                }
                .onAppear { renameText = displayName }
        } else {
            SpeakerPillView(speakerId: speakerId, displayName: displayName) {
                renameText = displayName
                renamingId = speakerId
            }
        }

        Spacer()

        if isRenaming {
            Button("Save") { commitRename(speakerId: speakerId) }
                .buttonStyle(.bordered)
                .controlSize(.mini)
        } else {
            Button {
                renameText = displayName
                renamingId = speakerId
            } label: {
                Image(systemName: "pencil")
                    .font(.caption2)
                    .foregroundStyle(TranscriptDesignTokens.secondaryText(scheme: colorScheme))
            }
            .buttonStyle(.plain)
        }
    }
    .padding(.vertical, 6)
}
```

- [ ] **Step 4: Remove the now-unused speakerColor helper**

Delete the `speakerColor(for:)` method in `TranscriptSidePanel` (it used the old dot approach; the color is now handled by `SpeakerPillView` via tokens):

```swift
// Delete this entire method:
private func speakerColor(for speakerId: String) -> Color {
    let palette: [Color] = [.accentColor, .orange, .green, .purple, .pink, .cyan, .yellow, .indigo]
    let hash = abs(speakerId.unicodeScalars.reduce(0) { $0 &+ Int($1.value) })
    return palette[hash % palette.count]
}
```

- [ ] **Step 5: Update section header text color**

In the `sectionHeader` function, change the foreground style to use the token:

```swift
// Remove:
.foregroundStyle(.secondary)

// Replace with:
.foregroundStyle(TranscriptDesignTokens.sectionLabel(scheme: colorScheme))
```

- [ ] **Step 6: Verify build**

```bash
swift build 2>&1 | grep "error:" | head -20
```
Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add Sources/dBrief/UI/TranscriptSidePanel.swift
git commit -m "feat: apply glass styling and SpeakerPillView to TranscriptSidePanel"
```

---

## Task 8: Redesign TranscriptPlayerBar

**Files:**
- Modify: `Sources/dBrief/UI/TranscriptPlayerBar.swift`

Add the frosted-glass bar background. The player bar is currently rendered inline in `mainContent` with manual padding. The bar itself has no background — callers give it padding. We add the glass background inside the bar's own `body`.

- [ ] **Step 1: Add colorScheme environment**

Add inside `TranscriptPlayerBar`:

```swift
@Environment(\.colorScheme) private var colorScheme
```

- [ ] **Step 2: Replace the entire body with the glass version**

The current `body` is a bare `HStack` with a `.task` modifier. Replace the whole `body` property:

```swift
var body: some View {
    HStack(spacing: 10) {
        Button {
            audioPlayer.togglePlayPause(url: audioURL)
        } label: {
            Image(systemName: isThisFile && audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 20)
        }
        .buttonStyle(.borderless)

        Text(formatTime(displayTime))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(TranscriptDesignTokens.secondaryText(scheme: colorScheme))
            .frame(width: 40, alignment: .trailing)

        WaveformView(
            samples: waveformSamples,
            playbackFraction: playbackFraction,
            onSeek: { fraction in
                let seekTime = (isThisFile ? audioPlayer.duration : 0) * fraction
                if isThisFile { audioPlayer.seek(to: seekTime) }
                currentTime = seekTime
            }
        )
        .frame(height: 36)

        Text(formatTime(isThisFile ? audioPlayer.duration : 0))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(TranscriptDesignTokens.secondaryText(scheme: colorScheme))
            .frame(width: 40, alignment: .leading)

        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0] as [Float], id: \.self) { speed in
                Button(speedLabel(speed)) { audioPlayer.setRate(speed) }
            }
        } label: {
            Text(speedLabel(audioPlayer.playbackRate))
                .font(.caption2.monospacedDigit())
                .frame(width: 30)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
        TranscriptDesignTokens.structureFill(scheme: colorScheme)
            .background(.ultraThinMaterial)
    )
    .overlay(alignment: .top) {
        Rectangle()
            .fill(TranscriptDesignTokens.structureBorder(scheme: colorScheme))
            .frame(height: 1)
    }
    .task {
        guard waveformSamples.isEmpty else { return }
        waveformSamples = await WaveformGenerator.generate(from: audioURL)
    }
}
```

The padding is now owned by `TranscriptPlayerBar` itself. Remove the padding the caller previously added. In `TranscriptWindowView.mainContent`, find:

```swift
TranscriptPlayerBar(audioURL: audioURL, currentTime: $currentTime)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
```

Replace with:

```swift
TranscriptPlayerBar(audioURL: audioURL, currentTime: $currentTime)
```

- [ ] **Step 3: Verify build**

```bash
swift build 2>&1 | grep "error:" | head -20
```
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/dBrief/UI/TranscriptPlayerBar.swift Sources/dBrief/UI/TranscriptWindowView.swift
git commit -m "feat: apply frosted-glass styling to TranscriptPlayerBar"
```

---

## Task 9: Redesign TranscriptChatView

**Files:**
- Modify: `Sources/dBrief/UI/TranscriptChatView.swift`

Command-palette layout: when there are no messages, show a prominent input field at the top followed by a chip grid of template prompts. When there are messages, keep the existing conversation + bottom input layout but apply glass styling to the input bar.

- [ ] **Step 1: Add colorScheme environment**

Add inside `TranscriptChatView`:

```swift
@Environment(\.colorScheme) private var colorScheme
```

- [ ] **Step 2: Replace promptTemplates with command-palette layout**

Replace the entire `promptTemplates` computed property:

```swift
private var promptTemplates: some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            // Prominent input at top
            HStack(spacing: 8) {
                Text("✦")
                    .font(.system(size: 13))
                    .foregroundStyle(TranscriptDesignTokens.secondaryText(scheme: colorScheme))
                TextField("Ask anything about this transcript…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .lineLimit(1...4)
                    .onSubmit { submitMessage() }
                Button { submitMessage() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(
                            inputText.trimmingCharacters(in: .whitespaces).isEmpty
                                ? TranscriptDesignTokens.secondaryText(scheme: colorScheme)
                                : Color.accentColor
                        )
                }
                .buttonStyle(.plain)
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: TranscriptDesignTokens.cardCornerRadius)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: TranscriptDesignTokens.cardCornerRadius)
                        .fill(TranscriptDesignTokens.cardFill(scheme: colorScheme))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: TranscriptDesignTokens.cardCornerRadius)
                    .stroke(TranscriptDesignTokens.cardBorder(scheme: colorScheme), lineWidth: 1)
            )
            .padding(.horizontal, 14)
            .padding(.top, 14)

            // Section label
            Text("QUICK TEMPLATES")
                .font(.system(size: 9, weight: .bold))
                .kerning(0.5)
                .foregroundStyle(TranscriptDesignTokens.sectionLabel(scheme: colorScheme))
                .padding(.horizontal, 14)
                .padding(.top, 4)

            // Chip grid
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 110), spacing: 6)],
                spacing: 6
            ) {
                ForEach(ChatPromptTemplate.defaults) { template in
                    Button {
                        inputText = template.prompt
                        submitMessage()
                    } label: {
                        Text(template.title)
                            .font(.system(size: 11))
                            .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: colorScheme))
                            .padding(.vertical, 5)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity)
                            .background(
                                Capsule()
                                    .fill(TranscriptDesignTokens.chipFill(scheme: colorScheme))
                                    .background(.ultraThinMaterial, in: Capsule())
                            )
                            .overlay(
                                Capsule()
                                    .stroke(TranscriptDesignTokens.chipBorder(scheme: colorScheme), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }
}
```

- [ ] **Step 3: Apply glass styling to the inputBar**

Replace the `inputBar` computed property:

```swift
private var inputBar: some View {
    HStack(spacing: 8) {
        if !chatService.messages.isEmpty {
            Button {
                chatService.clearMessages()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(TranscriptDesignTokens.secondaryText(scheme: colorScheme))
            }
            .buttonStyle(.borderless)
            .help("Clear chat")
        }

        TextField("Ask about this transcript…", text: $inputText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.callout)
            .lineLimit(1...4)
            .onSubmit { submitMessage() }

        Button {
            submitMessage()
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.title3)
                .foregroundStyle(
                    inputText.trimmingCharacters(in: .whitespaces).isEmpty || chatService.isStreaming
                        ? TranscriptDesignTokens.secondaryText(scheme: colorScheme)
                        : Color.accentColor
                )
        }
        .buttonStyle(.plain)
        .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || chatService.isStreaming)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
        TranscriptDesignTokens.structureFill(scheme: colorScheme)
            .background(.ultraThinMaterial)
    )
    .overlay(alignment: .top) {
        Rectangle()
            .fill(TranscriptDesignTokens.structureBorder(scheme: colorScheme))
            .frame(height: 1)
    }
}
```

Also remove the `Divider()` that was above `inputBar` in the main `body` (line `Divider()` between message list and input bar) — the glass bar's top border overlay replaces it:

```swift
// Remove this line from body:
Divider()

inputBar
```

Replace with just:

```swift
inputBar
```

- [ ] **Step 4: Verify build**

```bash
swift build 2>&1 | grep "error:" | head -20
```
Expected: no errors.

- [ ] **Step 5: Run all tests to verify nothing regressed**

```bash
swift test 2>&1 | tail -10
```
Expected: all existing tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/dBrief/UI/TranscriptChatView.swift
git commit -m "feat: command-palette layout and glass styling for TranscriptChatView"
```

---

## Task 10: Full build + smoke test

- [ ] **Step 1: Clean build**

```bash
swift build -c release 2>&1 | grep -E "error:|Build complete"
```
Expected: `Build complete!`

- [ ] **Step 2: Run full test suite**

```bash
swift test 2>&1 | tail -15
```
Expected: all tests pass with no failures.

- [ ] **Step 3: Launch the app and verify visually**

```bash
make run
```

Open any recording's transcript. Verify:
- Window background shows the cool gradient (not plain white/dark)
- Toolbar has a frosted glass look
- Transcript and Segments tabs show merged speaker-turn cards with pill badges
- Clicking the pill opens the rename popover
- Clicking text in a card seeks the audio
- Sidebar People section shows the same pill style as the cards
- Player bar is frosted glass, no double-padding
- Chat tab shows the command-palette layout (input at top, chips below) in empty state
- Chat conversation layout is unchanged once messages are sent
- Toggle system dark/light mode — all surfaces adapt automatically

- [ ] **Step 4: Final commit**

```bash
git add -p   # review any unstaged changes
git commit -m "feat: transcript viewer premium glass redesign complete"
```
