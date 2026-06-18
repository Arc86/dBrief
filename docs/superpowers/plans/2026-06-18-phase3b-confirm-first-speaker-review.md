# Phase 3b — Confirm-First Speaker Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in "confirm-first" speaker-identification mode that pauses the processing pipeline after diarization+resolution and lets the user accept/correct each speaker (with a playable audio snippet) in a dedicated review window before names commit to the AI analysis, markdown, and integrations.

**Architecture:** A new `AppSettings.speakerIdMode` flag gates the behavior. When set to `.confirmFirst` and there is something to resolve, `RecordingManager.processRecording` builds the rich transcript as today, then **holds** instead of running AI: it stashes a `SpeakerReviewSession` on `AppState` and surfaces a dedicated `speaker-review` window. The window's **Confirm** applies names + enrolls confirmed voiceprints and calls a continuation (`runAnalysisAndExport`) extracted from today's Steps 2–4; **Cancel** runs the same continuation with the resolver's own names. The hold is session-only.

**Tech Stack:** Swift 6.2, SPM, SwiftUI (`@Observable`, `MenuBarExtra`/`Window` scenes), swift-testing. No new dependencies. Reuses `VoiceMatch`, `SpeakerReassignment`, `VoiceLibraryStore`, `AudioPlayer`.

## Global Constraints

- Swift 6.2 / macOS 14+. `swift-tools-version: 6.2`. Tests use swift-testing; run `swift test`.
- All UI/state classes are `@MainActor @Observable`; services that do async work are `actor`s. Models are `Sendable` structs/enums.
- **Opt-in & backward compatible:** default mode is `.optimistic`; optimistic behavior must be byte-for-byte unchanged. Absent UserDefaults key → `.optimistic`.
- **Never strand a recording:** Cancel/close of the review window must always resume the pipeline.
- **Best-effort enrollment:** a missing embedding never blocks a confirm.
- **Session-only hold:** no new persisted pipeline state; a quit mid-hold just leaves the (already-saved) transcript un-analyzed.
- Logging uses the centralized `Logger` extensions (e.g. `Logger.transcription`), not ad-hoc `Logger(subsystem:category:)`.
- Voiceprints stay strictly local (Application Support), never uploaded.
- Spec: `docs/superpowers/specs/2026-06-18-phase3b-confirm-first-speaker-review-design.md`.

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `Sources/dBrief/App/AppSettings.swift` | `SpeakerIdMode` enum, `speakerIdMode` property, key + init load | Modify |
| `Sources/dBrief/UI/SettingsTranscriptionTab.swift` | Mode picker under the diarization toggle | Modify |
| `Sources/dBrief/Services/SpeakerReviewGate.swift` | Pure: decide whether to hold | Create |
| `Sources/dBrief/Services/SpeakerSnippet.swift` | Pure: pick a representative audio range per speaker | Create |
| `Sources/dBrief/Services/SpeakerReviewCandidates.swift` | Pure: rank library people for a cluster (display chips) | Create |
| `Sources/dBrief/Models/SpeakerReviewSession.swift` | Held-pipeline state (`SpeakerReviewSession`, `ConfirmedSpeaker`, `SpeakerReviewItem`) | Create |
| `Sources/dBrief/App/AppState.swift` | `pendingSpeakerReview` property | Modify |
| `Sources/dBrief/Services/RecordingManager.swift` | Extract `runAnalysisAndExport`; hold branch; `finishReview`/`cancelReview` | Modify |
| `Sources/dBrief/Services/AudioPlayer.swift` | `playRange(url:from:to:)` bounded playback | Modify |
| `Sources/dBrief/UI/SpeakerReviewView.swift` | The review window UI | Create |
| `Sources/dBrief/App/DBriefApp.swift` | `Window("Confirm Speakers", id: "speaker-review")`; auto-open onChange | Modify |
| `Sources/dBrief/UI/TranscriptionProgressView.swift` | "Review speakers" button while held | Modify |
| `Tests/dBriefTests/SpeakerReviewGateTests.swift` | Gate truth table | Create |
| `Tests/dBriefTests/SpeakerSnippetTests.swift` | Snippet selection | Create |
| `Tests/dBriefTests/SpeakerReviewCandidatesTests.swift` | Candidate ranking | Create |
| `Tests/dBriefTests/SpeakerIdModeTests.swift` | Enum raw-value/default | Create |

---

### Task 1: `SpeakerIdMode` setting + Transcription-tab picker

**Files:**
- Modify: `Sources/dBrief/App/AppSettings.swift` (enum near `TranscriptionEngine` ~l.182; `Keys` ~l.27; property near `transcriptionEngine` ~l.262; init load near l.843)
- Modify: `Sources/dBrief/UI/SettingsTranscriptionTab.swift` (diarization toggle at l.296)
- Test: `Tests/dBriefTests/SpeakerIdModeTests.swift`

**Interfaces:**
- Produces: `AppSettings.SpeakerIdMode` (`enum: String, CaseIterable, Codable, Hashable, Sendable { case optimistic, confirmFirst }`) with `var displayName: String` and `var shortDescription: String`; `AppSettings.speakerIdMode: SpeakerIdMode` (default `.optimistic`).

- [ ] **Step 1: Write the failing test**

Create `Tests/dBriefTests/SpeakerIdModeTests.swift`:
```swift
import Testing
@testable import dBrief

struct SpeakerIdModeTests {
    @Test("Raw values are stable for persistence")
    func rawValues() {
        #expect(AppSettings.SpeakerIdMode.optimistic.rawValue == "optimistic")
        #expect(AppSettings.SpeakerIdMode.confirmFirst.rawValue == "confirmFirst")
        #expect(AppSettings.SpeakerIdMode(rawValue: "confirmFirst") == .confirmFirst)
    }

    @Test("Both modes have non-empty display copy")
    func displayCopy() {
        for mode in AppSettings.SpeakerIdMode.allCases {
            #expect(!mode.displayName.isEmpty)
            #expect(!mode.shortDescription.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpeakerIdModeTests`
