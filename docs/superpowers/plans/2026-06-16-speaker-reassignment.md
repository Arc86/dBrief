# Speaker Reassignment via Known-Name Picker — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the free-text speaker-rename UI in the transcript window with a known-name picker that also reassigns speech to a different speaker, scoped to either the tapped turn or the whole speaker.

**Architecture:** A pure, unit-tested `SpeakerReassignment` helper rewrites `RichSegment.speakerId` over a set of segment IDs (with orphan-label cleanup + `meSpeakerId` transfer). A shared `SpeakerAssignPicker` SwiftUI popover lists known people (existing speakers + participants + calendar attendees) plus an inline "Add someone…" field, then offers a scope step. `TranscriptWindowView`'s turn-card speaker `Menu` opens the picker and applies the result through the existing `saveTranscript` / `recomputeSearch` path.

**Tech Stack:** Swift 6.2, SwiftUI, swift-testing (v0.6.0+). SwiftPM executable target `dBrief`; tests in `Tests/dBriefTests/`.

## Global Constraints

- Platform/toolchain: macOS 14+, Swift 6.2, `swift-tools-version: 6.2`.
- Tests use the **swift-testing** framework (`import Testing`, `@Test`, `#expect`), not XCTest. Run with `swift test`.
- All UI/state types are `@MainActor @Observable`; pure helpers are plain (no `@MainActor`, no I/O).
- `RichTranscript`, `RichSegment`, `SpeakerLabel`, `SpeakerTurn` are `Sendable` value types in `Sources/dBrief/Models/`.
- No data-model/schema change: only existing `RichSegment.speakerId` and `RichTranscript.speakerLabels` are rewritten.
- Persistence via the existing `TranscriptStore` (`.richtranscript.json` sidecar) — reached only through `TranscriptWindowView.saveTranscript(_:)`. Do not add new persistence.
- Logging (if any) uses centralized `Logger` extensions (`Logger.recording` etc.), never ad-hoc `Logger(subsystem:…)`. This feature needs no new logging.
- Commit messages end with the trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Work happens on branch `speaker-reassign` in worktree `../dBrief-speaker-reassign`.

---

### Task 1: `SpeakerReassignment` pure helper — types + `apply`/`segmentCount`

**Files:**
- Create: `Sources/dBrief/Services/SpeakerReassignment.swift`
- Test: `Tests/dBriefTests/SpeakerReassignmentTests.swift`