Expected: FAIL (compile error — `SpeakerIdMode` undefined).

- [ ] **Step 3: Add the enum** to `AppSettings.swift` (place beside `TranscriptionEngine`, inside `AppSettings`):
```swift
    /// How diarized speakers get their identities.
    enum SpeakerIdMode: String, CaseIterable, Codable, Hashable, Sendable {
        case optimistic    // auto-label confident matches, run straight through (default)
        case confirmFirst  // hold before AI; review speaker IDs first

        var displayName: String {
            switch self {
            case .optimistic: return "Optimistic"
            case .confirmFirst: return "Confirm first"
            }
        }

        var shortDescription: String {
            switch self {
            case .optimistic: return "Auto-label matched voices and keep processing."
            case .confirmFirst: return "Pause to review speaker names before analysis."
            }
        }
    }
```

- [ ] **Step 4: Add the storage key** in the `Keys` enum (near l.27):
```swift
        static let speakerIdMode = "speakerIdMode"
```

- [ ] **Step 5: Add the property** (beside `transcriptionEngine`, ~l.262):
```swift
    var speakerIdMode: SpeakerIdMode {
        didSet { UserDefaults.standard.set(speakerIdMode.rawValue, forKey: Keys.speakerIdMode) }
    }
```

- [ ] **Step 6: Load in init** (place beside the `transcriptionEngine` load block ~l.845). Lenient — absent/garbage → `.optimistic`:
```swift
        self.speakerIdMode = defaults.string(forKey: Keys.speakerIdMode)
            .flatMap(SpeakerIdMode.init(rawValue:)) ?? .optimistic
```
> Note: a stored property must be assigned before the property's `didSet` is meaningful; assign it in `init` with the other property loads. If `AppSettings.init` uses `self.x = …` direct assignment for others (it does — see `transcriptionEngine`), follow that style.

- [ ] **Step 7: Run test to verify it passes**

Run: `swift test --filter SpeakerIdModeTests`
Expected: PASS.

- [ ] **Step 8: Add the picker** to `SettingsTranscriptionTab.swift`, immediately after the diarization toggle (the one at l.296 with "Identify different speakers"). It is only meaningful when diarization is on:
```swift
                if settings.diarizationEnabled {
                    Picker(selection: $settings.speakerIdMode) {
                        ForEach(AppSettings.SpeakerIdMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("When a voice is recognized")
                            Text(settings.speakerIdMode.shortDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .pickerStyle(.menu)
                }
```
> `settings` is the `@Bindable`/`@Environment(AppSettings.self)` already used by surrounding toggles in this file — match the local variable name actually in scope (it is `settings`).

- [ ] **Step 9: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 10: Commit**
```bash
git add Sources/dBrief/App/AppSettings.swift Sources/dBrief/UI/SettingsTranscriptionTab.swift Tests/dBriefTests/SpeakerIdModeTests.swift
git commit -m "feat: AppSettings.speakerIdMode (optimistic | confirmFirst) + Transcription-tab picker"
```

---

### Task 2: `SpeakerReviewGate` — pure hold predicate

**Files:**
- Create: `Sources/dBrief/Services/SpeakerReviewGate.swift`
- Test: `Tests/dBriefTests/SpeakerReviewGateTests.swift`

**Interfaces:**
- Consumes: `AppSettings.SpeakerIdMode` (Task 1).
- Produces: `enum SpeakerReviewGate { static func shouldHold(mode: AppSettings.SpeakerIdMode, speakerCount: Int, libraryCount: Int) -> Bool }`.

- [ ] **Step 1: Write the failing test**

Create `Tests/dBriefTests/SpeakerReviewGateTests.swift`:
```swift
import Testing
@testable import dBrief

struct SpeakerReviewGateTests {
    @Test("Optimistic never holds")
    func optimisticNeverHolds() {
        #expect(SpeakerReviewGate.shouldHold(mode: .optimistic, speakerCount: 5, libraryCount: 9) == false)
    }

    @Test("Confirm-first holds with >=2 speakers even with empty library")
    func holdsOnMultipleSpeakers() {
        #expect(SpeakerReviewGate.shouldHold(mode: .confirmFirst, speakerCount: 2, libraryCount: 0) == true)
    }

    @Test("Confirm-first holds with a non-empty library even with 1 speaker")
    func holdsOnLibrary() {
        #expect(SpeakerReviewGate.shouldHold(mode: .confirmFirst, speakerCount: 1, libraryCount: 1) == true)
    }

    @Test("Confirm-first does NOT hold for a solo speaker with empty library")
    func soloEmptyLibraryNoHold() {
        #expect(SpeakerReviewGate.shouldHold(mode: .confirmFirst, speakerCount: 1, libraryCount: 0) == false)
        #expect(SpeakerReviewGate.shouldHold(mode: .confirmFirst, speakerCount: 0, libraryCount: 0) == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpeakerReviewGateTests`
Expected: FAIL (compile error — `SpeakerReviewGate` undefined).

- [ ] **Step 3: Implement**

Create `Sources/dBrief/Services/SpeakerReviewGate.swift`:
```swift
import Foundation

/// Pure decision: should confirm-first pause the pipeline for this recording?
/// Holds only when the mode is `.confirmFirst` AND there is something to resolve
/// — at least two diarized speakers, or a non-empty voice library to match against.
/// Solo memos with no library skip the hold.
enum SpeakerReviewGate {
    static func shouldHold(mode: AppSettings.SpeakerIdMode, speakerCount: Int, libraryCount: Int) -> Bool {
        mode == .confirmFirst && (speakerCount >= 2 || libraryCount > 0)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpeakerReviewGateTests`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add Sources/dBrief/Services/SpeakerReviewGate.swift Tests/dBriefTests/SpeakerReviewGateTests.swift
git commit -m "feat: SpeakerReviewGate pure hold predicate"
```

---

### Task 3: `SpeakerSnippet` — pure representative-range picker

**Files:**
- Create: `Sources/dBrief/Services/SpeakerSnippet.swift`
- Test: `Tests/dBriefTests/SpeakerSnippetTests.swift`

**Interfaces:**
- Consumes: `RichTranscript`/`RichSegment` (`Models/RichTranscript.swift`: `segments: [RichSegment]`, each with `start: Double`, `end: Double`, `speakerId: String?`).
- Produces: `enum SpeakerSnippet { static func representative(for speakerId: String, in transcript: RichTranscript, maxLength: Double = 6) -> (start: Double, end: Double)? }` — the longest turn for `speakerId`, capped to `maxLength` seconds from its start; `nil` when the speaker has no segment.

- [ ] **Step 1: Write the failing test**

Create `Tests/dBriefTests/SpeakerSnippetTests.swift`:
```swift
import Testing
@testable import dBrief

private func seg(_ start: Double, _ end: Double, _ speaker: String) -> RichSegment {
    RichSegment(start: start, end: end, text: "", originalText: "", speakerId: speaker)
}

struct SpeakerSnippetTests {
    @Test("Picks the longest turn for the speaker")
    func longestTurn() {
        let t = RichTranscript(segments: [
            seg(0, 1, "A"),       // 1s
            seg(2, 9, "B"),       // 7s (B's longest)
            seg(10, 12, "A"),     // 2s (A's longest)
            seg(13, 14, "B"),     // 1s
        ])
        let a = SpeakerSnippet.representative(for: "A", in: t)
        #expect(a?.start == 10 && a?.end == 12)
    }

    @Test("Caps the snippet to maxLength from the turn start")
    func capsLength() {
        let t = RichTranscript(segments: [seg(5, 30, "B")]) // 25s turn
        let r = SpeakerSnippet.representative(for: "B", in: t, maxLength: 6)
        #expect(r?.start == 5 && r?.end == 11)
    }

    @Test("Nil when the speaker has no segment")
    func noSegment() {
        let t = RichTranscript(segments: [seg(0, 1, "A")])
        #expect(SpeakerSnippet.representative(for: "Z", in: t) == nil)
    }
}
```
> `RichSegment` has defaulted `id`/`tokens`/`isStarred`/`isEdited` (see `Models/RichTranscript.swift`), so the `seg(...)` initializer above compiles with only the listed fields. If the memberwise init requires more, pass the defaults explicitly.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpeakerSnippetTests`
Expected: FAIL (compile error — `SpeakerSnippet` undefined).

- [ ] **Step 3: Implement**

Create `Sources/dBrief/Services/SpeakerSnippet.swift`:
```swift
import Foundation

/// Pure: choose a short, representative audio range for a diarized speaker so the
/// confirm-first review window can play a sample of that voice. Picks the speaker's
/// single longest turn (most likely clean, contiguous speech) and caps it to
/// `maxLength` seconds from its start.
enum SpeakerSnippet {
    static func representative(for speakerId: String, in transcript: RichTranscript, maxLength: Double = 6) -> (start: Double, end: Double)? {
        let longest = transcript.segments
            .filter { $0.speakerId == speakerId && $0.end > $0.start }
            .max { ($0.end - $0.start) < ($1.end - $1.start) }
        guard let s = longest else { return nil }
        let end = min(s.end, s.start + maxLength)
        return (s.start, end)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpeakerSnippetTests`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add Sources/dBrief/Services/SpeakerSnippet.swift Tests/dBriefTests/SpeakerSnippetTests.swift
git commit -m "feat: SpeakerSnippet representative-range picker"
```

---

### Task 4: `SpeakerReviewCandidates` — pure candidate ranking

**Files:**
- Create: `Sources/dBrief/Services/SpeakerReviewCandidates.swift`
- Test: `Tests/dBriefTests/SpeakerReviewCandidatesTests.swift`

**Interfaces:**
- Consumes: `VoiceLibrary`/`KnownPerson`/`Voiceprint` (`Models/VoiceLibrary.swift`: `people: [KnownPerson]`, each `id: String`, `name: String`, `voiceprints: [Voiceprint]` with `embedding: [Float]`), `VoiceMatch.cosineSimilarity`.
- Produces: `enum SpeakerReviewCandidates { static func topMatches(clusterEmbedding: [Float], library: VoiceLibrary, k: Int = 3) -> [Candidate] }` where `struct Candidate: Equatable { let name: String; let personId: String; let score: Float }`. Score = max cosine over the person's voiceprints; sorted descending; at most `k`; empty when the cluster embedding or library is empty.

- [ ] **Step 1: Write the failing test**

Create `Tests/dBriefTests/SpeakerReviewCandidatesTests.swift`:
```swift
import Testing
import Foundation
@testable import dBrief

private func person(_ id: String, _ name: String, _ embeddings: [[Float]]) -> KnownPerson {
    KnownPerson(id: id, name: name,
                voiceprints: embeddings.map { Voiceprint(embedding: $0, model: "t", capturedAt: Date(timeIntervalSince1970: 0)) })
}