**Interfaces:**
- Consumes: `RichTranscript`, `RichSegment`, `SpeakerLabel` from `Sources/dBrief/Models/RichTranscript.swift` (in-module, no import needed beyond `Foundation`).
- Produces (relied on by Tasks 2–3):
  - `enum ReassignScope { case theseSegments, allOfSpeaker }`
  - `enum SpeakerChoice: Equatable { case existing(speakerId: String); case new(name: String) }`
  - `struct SpeakerCandidate: Identifiable, Equatable { let id: String; let displayName: String; let existingSpeakerId: String?; let isCurrent: Bool }`
  - `enum SpeakerReassignment` with:
    - `static func apply(_ choice: SpeakerChoice, to transcript: RichTranscript, segmentIds: Set<UUID>, scope: ReassignScope, newId: String) -> RichTranscript`
    - `static func segmentCount(in transcript: RichTranscript, speakerId: String?) -> Int`
    - `static func candidates(in transcript: RichTranscript, currentSpeakerId: String?, participants: [String], calendarAttendees: [String]) -> [SpeakerCandidate]` (implemented in Task 2 — declare with the others but it's fine to add its body here or there; Task 2 owns its tests).

- [ ] **Step 1: Write the failing tests for `apply` + `segmentCount`**

Create `Tests/dBriefTests/SpeakerReassignmentTests.swift`:

```swift
import Foundation
@testable import dBrief
import Testing

struct SpeakerReassignmentTests {
    // Helper: build a transcript with N segments, given (speakerId) per segment.
    private func transcript(
        _ speakers: [String?],
        labels: [SpeakerLabel] = [],
        me: String? = nil
    ) -> RichTranscript {
        let segs = speakers.enumerated().map { i, sp in
            RichSegment(start: Double(i), end: Double(i) + 1,
                        text: "seg\(i)", originalText: "seg\(i)", speakerId: sp)
        }
        return RichTranscript(segments: segs, speakerLabels: labels, meSpeakerId: me)
    }

    @Test("theseSegments rewrites only the given ids")
    func theseSegmentsOnly() {
        let t = transcript(["S1", "S1", "S2"],
                           labels: [SpeakerLabel(id: "S1", displayName: "S1"),
                                    SpeakerLabel(id: "S2", displayName: "S2")])
        let firstId = t.segments[0].id
        let out = SpeakerReassignment.apply(.existing(speakerId: "S2"), to: t,
                                            segmentIds: [firstId], scope: .theseSegments,
                                            newId: "NEW")
        #expect(out.segments[0].speakerId == "S2")
        #expect(out.segments[1].speakerId == "S1")
        #expect(out.segments[2].speakerId == "S2")
    }

    @Test("allOfSpeaker rewrites every segment of the origin speaker")
    func allOfSpeaker() {
        let t = transcript(["S1", "S1", "S2"],
                           labels: [SpeakerLabel(id: "S1", displayName: "S1"),
                                    SpeakerLabel(id: "S2", displayName: "S2")])
        let firstId = t.segments[0].id
        let out = SpeakerReassignment.apply(.existing(speakerId: "S2"), to: t,
                                            segmentIds: [firstId], scope: .allOfSpeaker,
                                            newId: "NEW")
        #expect(out.segments.map(\.speakerId) == ["S2", "S2", "S2"])
    }

    @Test("no-op when target equals origin")
    func noOp() {
        let t = transcript(["S1", "S2"])
        let id0 = t.segments[0].id
        let out = SpeakerReassignment.apply(.existing(speakerId: "S1"), to: t,
                                            segmentIds: [id0], scope: .allOfSpeaker,
                                            newId: "NEW")
        #expect(out.segments.map(\.speakerId) == ["S1", "S2"])
    }

    @Test("full merge removes the orphaned label but keeps the target")
    func orphanCleanup() {
        let t = transcript(["S1", "S2"],
                           labels: [SpeakerLabel(id: "S1", displayName: "Alice"),
                                    SpeakerLabel(id: "S2", displayName: "Bob")])
        let id0 = t.segments[0].id
        let out = SpeakerReassignment.apply(.existing(speakerId: "S2"), to: t,
                                            segmentIds: [id0], scope: .allOfSpeaker,
                                            newId: "NEW")
        #expect(out.speakerLabels.contains { $0.id == "S2" })
        #expect(!out.speakerLabels.contains { $0.id == "S1" })
    }

    @Test("meSpeakerId transfers when its speaker is fully merged away")
    func meTransfer() {
        let t = transcript(["S1", "S2"],
                           labels: [SpeakerLabel(id: "S1", displayName: "Me"),
                                    SpeakerLabel(id: "S2", displayName: "Bob")],
                           me: "S1")
        let id0 = t.segments[0].id
        let out = SpeakerReassignment.apply(.existing(speakerId: "S2"), to: t,
                                            segmentIds: [id0], scope: .allOfSpeaker,
                                            newId: "NEW")
        #expect(out.meSpeakerId == "S2")
    }

    @Test("meSpeakerId untouched when its speaker still has segments")
    func meUntouched() {
        let t = transcript(["S1", "S1", "S2"], me: "S1")
        let id0 = t.segments[0].id
        let out = SpeakerReassignment.apply(.existing(speakerId: "S2"), to: t,
                                            segmentIds: [id0], scope: .theseSegments,
                                            newId: "NEW")
        #expect(out.meSpeakerId == "S1")
    }

    @Test("segmentCount counts segments for a speaker")
    func segmentCount() {
        let t = transcript(["S1", "S1", "S2", nil])
        #expect(SpeakerReassignment.segmentCount(in: t, speakerId: "S1") == 2)
        #expect(SpeakerReassignment.segmentCount(in: t, speakerId: "S2") == 1)
        #expect(SpeakerReassignment.segmentCount(in: t, speakerId: nil) == 0)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ../dBrief-speaker-reassign && swift test --filter SpeakerReassignmentTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'SpeakerReassignment' in scope` (type doesn't exist yet).

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/dBrief/Services/SpeakerReassignment.swift`:

```swift
import Foundation

enum ReassignScope { case theseSegments, allOfSpeaker }

enum SpeakerChoice: Equatable {
    case existing(speakerId: String)
    case new(name: String)
}

struct SpeakerCandidate: Identifiable, Equatable {
    let id: String              // existing speakerId, or "name:"+normalized for a name-only entry
    let displayName: String
    let existingSpeakerId: String?
    let isCurrent: Bool
}

enum SpeakerReassignment {

    static func segmentCount(in transcript: RichTranscript, speakerId: String?) -> Int {
        guard let speakerId else { return 0 }
        return transcript.segments.reduce(0) { $0 + ($1.speakerId == speakerId ? 1 : 0) }
    }

    static func apply(
        _ choice: SpeakerChoice,
        to transcript: RichTranscript,
        segmentIds: Set<UUID>,
        scope: ReassignScope,
        newId: String
    ) -> RichTranscript {
        var out = transcript

        // 1. Resolve target id (and append a label for a genuinely new name).
        let targetId: String
        switch choice {
        case .existing(let id):
            targetId = id
        case .new(let rawName):
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return transcript }
            if let match = out.speakerLabels.first(where: { normalize($0.displayName) == normalize(name) }) {
                targetId = match.id
            } else {
                targetId = newId
                out.speakerLabels.append(SpeakerLabel(id: newId, displayName: name))
            }
        }

        // 2. Origin speaker = speakerId of the first targeted segment (a turn shares one).
        guard let origin = out.segments.first(where: { segmentIds.contains($0.id) })?.speakerId
        else { return transcript }
        if origin == targetId { return transcript }

        // 3. Rewrite.
        for i in out.segments.indices {
            switch scope {
            case .theseSegments:
                if segmentIds.contains(out.segments[i].id) { out.segments[i].speakerId = targetId }
            case .allOfSpeaker:
                if out.segments[i].speakerId == origin { out.segments[i].speakerId = targetId }
            }
        }

        // 4. Orphan-label cleanup (never drop the target's label).
        let live = Set(out.segments.compactMap { $0.speakerId })
        out.speakerLabels.removeAll { $0.id != targetId && !live.contains($0.id) }

        // 5. meSpeakerId transfer if the origin was "me" and is now gone.
        if out.meSpeakerId == origin && !live.contains(origin) {
            out.meSpeakerId = targetId
        }

        return out
    }

    static func candidates(
        in transcript: RichTranscript,
        currentSpeakerId: String?,
        participants: [String],
        calendarAttendees: [String]
    ) -> [SpeakerCandidate] {
        // Implemented in Task 2.
        []
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ../dBrief-speaker-reassign && swift test --filter SpeakerReassignmentTests 2>&1 | tail -20`
Expected: PASS — all 7 tests pass (`candidates` not yet exercised).

- [ ] **Step 5: Commit**

```bash
cd ../dBrief-speaker-reassign
git add Sources/dBrief/Services/SpeakerReassignment.swift Tests/dBriefTests/SpeakerReassignmentTests.swift
git commit -m "feat: SpeakerReassignment.apply + segmentCount with orphan cleanup

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `SpeakerReassignment.candidates`

**Files:**
- Modify: `Sources/dBrief/Services/SpeakerReassignment.swift` (replace the stub `candidates` body)
- Test: `Tests/dBriefTests/SpeakerReassignmentTests.swift` (add tests)

**Interfaces:**
- Consumes: the types from Task 1 (`SpeakerCandidate`, `RichTranscript`).
- Produces: a populated `candidates(...)` used by `TranscriptWindowView` in Task 4.

- [ ] **Step 1: Write the failing tests**

Append to `SpeakerReassignmentTests.swift` inside the struct:

```swift
    @Test("candidates put the current speaker first and flag it")
    func candidatesCurrentFirst() {
        let t = transcript(["S2", "S1"],
                           labels: [SpeakerLabel(id: "S1", displayName: "Alice"),
                                    SpeakerLabel(id: "S2", displayName: "Bob")])
        let cands = SpeakerReassignment.candidates(in: t, currentSpeakerId: "S2",
                                                   participants: [], calendarAttendees: [])
        #expect(cands.first?.existingSpeakerId == "S2")
        #expect(cands.first?.isCurrent == true)
        #expect(cands.count == 2)
        #expect(cands.contains { $0.existingSpeakerId == "S1" && !$0.isCurrent })
    }

    @Test("unlabeled speakers display their raw id")
    func candidatesUnlabeled() {
        let t = transcript(["S1", "S2"])  // no labels
        let cands = SpeakerReassignment.candidates(in: t, currentSpeakerId: "S1",
                                                   participants: [], calendarAttendees: [])
        #expect(cands.contains { $0.existingSpeakerId == "S2" && $0.displayName == "S2" })
    }

    @Test("participant names not yet speakers appear as name-only candidates")
    func candidatesNameOnly() {
        let t = transcript(["S1"], labels: [SpeakerLabel(id: "S1", displayName: "Alice")])
        let cands = SpeakerReassignment.candidates(in: t, currentSpeakerId: "S1",
                                                   participants: ["Carol", "alice"],
                                                   calendarAttendees: ["Carol", "Dave"])
        // "alice" deduped against existing "Alice"; "Carol" deduped across the two lists.
        let nameOnly = cands.filter { $0.existingSpeakerId == nil }
        #expect(nameOnly.map(\.displayName).sorted() == ["Carol", "Dave"])
        #expect(nameOnly.allSatisfy { $0.id.hasPrefix("name:") })
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ../dBrief-speaker-reassign && swift test --filter SpeakerReassignmentTests 2>&1 | tail -20`
Expected: FAIL — the new `candidates*` tests fail (stub returns `[]`).

- [ ] **Step 3: Implement `candidates`**

Replace the stub body in `SpeakerReassignment.candidates`:

```swift
    static func candidates(
        in transcript: RichTranscript,
        currentSpeakerId: String?,
        participants: [String],
        calendarAttendees: [String]
    ) -> [SpeakerCandidate] {
        func label(for id: String) -> String {
            transcript.speakerLabels.first(where: { $0.id == id })?.displayName ?? id
        }

        // Existing speakers in first-appearance order.
        var seenIds: [String] = []
        for seg in transcript.segments {
            if let id = seg.speakerId, !seenIds.contains(id) { seenIds.append(id) }
        }

        var result: [SpeakerCandidate] = seenIds.map { id in
            SpeakerCandidate(id: id, displayName: label(for: id),
                             existingSpeakerId: id, isCurrent: id == currentSpeakerId)
        }
        // Current speaker first.
        result.sort { ($0.isCurrent ? 0 : 1) < ($1.isCurrent ? 0 : 1) }

        // Name-only candidates: names not already an existing speaker's display name.
        var takenNames = Set(result.map { normalize($0.displayName) })
        for name in participants + calendarAttendees {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = normalize(trimmed)
            if takenNames.contains(key) { continue }
            takenNames.insert(key)
            result.append(SpeakerCandidate(id: "name:" + key, displayName: trimmed,
                                           existingSpeakerId: nil, isCurrent: false))
        }
        return result
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ../dBrief-speaker-reassign && swift test --filter SpeakerReassignmentTests 2>&1 | tail -20`
Expected: PASS — all `SpeakerReassignmentTests` pass (10 total).

- [ ] **Step 5: Commit**

```bash
cd ../dBrief-speaker-reassign
git add Sources/dBrief/Services/SpeakerReassignment.swift Tests/dBriefTests/SpeakerReassignmentTests.swift
git commit -m "feat: SpeakerReassignment.candidates (existing speakers + name-only, deduped)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `SpeakerAssignPicker` view

**Files:**
- Create: `Sources/dBrief/UI/SpeakerAssignPicker.swift`

**Interfaces:**
- Consumes: `SpeakerCandidate`, `SpeakerChoice`, `ReassignScope` (Task 1); `TranscriptDesignTokens.speakerColor(for:)` (existing, in `Sources/dBrief/UI/`).
- Produces (used by Task 4):
  ```swift
  struct SpeakerAssignPicker: View {
      let candidates: [SpeakerCandidate]
      let currentDisplayName: String
      let speakerSegmentCount: Int
      let turnSegmentCount: Int
      let onChoose: (SpeakerChoice, ReassignScope) -> Void
      let onCancel: () -> Void
  }
  ```

This task has no unit test (SwiftUI view); it is verified by compiling and by the manual run in Task 5. It is a separate task because it is an independently reviewable, self-contained component.

- [ ] **Step 1: Create the view**

Create `Sources/dBrief/UI/SpeakerAssignPicker.swift`:

```swift
import SwiftUI

/// Popover body for assigning/renaming a transcript speaker. Step 1 picks a person
/// (existing speaker or a typed new name); step 2 (shown only when the speaker has
/// segments beyond this turn) picks the scope.
struct SpeakerAssignPicker: View {
    let candidates: [SpeakerCandidate]
    let currentDisplayName: String
    let speakerSegmentCount: Int
    let turnSegmentCount: Int
    let onChoose: (SpeakerChoice, ReassignScope) -> Void
    let onCancel: () -> Void

    private enum Step: Equatable { case pick, scope }

    @State private var step: Step = .pick
    @State private var pendingChoice: SpeakerChoice?
    @State private var addingNew = false
    @State private var newName = ""

    private var hasSegmentsBeyondTurn: Bool { speakerSegmentCount > turnSegmentCount }
    private var thisScopeLabel: String { turnSegmentCount == 1 ? "This segment" : "This turn" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch step {
            case .pick:  pickStep
            case .scope: scopeStep
            }
        }
        .padding(12)
        .frame(width: 220)
    }

    // MARK: Pick step

    private var pickStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Assign speaker")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ForEach(candidates) { c in
                Button { choose(.existing(speakerId: c.existingSpeakerId ?? ""), candidate: c) } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(TranscriptDesignTokens.speakerColor(for: c.existingSpeakerId))
                            .frame(width: 8, height: 8)
                        Text(c.displayName).font(.system(size: 12))
                        Spacer()
                        if c.isCurrent {
                            Image(systemName: "checkmark").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(c.existingSpeakerId == nil && c.isCurrent)
            }

            Divider()

            if addingNew {
                TextField("Name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { confirmNewName() }
                HStack {
                    Button("Cancel") { addingNew = false; newName = "" }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button("Add") { confirmNewName() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Button { addingNew = true } label: {
                    Label("Add someone…", systemImage: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func choose(_ choice: SpeakerChoice, candidate: SpeakerCandidate) {
        // Picking a name-only candidate routes through .new so it mints/merges by name.
        let resolved: SpeakerChoice
        if candidate.existingSpeakerId == nil { resolved = .new(name: candidate.displayName) }
        else { resolved = choice }

        if candidate.isCurrent { onCancel(); return }   // no-op
        advance(with: resolved)
    }

    private func confirmNewName() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        advance(with: .new(name: name))
    }

    private func advance(with choice: SpeakerChoice) {
        if hasSegmentsBeyondTurn {
            pendingChoice = choice
            step = .scope
        } else {
            onChoose(choice, .allOfSpeaker)
        }
    }

    // MARK: Scope step

    private var scopeStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apply to…").font(.caption.bold()).foregroundStyle(.secondary)
            Button(thisScopeLabel) {
                if let c = pendingChoice { onChoose(c, .theseSegments) }
            }
            .buttonStyle(.bordered).controlSize(.small)
            Button("All \(speakerSegmentCount) from “\(currentDisplayName)”") {
                if let c = pendingChoice { onChoose(c, .allOfSpeaker) }
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            Button("Back") { step = .pick }
                .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd ../dBrief-speaker-reassign && swift build 2>&1 | tail -20`
Expected: build succeeds (no errors). If `TranscriptDesignTokens.speakerColor(for:)` signature differs, match the existing callsite in `TranscriptWindowView.swift` (it accepts `String?`).

- [ ] **Step 3: Commit**

```bash
cd ../dBrief-speaker-reassign
git add Sources/dBrief/UI/SpeakerAssignPicker.swift
git commit -m "feat: SpeakerAssignPicker popover (pick person + scope step)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Wire the picker into `TranscriptWindowView`; remove the rename sheet

**Files:**
- Modify: `Sources/dBrief/UI/TranscriptWindowView.swift`

**Interfaces:**
- Consumes: `SpeakerReassignment` (Tasks 1–2), `SpeakerAssignPicker` (Task 3), existing `saveTranscript(_:)` (~L950), `recomputeSearch()` (~L872), `displayName(for:)` (~L471), `setMeSpeaker(_:)` (~L722), `SpeakerTurn` (`.segments`, `.speakerId`).
- Produces: the live feature. After this task the old free-text rename is gone.

Read the file region first: lines ~50–55 (`@State`), ~190–200 (the rename sheet binding via `IdentifiedString`), ~444–469 (`speakerLabel(id:isMe:)`), ~680–738 (rename popover/`commitSpeakerRename`/`renameSpeaker`). Confirm exact line numbers before editing — they may have shifted.

- [ ] **Step 1: Add the turn-state + remove the old rename state**

Replace the two state vars (currently `@State private var renamingSpeakerId: String?` and `@State private var speakerRenameText = ""`, ~L52–53) with:

```swift
    @State private var assigningTurn: SpeakerTurn?
```

`SpeakerTurn` is `Identifiable` (stable `id`), so it works directly with `.popover(item:)`.

- [ ] **Step 2: Change `speakerLabel` to take the turn and open the picker**

Update the callsite (~L419) from `speakerLabel(id: id, isMe: isMe)` to `speakerLabel(turn: turn, isMe: isMe)`.

Replace the `speakerLabel(id:isMe:)` function (~L444–469) with:

```swift
    private func speakerLabel(turn: SpeakerTurn, isMe: Bool) -> some View {
        let id = turn.speakerId ?? ""
        return Menu {
            Button("Reassign / rename…") { assigningTurn = turn }
            if isMe {
                Button("Clear “This is me”") { setMeSpeaker(nil) }
            } else {
                Button("This is me") { setMeSpeaker(turn.speakerId) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(displayName(for: id))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isMe ? Color.accentColor : TranscriptDesignTokens.speakerColor(for: id))
                if isMe {
                    Text("· You").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .popover(item: $assigningTurn, arrowEdge: .bottom) { turn in
            speakerAssignPicker(for: turn)
        }
    }
```

(Note: the `.popover(item:)` lives on the label so it anchors to the badge. Because each
rendered `speakerLabel` carries the popover but `assigningTurn` is single-valued, only the
tapped one presents — SwiftUI shows the popover whose `item` becomes non-nil. This matches the
existing single-sheet pattern.)

- [ ] **Step 3: Add the picker builder + `assignSpeaker`**

Add these methods near `renameSpeaker` (which you delete in Step 4):

```swift
    @ViewBuilder
    private func speakerAssignPicker(for turn: SpeakerTurn) -> some View {
        let transcript = richTranscript ?? RichTranscript(segments: [])
        // CalendarEvent.attendees: [Person], Person.name: String (Models/CalendarEvent.swift).
        let attendees = recording.calendarCandidates.flatMap { $0.attendees.map(\.name) }
        SpeakerAssignPicker(
            candidates: SpeakerReassignment.candidates(
                in: transcript,
                currentSpeakerId: turn.speakerId,
                participants: recording.participants,
                calendarAttendees: attendees),
            currentDisplayName: displayName(for: turn.speakerId ?? ""),
            speakerSegmentCount: SpeakerReassignment.segmentCount(in: transcript, speakerId: turn.speakerId),
            turnSegmentCount: turn.segments.count,
            onChoose: { choice, scope in assignSpeaker(turn: turn, choice: choice, scope: scope) },
            onCancel: { assigningTurn = nil })
    }

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

(`CalendarEvent.attendees` is `[CalendarEvent.Person]` and `Person.name` is `String` —
confirmed in `Sources/dBrief/Models/CalendarEvent.swift`. `calendarCandidates` is empty after
a recording is reopened, which is acceptable: participants already carry calendar names
post-processing.)

- [ ] **Step 4: Delete the old rename UI**

Remove, in `TranscriptWindowView.swift`:
- the rename `.sheet`/`.popover` block bound via the `IdentifiedString` adapter (~L190–200) that presented the "Rename Speaker" UI;
- `private func commitSpeakerRename(_:)` (~L702–708);
- `private func renameSpeaker(speakerId:displayName:)` (~L729–738);
- the "Rename Speaker" `TextField` popover/sheet body (~L680–700) if it is a standalone function;
- any now-unused `IdentifiedString` helper **only if** it has no other references (`rg -n "IdentifiedString" Sources/`). If referenced elsewhere, leave it.

- [ ] **Step 5: Build and run the full test suite**

Run: `cd ../dBrief-speaker-reassign && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -15`
Expected: build succeeds; all tests pass (no regressions; `SpeakerReassignmentTests` green).

- [ ] **Step 6: Manual smoke test**

Run: `cd ../dBrief-speaker-reassign && make app && open dBrief.app` (or `make run`).
Verify on a finished recording with ≥2 diarized speakers:
1. Click a speaker badge → "Reassign / rename…" → picker lists known speakers + "Add someone…".
2. Pick a different existing speaker on a multi-segment speaker → scope step appears → "This turn" reassigns only that turn; "All N" reassigns the whole speaker.
3. "Add someone…" → type a new name → applied; badge + People list update; persists after closing/reopening the transcript window.
4. Picking the current speaker is a no-op.
Expected: all behave as described; no crash; changes survive reopening (sidecar persisted).

- [ ] **Step 7: Commit**

```bash
cd ../dBrief-speaker-reassign
git add Sources/dBrief/UI/TranscriptWindowView.swift
git commit -m "feat: speaker picker + turn/all reassignment in transcript window

Replaces the free-text rename sheet with SpeakerAssignPicker, applying
choices through SpeakerReassignment and the existing save/search path.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Documentation sync

**Files:**
- Modify: `CLAUDE.md`
- Modify: `site/docs/` (the relevant transcript/diarization page) and `site/docs.js` (NAV) if the rename flow is documented there.

**Interfaces:** none (docs only).

- [ ] **Step 1: Update `CLAUDE.md`**

In the **Speaker Diarization** section, replace the "Post-hoc rename: Clicking a speaker badge … opens a rename popover that updates `SpeakerLabel.displayName`" sentence with a description of the new flow: clicking a speaker badge opens `SpeakerAssignPicker` (known speakers + participants/calendar attendees + "Add someone…"); choosing a different person offers a scope step — **this turn** vs **all of this speaker** — applied by the pure, unit-tested `SpeakerReassignment` (rewrites `RichSegment.speakerId`, cleans orphaned labels, transfers `meSpeakerId`) and persisted via `TranscriptStore`. Note it subsumes free-text rename. In the **Rich Transcript Viewer** section, update any mention of the rename popover similarly.

- [ ] **Step 2: Update the site docs (if present)**

Run: `rg -ln "rename|speaker badge|SpeakerLabel" site/docs 2>/dev/null`. If a page documents the rename flow, update it to describe the picker + scope, and check `site/docs.js` NAV needs no new entry (this is an edit to an existing page, not a new page). If `site/docs` has no such mention, skip — note that in the commit body.

- [ ] **Step 3: Commit**

```bash
cd ../dBrief-speaker-reassign
git add CLAUDE.md site/docs site/docs.js 2>/dev/null; git add CLAUDE.md
git commit -m "docs: describe speaker picker + reassignment flow

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review Notes

- **Spec coverage:** Goal/known-name picker → Tasks 2–4; per-turn vs all-speaker scope → Tasks 1, 3, 4; add-new + collision-merge → Tasks 1, 3; orphan cleanup + `meSpeakerId` transfer → Task 1; single live entry point (turn card) + remove old rename → Task 4; dead `TranscriptSegmentRow`/`SpeakerPillView` left untouched (Non-Goals/Constraints); docs → Task 5. No spec requirement is unaddressed.
- **Placeholder scan:** all code steps contain full code; the only deferred body (`candidates`) is explicitly owned by Task 2 with its real implementation shown there.
- **Type consistency:** `apply`, `segmentCount`, `candidates`, `SpeakerChoice`, `ReassignScope`, `SpeakerCandidate` signatures are identical across Tasks 1–4. `SpeakerAssignPicker`'s init params match the Task 4 callsite exactly.
- **Known verification points (flagged inline, not placeholders):** exact line numbers in `TranscriptWindowView.swift` (Task 4) and the `CalendarEvent` attendee-names property name (Task 4 Step 3) must be confirmed against the code at execution time; both have explicit fallbacks.