struct SpeakerReviewCandidatesTests {
    @Test("Ranks people by best cosine, descending, capped to k")
    func ranking() {
        let lib = VoiceLibrary(people: [
            person("amy", "Amy", [[1, 0]]),          // cosine 1.0 with [1,0]
            person("bob", "Bob", [[0, 1]]),          // cosine 0.0
            person("cleo", "Cleo", [[1, 1], [0.9, 0.1]]), // best ~0.996
        ])
        let out = SpeakerReviewCandidates.topMatches(clusterEmbedding: [1, 0], library: lib, k: 2)
        #expect(out.count == 2)
        #expect(out[0].personId == "amy")
        #expect(out[1].personId == "cleo")
        #expect(out[0].score >= out[1].score)
    }

    @Test("Empty cluster embedding or empty library -> no candidates")
    func emptyInputs() {
        let lib = VoiceLibrary(people: [person("amy", "Amy", [[1, 0]])])
        #expect(SpeakerReviewCandidates.topMatches(clusterEmbedding: [], library: lib).isEmpty)
        #expect(SpeakerReviewCandidates.topMatches(clusterEmbedding: [1, 0], library: VoiceLibrary()).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpeakerReviewCandidatesTests`
Expected: FAIL (compile error — `SpeakerReviewCandidates` undefined).

- [ ] **Step 3: Implement**

Create `Sources/dBrief/Services/SpeakerReviewCandidates.swift`:
```swift
import Foundation

/// Pure: rank known people by voiceprint similarity to a diarized cluster, for the
/// confirm-first review window's suggestion chips. Mirrors the resolver's per-person
/// scoring (max cosine over a person's prints) but returns the ranked list for display
/// rather than a single decision — so the resolver itself stays untouched.
enum SpeakerReviewCandidates {
    struct Candidate: Equatable {
        let name: String
        let personId: String
        let score: Float
    }

    static func topMatches(clusterEmbedding: [Float], library: VoiceLibrary, k: Int = 3) -> [Candidate] {
        guard !clusterEmbedding.isEmpty, !library.people.isEmpty else { return [] }
        return library.people
            .map { p in
                let best = p.voiceprints.reduce(Float(-1)) {
                    max($0, VoiceMatch.cosineSimilarity(clusterEmbedding, $1.embedding))
                }
                return Candidate(name: p.name, personId: p.id, score: best)
            }
            .sorted { $0.score > $1.score }
            .prefix(k)
            .map { $0 }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpeakerReviewCandidatesTests`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add Sources/dBrief/Services/SpeakerReviewCandidates.swift Tests/dBriefTests/SpeakerReviewCandidatesTests.swift
git commit -m "feat: SpeakerReviewCandidates pure candidate ranking"
```

---

### Task 5: `SpeakerReviewSession` model + `AppState.pendingSpeakerReview`

**Files:**
- Create: `Sources/dBrief/Models/SpeakerReviewSession.swift`
- Modify: `Sources/dBrief/App/AppState.swift` (add property near `currentRecording` ~l.17)

**Interfaces:**
- Consumes: `Recording` (`final class`, `Models/Recording.swift`), `RichTranscript`, `VoiceIdentityResolver.Decision`.
- Produces:
  - `struct SpeakerReviewItem: Identifiable` — one card's input: `id` = speakerId, `proposedName: String`, `reason: VoiceIdentityResolver.Reason`, `confidence: Float`, `personId: String?`, `clusterEmbedding: [Float]`, `snippet: (start: Double, end: Double)?`.
  - `struct ConfirmedSpeaker: Equatable { let name: String; let personId: String? }`.
  - `@MainActor final class SpeakerReviewSession: Identifiable` holding `let id = UUID()`, `let recording: Recording`, `let masterAudioURL: URL?`, `var items: [SpeakerReviewItem]`, and the captured processing flags `let summary/actionItems/tags: Bool` plus `let localAIAvailable: Bool`. (Built by `RecordingManager` in Task 6; consumed by the view in Task 7.)
- Produces: `AppState.pendingSpeakerReview: SpeakerReviewSession?` (nil when not holding).

- [ ] **Step 1: Create the model**

Create `Sources/dBrief/Models/SpeakerReviewSession.swift`:
```swift
import Foundation

/// One speaker card in the confirm-first review window.
struct SpeakerReviewItem: Identifiable, Equatable {
    var id: String                 // diarization speaker id
    var proposedName: String       // matched name, or the raw "Speaker N"
    var reason: VoiceIdentityResolver.Reason
    var confidence: Float
    var personId: String?          // library link when the proposal came from a match
    var clusterEmbedding: [Float]  // for live candidate chips
    var snippet: (start: Double, end: Double)?  // representative audio range

    static func == (lhs: SpeakerReviewItem, rhs: SpeakerReviewItem) -> Bool {
        lhs.id == rhs.id && lhs.proposedName == rhs.proposedName
            && lhs.reason == rhs.reason && lhs.personId == rhs.personId
    }
}

/// A user's confirmed identity for one speaker (output of the review window).
struct ConfirmedSpeaker: Equatable {
    let name: String
    let personId: String?
}

/// The held-pipeline state for a recording paused awaiting speaker confirmation.
/// Session-only: never persisted; cleared on confirm/cancel.
@MainActor
final class SpeakerReviewSession: Identifiable {
    let id = UUID()
    let recording: Recording
    let masterAudioURL: URL?
    var items: [SpeakerReviewItem]
    // Captured so the continuation runs with the same options the user chose.
    let summary: Bool
    let actionItems: Bool
    let tags: Bool
    let localAIAvailable: Bool

    init(recording: Recording, masterAudioURL: URL?, items: [SpeakerReviewItem],
         summary: Bool, actionItems: Bool, tags: Bool, localAIAvailable: Bool) {
        self.recording = recording
        self.masterAudioURL = masterAudioURL
        self.items = items
        self.summary = summary
        self.actionItems = actionItems
        self.tags = tags
        self.localAIAvailable = localAIAvailable
    }
}
```
> `VoiceIdentityResolver.Reason` is `Equatable, Sendable` (existing). The custom `==` on `SpeakerReviewItem` avoids needing `(Double, Double)?` tuple equatability synthesis.

- [ ] **Step 2: Add the AppState property** (near `currentRecording`, ~l.17 of `App/AppState.swift`):
```swift
    /// Non-nil while a recording is paused for confirm-first speaker review.
    var pendingSpeakerReview: SpeakerReviewSession?
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 4: Commit**
```bash
git add Sources/dBrief/Models/SpeakerReviewSession.swift Sources/dBrief/App/AppState.swift
git commit -m "feat: SpeakerReviewSession hold-state model + AppState.pendingSpeakerReview"
```

---

### Task 6: RecordingManager — extract continuation, hold branch, finish/cancel

**Files:**
- Modify: `Sources/dBrief/Services/RecordingManager.swift`

**Interfaces:**
- Consumes: `SpeakerReviewGate.shouldHold` (Task 2), `SpeakerSnippet.representative` (Task 3), `SpeakerReviewSession`/`SpeakerReviewItem`/`ConfirmedSpeaker` (Task 5), existing `VoiceIdentityResolver.resolve`, `richTranscriptBuilder.build`, `SpeakerReassignment.rename`, `enrollVoiceprintOnRename`, `voiceLibraryStore.upsert`, `transcriptStore.save`.
- Produces:
  - `private func runAnalysisAndExport(recording: Recording, summary: Bool, actionItems: Bool, tags: Bool, localAIAvailable: Bool) async` — today's Steps 2 (AI) → 3 (title+markdown) → 4 (integrations) → completion, verbatim.
  - `func finishReview(confirmed: [String: ConfirmedSpeaker]) async` — apply names, enroll, resume.
  - `func cancelReview() async` — resume with resolver names.

**Background:** Today `processRecording` (l.338) runs: finalize → Step 1 transcription (incl. resolve+build+auto-enroll, l.460–510) → Step 2 AI (l.519) → Step 3 markdown (l.611) → Step 4 integrations (l.693) → `recordingState = .idle` (l.718). `localAIAvailable` is captured at the top (l.346). The hold must occur after the rich transcript is built (l.500) and before Step 2.

- [ ] **Step 1: Extract `runAnalysisAndExport`.** Cut the block from the start of `// Step 2: AI tasks` (l.519) through the completion/notification lines ending at the current end of `processRecording` (the `recordingState = .idle` at l.718 and the failed-count summary/notification that follows it) into a new private method. It must reference only: `recording`, `summary`, `actionItems`, `tags`, `localAIAvailable`, and `self`/`appState`/`appSettings` (all already in scope as before). Signature:
```swift
    /// Steps 2–4 of processing (AI analysis → title+markdown → integration dispatch)
    /// plus completion. Extracted so confirm-first can run it after the user confirms
    /// speaker names, and the optimistic path can call it inline. Behavior unchanged.
    private func runAnalysisAndExport(
        recording: Recording,
        summary: Bool,
        actionItems: Bool,
        tags: Bool,
        localAIAvailable: Bool
    ) async {
        // <moved Step 2 / Step 3 / Step 4 / completion body, verbatim>
    }
```
> Mechanical move. Do not change the moved code. The `guard !Task.isCancelled else { return }` lines stay with their steps.

- [ ] **Step 2: Call the continuation inline for the optimistic path.** At the bottom of `processRecording`, where Step 2 used to begin, replace the removed body with the hold decision + call. Insert this **after** the Step 1 transcription `do/catch` block ends (after l.517) and before where Step 2 was:
```swift
        // Confirm-first gate: pause before AI when there is something to review.
        if let session = appState.pendingSpeakerReview, session.recording === recording {
            // Hold was armed inside Step 1 (below); stop here. The review window's
            // Confirm/Cancel resumes via finishReview / cancelReview.
            return
        }

        await runAnalysisAndExport(
            recording: recording,
            summary: summary,
            actionItems: actionItems,
            tags: tags,
            localAIAvailable: localAIAvailable
        )
```

- [ ] **Step 3: Arm the hold inside Step 1, replacing the unconditional auto-enroll.** In the Step 1 `do` block, the current code (l.502–510) auto-enrolls named speakers right after `transcriptStore.save(rich, …)`. Replace that auto-enroll block with a hold decision: if `shouldHold`, build the session (deferring enrollment to confirm) and skip auto-enroll; else keep the existing auto-enroll. Use the already-in-scope `result` (TranscriptionResult), `rich` (RichTranscript), `resolved`, `library`, and the full `decisions` dict. **Note:** today only `.matched` decisions are kept (l.474–478); you must also retain the full `decisions` dict. Capture it:
```swift
                        // (existing) inside `if let embeddings = ..., hasLibrary {`
                        let decisions = VoiceIdentityResolver.resolve(
                            clusterEmbeddings: embeddings, library: library, roster: roster)
                        // ... existing `for (sid, d) in decisions where d.reason == .matched { ... }`
                        // ... existing logging ...
                        allDecisions = decisions   // NEW: hoist for the hold (see below)
```
Declare `var allDecisions: [String: VoiceIdentityResolver.Decision] = [:]` just before the `if let embeddings …` block (alongside `resolved`), so it's visible after it.

Then replace the auto-enroll block (l.502–510) with:
```swift
                    // Confirm-first: pause here instead of auto-enrolling + running AI,
                    // when there is something to review. Otherwise behave exactly as before.
                    let speakerCount = Set(rich.segments.compactMap { $0.speakerId }).count
                    let shouldHold = SpeakerReviewGate.shouldHold(
                        mode: appSettings.speakerIdMode,
                        speakerCount: speakerCount,
                        libraryCount: library.people.count)

                    if shouldHold {
                        let embeddings = result.speakerEmbeddings ?? [:]
                        let items: [SpeakerReviewItem] = rich.speakerLabels.map { label in
                            let d = allDecisions[label.id]
                            return SpeakerReviewItem(
                                id: label.id,
                                proposedName: label.displayName,
                                reason: d?.reason ?? .noEmbedding,
                                confidence: d?.confidence ?? 0,
                                personId: label.personId,
                                clusterEmbedding: embeddings[label.id] ?? [],
                                snippet: SpeakerSnippet.representative(for: label.id, in: rich))
                        }.sorted { $0.id < $1.id }
                        appState.pendingSpeakerReview = SpeakerReviewSession(
                            recording: recording,
                            masterAudioURL: recording.finalizedAudioURL,
                            items: items,
                            summary: summary, actionItems: actionItems, tags: tags,
                            localAIAvailable: localAIAvailable)
                        appState.recordingStatusNote = "Waiting for speaker confirmation"
                        sendReviewReadyNotification()   // Step 5
                        Logger.transcription.info("Confirm-first: holding \(items.count) speaker(s) for review")
                    } else {
                        // (existing optimistic auto-enroll — unchanged)
                        if let embeddings = result.speakerEmbeddings, !embeddings.isEmpty {
                            for entry in VoiceEnrollment.enrollable(speakerLabels: rich.speakerLabels, embeddings: embeddings) {
                                await voiceLibraryStore.upsert(
                                    name: entry.name,
                                    voiceprint: Voiceprint(embedding: entry.embedding, model: "fluidaudio-wespeaker-256", capturedAt: Date()))
                            }
                        }
                    }
```
> `recording.finalizedAudioURL` is the master M4A path the player uses (confirm the exact property name in `Recording.swift`; it is the finalized audio URL set by the finalizer — if named differently, use that). The Step 2 gate added in Step 2 (`if let session = appState.pendingSpeakerReview, session.recording === recording { return }`) then stops the pipeline.

- [ ] **Step 4: Implement `finishReview` and `cancelReview`.** Add to `RecordingManager`:
```swift
    /// Confirm-first: the user accepted/corrected speaker names. Apply them to the
    /// rich transcript, enroll the named speakers' voiceprints, then resume the
    /// held pipeline (AI → markdown → integrations).
    func finishReview(confirmed: [String: ConfirmedSpeaker]) async {
        guard let session = appState.pendingSpeakerReview else { return }
        let recording = session.recording
        appState.pendingSpeakerReview = nil
        appState.recordingStatusNote = nil

        if var transcript = recording.richTranscript ?? (try? await transcriptStore.load(for: recording)) {
            for (speakerId, c) in confirmed {
                let name = c.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                transcript = SpeakerReassignment.rename(transcript, speakerId: speakerId, to: name, personId: c.personId)
            }
            recording.richTranscript = transcript
            try? await transcriptStore.save(transcript, for: recording)
            // Enroll confirmed, named speakers (best-effort, deduped by upsert).
            for (speakerId, c) in confirmed {
                let name = c.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name != speakerId else { continue }
                _ = await enrollVoiceprintOnRename(recording: recording, speakerId: speakerId, name: name)
            }
        }

        await runAnalysisAndExport(
            recording: recording,
            summary: session.summary, actionItems: session.actionItems,
            tags: session.tags, localAIAvailable: session.localAIAvailable)
    }

    /// Confirm-first: the user cancelled/closed the review. Keep the resolver's own
    /// names (the rich transcript is already built) and resume so nothing is stranded.
    func cancelReview() async {
        guard let session = appState.pendingSpeakerReview else { return }
        appState.pendingSpeakerReview = nil
        appState.recordingStatusNote = nil
        await runAnalysisAndExport(
            recording: session.recording,
            summary: session.summary, actionItems: session.actionItems,
            tags: session.tags, localAIAvailable: session.localAIAvailable)
    }
```
> `name != speakerId` skips the case where the user left a card as its raw "Speaker N" (no real identity to enroll). `SpeakerReassignment.rename` already handles name-swaps between speakers.

- [ ] **Step 5: Add the review-ready notification.** Mirror `sendCompletionNotification` (l.2165):
```swift
    private func sendReviewReadyNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Confirm speakers"
        content.body = "Review who's who to finish processing this recording."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
```

- [ ] **Step 6: Build**

Run: `swift build`
Expected: builds clean. (If `runAnalysisAndExport`'s moved body references a local that was declared earlier in `processRecording` and not passed in, pass it as a parameter — but per the audit it needs only the five listed.)

- [ ] **Step 7: Run the full test suite (regression)**

Run: `swift test`
Expected: all existing tests pass (no behavior change for optimistic mode).

- [ ] **Step 8: Commit**
```bash
git add Sources/dBrief/Services/RecordingManager.swift
git commit -m "feat: confirm-first pipeline hold — extract continuation, finishReview/cancelReview"
```

---

### Task 7: Review window UI + bounded playback + triggers

**Files:**
- Modify: `Sources/dBrief/Services/AudioPlayer.swift` (add `playRange`)
- Create: `Sources/dBrief/UI/SpeakerReviewView.swift`
- Modify: `Sources/dBrief/App/DBriefApp.swift` (register `speaker-review` Window; auto-open onChange in `MenuBarView`)
- Modify: `Sources/dBrief/UI/TranscriptionProgressView.swift` ("Review speakers" button while held)

**Interfaces:**
- Consumes: `appState.pendingSpeakerReview` (Task 5), `SpeakerReviewCandidates.topMatches` (Task 4), `recordingManager.finishReview/cancelReview` (Task 6), `AudioPlayer`.
- Produces: `AudioPlayer.playRange(url:from:to:)`; `SpeakerReviewView`; `Window(id: "speaker-review")`.

- [ ] **Step 1: Add bounded playback to `AudioPlayer`.** Add a stored `endLimit` and stop at it. In `AudioPlayer.swift`:
```swift
    private var endLimit: TimeInterval?

    /// Plays `url` from `from`, automatically pausing at `to`. Used by the speaker
    /// review window to preview a single speaker's representative turn.
    func playRange(url: URL, from: TimeInterval, to: TimeInterval) {
        play(url: url)
        seek(to: from)
        endLimit = to
    }
```
Then in the timer tick that updates `currentTime` (`startTimer`, ~l.88), after `currentTime` is updated, add:
```swift
        if let limit = endLimit, currentTime >= limit {
            pause()
            endLimit = nil
        }
```
And clear it in `stop()` and `pause()` (set `endLimit = nil` in `stop()`; leave `pause()` as is since the tick already nils it). Confirm `play(url:)`/`seek(to:)` are synchronous enough that seeking right after play works (they are — `AVAudioPlayer` is loaded synchronously in `play`).

- [ ] **Step 2: Create `SpeakerReviewView`.** A card per `SpeakerReviewItem` with an editable name, reason/confidence badge, candidate chips, and a play button; footer Confirm/Cancel.

Create `Sources/dBrief/UI/SpeakerReviewView.swift`:
```swift
import SwiftUI

struct SpeakerReviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(\.dismiss) private var dismiss

    /// Edited name + resolved personId per speaker id, seeded from the session.
    @State private var edits: [String: ConfirmedSpeaker] = [:]
    @State private var library = VoiceLibrary()

    var body: some View {
        Group {
            if let session = appState.pendingSpeakerReview {
                content(session)
            } else {
                // Nothing to review (already confirmed/cancelled) — close.
                Color.clear.onAppear { dismiss() }
            }
        }
        .frame(minWidth: 460, minHeight: 360)
    }

    private func content(_ session: SpeakerReviewSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Confirm speakers")
                .font(.title2).bold()
                .padding([.horizontal, .top])
            Text("Check who's who before the summary and exports are generated.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(session.items) { item in
                        card(item, session: session)
                    }
                }
                .padding()
            }

            Divider()
            HStack {
                Button("Cancel") {
                    Task { await recordingManager.cancelReview() }
                    dismiss()
                }
                Spacer()
                Button("Confirm") {
                    Task { await recordingManager.finishReview(confirmed: edits) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .task {
            // Seed edits from the proposed names, and load the library for chips.
            if edits.isEmpty {
                for item in session.items {
                    edits[item.id] = ConfirmedSpeaker(name: item.proposedName, personId: item.personId)
                }
            }
            library = await recordingManager.loadVoiceLibrary()
        }
    }

    private func card(_ item: SpeakerReviewItem, session: SpeakerReviewSession) -> some View {
        let binding = Binding(
            get: { edits[item.id]?.name ?? item.proposedName },
            set: { edits[item.id] = ConfirmedSpeaker(name: $0, personId: edits[item.id]?.personId) }
        )
        let candidates = SpeakerReviewCandidates.topMatches(
            clusterEmbedding: item.clusterEmbedding, library: library)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Speaker name", text: binding)
                    .textFieldStyle(.roundedBorder)
                if let snippet = item.snippet, let url = session.masterAudioURL {
                    Button {
                        audioPlayer.playRange(url: url, from: snippet.start, to: snippet.end)
                    } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.borderless)
                    .help("Play a sample of this voice")
                }
            }
            Text(reasonBadge(item))
                .font(.caption).foregroundStyle(.secondary)
            if !candidates.isEmpty {
                HStack {
                    ForEach(candidates, id: \.personId) { c in
                        Button(c.name) {
                            edits[item.id] = ConfirmedSpeaker(name: c.name, personId: c.personId)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func reasonBadge(_ item: SpeakerReviewItem) -> String {
        switch item.reason {
        case .matched: return "Matched · \(String(format: "%.2f", item.confidence))"
        case .belowThreshold: return "No confident match"
        case .lowMargin: return "Ambiguous match"
        case .offRoster: return "Off the expected roster"
        case .lostContention: return "Claimed by another speaker"
        case .noEmbedding: return "No voice sample"
        case .emptyLibrary: return "No known voices yet"
        }
    }
}
```
> This needs one small RM accessor: `func loadVoiceLibrary() async -> VoiceLibrary { await voiceLibraryStore.load() }`. Add it to `RecordingManager` in this task (it's a UI read; keep it on RM next to the store). If a public accessor already exists, use it.

- [ ] **Step 3: Add `loadVoiceLibrary()` to RecordingManager** (if not already present):
```swift
    /// Read-only access to the voice library for review UI (candidate chips).
    func loadVoiceLibrary() async -> VoiceLibrary { await voiceLibraryStore.load() }
```

- [ ] **Step 4: Register the window scene** in `DBriefApp.swift`, after the `"transcript"` Window (l.255):
```swift
        Window("Confirm Speakers", id: "speaker-review") {
            SpeakerReviewView()
                .environment(context)
                .environment(context.appState)
                .environment(context.appSettings)
                .environment(context.audioPlayer)
                .environment(context.recordingManager)
        }
        .defaultSize(width: 500, height: 440)
        .windowResizability(.contentSize)
```

- [ ] **Step 5: Auto-open the window when a hold begins.** In `MenuBarView` (`DBriefApp.swift`, has `@Environment(\.openWindow) var openWindow` at l.272), add to the root `VStack` (e.g. on `body`'s top container):
```swift
        .onChange(of: appState.pendingSpeakerReview?.id) { _, newValue in
            if newValue != nil { openWindow(id: "speaker-review") }
        }
```
> Best-effort auto-open (fires when the menu is visible). The guaranteed manual path is Step 6.

- [ ] **Step 6: Add a "Review speakers" button** in `TranscriptionProgressView.swift` (it has `@Environment(\.openWindow)` at l.7). Near the existing action buttons (~l.115–131, by the "Live Transcript" button), add:
```swift
                    if appState.pendingSpeakerReview != nil {
                        Button {
                            openWindow(id: "speaker-review")
                        } label: {
                            Label("Review speakers", systemImage: "person.crop.circle.badge.questionmark")
                        }
                    }
```
> `appState` is already in scope in this view (it reads `appState.processingSteps`).

- [ ] **Step 7: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 8: Build the app bundle and run the manual check**

Run: `make app`
Then manually verify:
1. **Confirm-first happy path:** Settings → AI & Models → Transcription → set "When a voice is recognized" to **Confirm first** (diarization on). Record/import a 2-speaker clip with ≥1 library member. After transcription, the pipeline holds: the "Confirm Speakers" window opens (or "Review speakers" appears in progress), each card shows a reason badge, ▶ plays that speaker's snippet, candidate chips populate. Edit/confirm names → **Confirm** → AI/markdown reflect the confirmed names; `library.json` gains the confirmed voiceprints.
2. **Cancel path:** trigger a hold, click **Cancel** (or close the window) → pipeline resumes with the resolver's own names; recording completes (never stranded).
3. **Optimistic regression:** set mode back to **Optimistic** → record the same clip → no hold, processes straight through exactly as before.
4. **No-hold cases:** confirm-first + a solo voice memo (1 speaker) with an empty library → no hold. Diarization off → no hold.

Record results in the implementation report.

- [ ] **Step 9: Commit**
```bash
git add Sources/dBrief/Services/AudioPlayer.swift Sources/dBrief/UI/SpeakerReviewView.swift Sources/dBrief/App/DBriefApp.swift Sources/dBrief/UI/TranscriptionProgressView.swift Sources/dBrief/Services/RecordingManager.swift
git commit -m "feat: confirm-first speaker review window + bounded snippet playback + triggers"
```

---

## Self-Review

**Spec coverage:**
- Setting `speakerIdMode = .optimistic | .confirmFirst` → Task 1. ✓
- Hold trigger (`≥2 speakers OR library non-empty`, confirm-first only) → Task 2 (`SpeakerReviewGate`), wired in Task 6 Step 3. ✓
- Pipeline split + session hold before AI; Confirm resumes, Cancel proceeds optimistically → Task 5 (session model) + Task 6 (`runAnalysisAndExport`, hold branch, `finishReview`/`cancelReview`). ✓
- Dedicated review window, all speakers (matched + unmatched), reason/confidence badge, candidate chips, per-speaker audio snippet → Task 4 (candidates), Task 3 (snippet), Task 7 (view + `playRange`). ✓
- Enrollment deferred to Confirm in confirm-first; optimistic auto-enroll unchanged → Task 6 Step 3 (`else` branch keeps auto-enroll) + Step 4 (`finishReview` enrolls). ✓
- Session-only (no persistence); never strand → Task 6 (`cancelReview` always resumes; no disk state). ✓
- Out of scope: "this is me" toggle, cross-restart resume, profile override, wrong-enroll pruning → not implemented (matches spec). ✓
- Triggers/notification (auto-open + manual button + notification) → Task 7 Steps 5–6 + Task 6 Step 5. ✓

**Placeholder scan:** No TBD/TODO/"handle errors" placeholders; every code step shows code. Manual-check steps enumerate concrete actions. ✓

**Type consistency:**
- `SpeakerIdMode` used identically in Tasks 1, 2, 6. ✓
- `SpeakerReviewItem`/`ConfirmedSpeaker`/`SpeakerReviewSession` defined in Task 5; consumed with matching field names in Tasks 6 (build) and 7 (read). ✓
- `SpeakerReviewCandidates.Candidate{name, personId, score}` (Task 4) consumed via `c.name`/`c.personId` in Task 7. ✓
- `SpeakerSnippet.representative(for:in:maxLength:) -> (start, end)?` (Task 3) consumed in Task 6 Step 3 and rendered in Task 7. ✓
- `finishReview(confirmed: [String: ConfirmedSpeaker])` / `cancelReview()` (Task 6) called in Task 7. ✓
- `AudioPlayer.playRange(url:from:to:)` (Task 7 Step 1) called in Task 7 Step 2. ✓

**Verification points flagged for the implementer (confirm exact names in code, fix if they differ):**
- `Recording.finalizedAudioURL` — the master audio URL property (Task 6 Step 3, Task 7). The transcript player bar already plays the master; use whatever property it reads.
- `SettingsTranscriptionTab` local binding variable name (`settings` per the surrounding toggles) (Task 1 Step 8).
- `AudioPlayer.startTimer` is where `currentTime` is updated (Task 7 Step 1).
- The exact end line of `processRecording` for the `runAnalysisAndExport` cut (Task 6 Step 1) — include the completion + failed-count notification block.

## Notes / risks
- **Auto-open reliability:** `openWindow` from `MenuBarView.onChange` only fires when the menu popover is rendered. The "Review speakers" button in `TranscriptionProgressView` + the local notification are the guaranteed paths. Tap-to-open from the notification is a future nicety (needs a `UNUserNotificationCenterDelegate`) — out of scope.
- **`recordingState` stays `.processing` during the hold** so a second recording can't start mid-review; closing/cancelling the window always resumes and returns to `.idle`. The window's empty-state `onAppear { dismiss() }` guards against a stale window after confirm/cancel.
- **Snippet length 6 s / top-3 chips** are defaults; tune in `SpeakerSnippet.representative`'s `maxLength` and `SpeakerReviewCandidates.topMatches`'s `k`.
```
