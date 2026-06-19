# Cross-Part Speaker Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Long (>30 min, segmented) recordings keep their speaker labels, voice embeddings, and speaker count by reconciling each part's independently-diarized speakers into one global speaker space.

**Architecture:** A new pure `SegmentSpeakerReconciler` (app target) folds per-part local speaker ids into global ids via greedy one-to-one voiceprint cosine matching. `RecordingManager.transcribeSegmentedAudio` / `mergeSegmentTranscriptions` then forward the remapped `segment.speaker` + `word.speaker`, the merged `speakerEmbeddings`, and `speakerCount` — the three fields the current merge silently drops.

**Tech Stack:** Swift 6.2, SPM. swift-testing (`Testing`) for tests. Reuses `VoiceMatch.cosineSimilarity` and `dBriefWire.TranscriptionResult`.

## Global Constraints

- Pure helper goes in the **app target**: `Sources/dBrief/Services/` (it reuses `VoiceMatch`, which is app-target, not `dBriefWire`). No wire/protocol/helper-process/persistence changes.
- Reconciliation runs on **un-offset** per-part segments; the time offset stays applied by `mergeSegmentTranscriptions`. Reconciliation touches speaker ids only, so it is offset-independent.
- Global ids are the strings `"Speaker 1"`, `"Speaker 2"`, … assigned in (part order, then local-id sort order). Deterministic; no `Date.now`/randomness in the helper.
- `matchThreshold = 0.5` (named constant). Accept a cross-part match at cosine `≥ 0.5`.
- Do **not** match against the persisted voice library here — `VoiceIdentityResolver` owns that downstream.
- Empty results surface as `nil`: no embeddings → `speakerEmbeddings == nil`; zero global speakers → `speakerCount == nil`.
- Tests use swift-testing: `import Testing`, `@testable import dBrief`, `@Suite`/`@Test`/`#expect`. Run with `swift test`.
- `TranscriptionResult.Segment` fields: `start: Double`, `end: Double`, `text: String`, `words: [Word]?`, `speaker: String?`. `Word` fields: `word`, `start`, `end`, `probability: Double?`, `speaker: String?`.

---

## File Structure

- **Create** `Sources/dBrief/Services/SegmentSpeakerReconciler.swift` — the pure reconciler (Task 1).
- **Create** `Tests/dBriefTests/SegmentSpeakerReconcilerTests.swift` — unit tests for the reconciler (Task 1).
- **Modify** `Sources/dBrief/Services/RecordingManager.swift`:
  - `SegmentTranscriptionPiece` (line ~2582) — add `speakerEmbeddings` field (Task 2).
  - `transcribeSegmentedAudio` (line ~2098) — populate the new field per part; assemble final result from reconciler output (Task 2).
  - `mergeSegmentTranscriptions` (line ~2588) — call the reconciler, remap segment + word speakers, forward embeddings + count (Task 2).
- **Modify** `Tests/dBriefTests/WhisperPipelineTests.swift` (or wherever `mergeSegmentTranscriptions` is already exercised) — add an integration test that speakers/embeddings/count survive the merge (Task 2).

---

## Task 1: `SegmentSpeakerReconciler` pure helper + unit tests

**Files:**
- Create: `Sources/dBrief/Services/SegmentSpeakerReconciler.swift`
- Test: `Tests/dBriefTests/SegmentSpeakerReconcilerTests.swift`

**Interfaces:**
- Consumes: `VoiceMatch.cosineSimilarity(_:_:) -> Float`; `dBriefWire.TranscriptionResult.Segment`.
- Produces:
  ```swift
  enum SegmentSpeakerReconciler {
      struct Part {
          let segments: [TranscriptionResult.Segment]   // local speaker ids, un-offset
          let speakerEmbeddings: [String: [Float]]?     // local speakerId → vector
          init(segments: [TranscriptionResult.Segment], speakerEmbeddings: [String: [Float]]?)
      }
      struct Result {
          let remaps: [[String: String]]                // one localId→globalId map per input part
          let speakerEmbeddings: [String: [Float]]      // globalId → mean vector (only embedded globals)
          let speakerCount: Int                         // number of global speakers (0 if none)
      }
      static let matchThreshold: Float                  // 0.5
      static func reconcile(_ parts: [Part]) -> Result
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `Tests/dBriefTests/SegmentSpeakerReconcilerTests.swift`:

```swift
import Foundation
import Testing
@testable import dBrief
import dBriefWire

@Suite("SegmentSpeakerReconciler.reconcile")
struct SegmentSpeakerReconcilerTests {

    // Build a part from (speaker, embedding) pairs; one 1-second segment per speaker.
    private func part(_ speakers: [(id: String, vec: [Float]?)]) -> SegmentSpeakerReconciler.Part {
        var segs: [TranscriptionResult.Segment] = []
        var emb: [String: [Float]] = [:]
        for (i, s) in speakers.enumerated() {
            segs.append(.init(start: Double(i), end: Double(i) + 1, text: "hi", words: nil, speaker: s.id))
            if let v = s.vec { emb[s.id] = v }
        }
        return .init(segments: segs, speakerEmbeddings: emb.isEmpty ? nil : emb)
    }

    @Test("Same speaker across two parts merges to one global")
    func sameSpeakerMerges() {
        let p1 = part([("Speaker 1", [1, 0])])
        let p2 = part([("Speaker 1", [0.98, 0.20])]) // cosine ~0.98 ≥ 0.5
        let r = SegmentSpeakerReconciler.reconcile([p1, p2])
        #expect(r.speakerCount == 1)
        #expect(r.remaps[0]["Speaker 1"] == "Speaker 1")
        #expect(r.remaps[1]["Speaker 1"] == "Speaker 1")
        // global embedding is the mean of the two contributing vectors
        let g = r.speakerEmbeddings["Speaker 1"]
        #expect(g?.count == 2)
        #expect(abs((g?[0] ?? 0) - 0.99) < 1e-5)
        #expect(abs((g?[1] ?? 0) - 0.10) < 1e-5)
    }

    @Test("Different speakers across two parts stay distinct")
    func differentSpeakersStayDistinct() {
        let p1 = part([("Speaker 1", [1, 0])])
        let p2 = part([("Speaker 1", [0, 1])]) // cosine 0 < 0.5 → new global
        let r = SegmentSpeakerReconciler.reconcile([p1, p2])
        #expect(r.speakerCount == 2)
        #expect(r.remaps[0]["Speaker 1"] == "Speaker 1")
        #expect(r.remaps[1]["Speaker 1"] == "Speaker 2")
    }

    @Test("Two real people across three parts, one absent from the middle part")
    func threePartsTwoPeople() {
        let alice: [Float] = [1, 0]
        let bob: [Float] = [0, 1]
        let p1 = part([("Speaker 1", alice), ("Speaker 2", bob)])
        let p2 = part([("Speaker 1", bob)])                 // only Bob speaks
        let p3 = part([("Speaker 1", alice)])               // Alice returns
        let r = SegmentSpeakerReconciler.reconcile([p1, p2, p3])
        #expect(r.speakerCount == 2)
        let aliceGlobal = r.remaps[0]["Speaker 1"]          // Alice's global id
        let bobGlobal = r.remaps[0]["Speaker 2"]            // Bob's global id
        #expect(r.remaps[1]["Speaker 1"] == bobGlobal)      // part 2 → Bob
        #expect(r.remaps[2]["Speaker 1"] == aliceGlobal)    // part 3 → Alice
    }

    @Test("A part missing embeddings yields distinct globals, never a mislabel")
    func missingEmbeddingsNamespaces() {
        let p1 = part([("Speaker 1", [1, 0])])
        let p2 = part([("Speaker 1", nil)])                 // no embedding → cannot match
        let r = SegmentSpeakerReconciler.reconcile([p1, p2])
        #expect(r.speakerCount == 2)
        #expect(r.remaps[1]["Speaker 1"] == "Speaker 2")
    }

    @Test("No diarization (nil speakers) → empty remaps, no embeddings, zero count")
    func noDiarizationPassThrough() {
        let segs: [TranscriptionResult.Segment] = [.init(start: 0, end: 1, text: "hi", words: nil, speaker: nil)]
        let p = SegmentSpeakerReconciler.Part(segments: segs, speakerEmbeddings: nil)
        let r = SegmentSpeakerReconciler.reconcile([p])
        #expect(r.speakerCount == 0)
        #expect(r.speakerEmbeddings.isEmpty)
        #expect(r.remaps[0].isEmpty)
    }

    @Test("Deterministic global-id assignment by part then local-id order")
    func deterministic() {
        // Part 1 introduces S2 then S1 (unsorted); ids assign in local-id sort order.
        let p1 = part([("Speaker 2", [1, 0]), ("Speaker 1", [0, 1])])
        let r = SegmentSpeakerReconciler.reconcile([p1])
        #expect(r.remaps[0]["Speaker 1"] == "Speaker 1") // sorted first → global 1
        #expect(r.remaps[0]["Speaker 2"] == "Speaker 2")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SegmentSpeakerReconcilerTests`
Expected: FAIL — `cannot find 'SegmentSpeakerReconciler' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/dBrief/Services/SegmentSpeakerReconciler.swift`:

```swift
import Foundation
import dBriefWire

/// Reconciles speakers across independently-diarized segments of a long
/// recording. Each 30-minute part is diarized on its own, so part 1's
/// "Speaker 1" and part 2's "Speaker 1" are not necessarily the same person.
/// This helper folds every part's *local* speaker ids into a single *global*
/// speaker space using voiceprint cosine similarity, so the merged transcript
/// has one consistent set of "Speaker N" labels plus one embedding per speaker.
///
/// Pure and deterministic. Degrades gracefully: a part with no embeddings (or a
/// speaker below the match threshold) contributes new distinct globals rather
/// than risk a wrong label — consistent with the project's "neutral Speaker N
/// beats a confident wrong name" stance.
enum SegmentSpeakerReconciler {
    /// Cross-part same-speaker acceptance threshold. Observed cross-speaker
    /// cosine ≈ 0.28 and self ≈ 1.0; all parts share one recording/mic/session,
    /// so same-speaker cosine across parts is high. 0.5 sits well between.
    static let matchThreshold: Float = 0.5

    struct Part {
        let segments: [TranscriptionResult.Segment]
        let speakerEmbeddings: [String: [Float]]?
        init(segments: [TranscriptionResult.Segment], speakerEmbeddings: [String: [Float]]?) {
            self.segments = segments
            self.speakerEmbeddings = speakerEmbeddings
        }
    }

    struct Result {
        let remaps: [[String: String]]
        let speakerEmbeddings: [String: [Float]]
        let speakerCount: Int
    }

    private struct Global {
        var id: String
        var vectors: [[Float]]   // contributing embeddings (empty if seeded without one)
        var rep: [Float]?        // running mean of `vectors`, nil when none
    }

    static func reconcile(_ parts: [Part]) -> Result {
        var globals: [Global] = []
        var remaps: [[String: String]] = []

        for part in parts {
            // Local speaker ids present in this part's segments, in sort order.
            let localIds = Set(part.segments.compactMap { $0.speaker }).sorted()
            var remap: [String: String] = [:]

            // 1. Greedy one-to-one match for locals that have an embedding.
            let embeds = part.speakerEmbeddings ?? [:]
            let embeddedLocals = localIds.filter { embeds[$0] != nil }

            // Candidate (local, globalIndex, cosine) pairs, only globals with a rep.
            var candidates: [(local: String, gIndex: Int, score: Float)] = []
            for local in embeddedLocals {
                guard let v = embeds[local] else { continue }
                for (gi, g) in globals.enumerated() {
                    guard let rep = g.rep else { continue }
                    candidates.append((local, gi, VoiceMatch.cosineSimilarity(v, rep)))
                }
            }
            // Sort by score desc; stable tiebreak on (globalId, localId) for determinism.
            candidates.sort {
                if $0.score != $1.score { return $0.score > $1.score }
                if globals[$0.gIndex].id != globals[$1.gIndex].id {
                    return globals[$0.gIndex].id < globals[$1.gIndex].id
                }
                return $0.local < $1.local
            }
            var usedLocals: Set<String> = []
            var usedGlobals: Set<Int> = []
            for c in candidates {
                guard c.score >= matchThreshold else { break } // sorted desc → rest are lower
                guard !usedLocals.contains(c.local), !usedGlobals.contains(c.gIndex) else { continue }
                usedLocals.insert(c.local)
                usedGlobals.insert(c.gIndex)
                remap[c.local] = globals[c.gIndex].id
                globals[c.gIndex].vectors.append(embeds[c.local]!)
                globals[c.gIndex].rep = mean(globals[c.gIndex].vectors)
            }

            // 2. Every unmatched local (no embedding, below threshold, or lost
            //    contention) becomes a new global, in local-id sort order.
            for local in localIds where remap[local] == nil {
                let newId = "Speaker \(globals.count + 1)"
                var g = Global(id: newId, vectors: [], rep: nil)
                if let v = embeds[local] {
                    g.vectors = [v]
                    g.rep = v
                }
                globals.append(g)
                remap[local] = newId
            }

            remaps.append(remap)
        }

        var embeddings: [String: [Float]] = [:]
        for g in globals {
            if let rep = g.rep { embeddings[g.id] = rep }
        }
        return Result(remaps: remaps, speakerEmbeddings: embeddings, speakerCount: globals.count)
    }

    private static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        guard vectors.count > 1 else { return first }
        var acc = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == first.count {
            for i in v.indices { acc[i] += v[i] }
        }
        let n = Float(vectors.count)
        return acc.map { $0 / n }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SegmentSpeakerReconcilerTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Services/SegmentSpeakerReconciler.swift Tests/dBriefTests/SegmentSpeakerReconcilerTests.swift
git commit -m "feat: SegmentSpeakerReconciler — unify speakers across diarized parts"
```

---

## Task 2: Wire the reconciler into segmented transcription

**Files:**
- Modify: `Sources/dBrief/Services/RecordingManager.swift` (`SegmentTranscriptionPiece` ~2582, `transcribeSegmentedAudio` ~2098, `mergeSegmentTranscriptions` ~2588)
- Test: `Tests/dBriefTests/WhisperPipelineTests.swift`

**Interfaces:**
- Consumes: `SegmentSpeakerReconciler.reconcile([SegmentSpeakerReconciler.Part]) -> SegmentSpeakerReconciler.Result` (Task 1).
- Produces: `mergeSegmentTranscriptions` now returns a `TranscriptionResult` whose `segments` carry reconciled `speaker` (on segments **and** words), plus `speakerEmbeddings` and `speakerCount`.

- [ ] **Step 1: Write the failing integration test**

Add to `Tests/dBriefTests/WhisperPipelineTests.swift` (inside the existing suite; if the file uses a `struct`, add this method):

```swift
    @Test("mergeSegmentTranscriptions reconciles speakers, embeddings, and count")
    func mergeForwardsSpeakerData() {
        // Part 1: Speaker 1 at t=0..1. Part 2: Speaker 1 (same voiceprint) at t=0..1.
        let seg1 = TranscriptionResult.Segment(
            start: 0, end: 1, text: "hello",
            words: [.init(word: "hello", start: 0, end: 1, probability: 1, speaker: "Speaker 1")],
            speaker: "Speaker 1")
        let seg2 = TranscriptionResult.Segment(
            start: 0, end: 1, text: "again",
            words: [.init(word: "again", start: 0, end: 1, probability: 1, speaker: "Speaker 1")],
            speaker: "Speaker 1")
        let p1 = RecordingManager.SegmentTranscriptionPiece(
            offsetSeconds: 0, text: "hello", segments: [seg1], speakerEmbeddings: ["Speaker 1": [1, 0]])
        let p2 = RecordingManager.SegmentTranscriptionPiece(
            offsetSeconds: 100, text: "again", segments: [seg2], speakerEmbeddings: ["Speaker 1": [0.98, 0.2]])

        let merged = RecordingManager.mergeSegmentTranscriptions([p1, p2])

        // Speakers survive the merge and are unified to one global.
        #expect(merged.segments.count == 2)
        #expect(merged.segments[0].speaker == "Speaker 1")
        #expect(merged.segments[1].speaker == "Speaker 1")
        #expect(merged.segments[1].words?.first?.speaker == "Speaker 1")
        // Offset still applied.
        #expect(merged.segments[1].start == 100)
        // Embeddings + count forwarded.
        #expect(merged.speakerCount == 1)
        #expect(merged.speakerEmbeddings?["Speaker 1"]?.count == 2)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter mergeForwardsSpeakerData`
Expected: FAIL — `SegmentTranscriptionPiece` has no `speakerEmbeddings:` argument (compile error).

- [ ] **Step 3: Add `speakerEmbeddings` to `SegmentTranscriptionPiece`**

In `RecordingManager.swift`, change the struct (~line 2582). Default the new field to
`nil` so the synthesized memberwise initializer keeps a default parameter — this keeps the
existing 3-arg call site in `mergeSegmentTranscriptionsAppliesOffsets`
(`Tests/dBriefTests/WhisperPipelineTests.swift:88`) compiling unchanged:

```swift
    struct SegmentTranscriptionPiece: Sendable {
        let offsetSeconds: Double
        let text: String
        let segments: [TranscriptionResult.Segment]
        let speakerEmbeddings: [String: [Float]]? = nil
    }
```

> The existing `mergeSegmentTranscriptionsAppliesOffsets` test asserts only text/count/offsets
> on speaker-less segments; the reconciler yields empty remaps and nil speakers for those, so its
> assertions stay green. Do **not** edit that test.

- [ ] **Step 4: Populate it per part in `transcribeSegmentedAudio`**

In the per-part loop (~line 2143), update the `pieces.append`:

```swift
            pieces.append(
                SegmentTranscriptionPiece(
                    offsetSeconds: cumulativeOffset,
                    text: result.text,
                    segments: result.segments,
                    speakerEmbeddings: result.speakerEmbeddings
                )
            )
```

Then replace the final assembly (~lines 2155-2163) so embeddings + count flow from the merge. The merge now owns reconciled segments/embeddings/count; `transcribeSegmentedAudio` overlays language/warnings/times:

```swift
        let merged = Self.mergeSegmentTranscriptions(pieces)
        return TranscriptionResult(
            text: merged.text,
            segments: merged.segments,
            language: language,
            warnings: warnings.isEmpty ? nil : warnings,
            speakerCount: merged.speakerCount,
            inferenceTime: inferenceSum,
            diarizationTime: diarizationSum,
            speakerEmbeddings: merged.speakerEmbeddings
        )
```

- [ ] **Step 5: Reconcile + remap inside `mergeSegmentTranscriptions`**

Replace the body (~lines 2588-2614):

```swift
    nonisolated static func mergeSegmentTranscriptions(_ pieces: [SegmentTranscriptionPiece]) -> TranscriptionResult {
        // Unify each part's independently-diarized speakers into one global space.
        let reconciled = SegmentSpeakerReconciler.reconcile(
            pieces.map { .init(segments: $0.segments, speakerEmbeddings: $0.speakerEmbeddings) }
        )

        var fullTextParts: [String] = []
        var mergedSegments: [TranscriptionResult.Segment] = []

        for (index, piece) in pieces.enumerated() {
            let remap = reconciled.remaps[index]
            let trimmed = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                fullTextParts.append(trimmed)
            }

            for segment in piece.segments {
                let globalSpeaker = segment.speaker.flatMap { remap[$0] }
                let remappedWords = segment.words?.map { word -> TranscriptionResult.Word in
                    var w = word
                    if let s = word.speaker { w.speaker = remap[s] }
                    return w
                }
                mergedSegments.append(
                    .init(
                        start: segment.start + piece.offsetSeconds,
                        end: segment.end + piece.offsetSeconds,
                        text: segment.text,
                        words: remappedWords,
                        speaker: globalSpeaker
                    )
                )
            }
        }

        return TranscriptionResult(
            text: fullTextParts.joined(separator: " "),
            segments: mergedSegments,
            speakerCount: reconciled.speakerCount == 0 ? nil : reconciled.speakerCount,
            speakerEmbeddings: reconciled.speakerEmbeddings.isEmpty ? nil : reconciled.speakerEmbeddings
        )
    }
```

Note: `TranscriptionResult.Word.speaker` is a `var`, and `Word` is a struct, so `var w = word; w.speaker = …` is a local mutation — correct.

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter "mergeForwardsSpeakerData"`
Expected: PASS.

Then the full pipeline suite (the merge has existing callers/tests):
Run: `swift test --filter WhisperPipelineTests`
Expected: PASS (existing offset/merge tests still green).

- [ ] **Step 7: Build the app target to confirm no integration breakage**

Run: `swift build`
Expected: Build complete, no errors.

- [ ] **Step 8: Commit**

```bash
git add Sources/dBrief/Services/RecordingManager.swift Tests/dBriefTests/WhisperPipelineTests.swift
git commit -m "fix: forward reconciled speakers, embeddings, and count through segmented merge"
```

---

## Task 3: Full test run + lessons/memory note

**Files:**
- Modify: `tasks/lessons.md` (mark the 3rd reconstruction-drop site fixed)

- [ ] **Step 1: Run the entire test suite**

Run: `swift test`
Expected: PASS — all suites green (was 409/409; now +8 reconciler/integration tests).

- [ ] **Step 2: Update the lessons note**

In `tasks/lessons.md`, find the section "`TranscriptionResult` has MULTIPLE reconstruction sites" and update item 3 from "NOT yet fixed" to fixed, e.g.:

```markdown
3. `RecordingManager.transcribeSegmentedAudio` / `mergeSegmentTranscriptions` — FIXED 2026-06-19.
   Now forwards `speaker` (segments + words), `speakerEmbeddings`, and `speakerCount` via the new
   pure `SegmentSpeakerReconciler`, which unifies each part's independently-diarized speakers into one
   global space by voiceprint cosine (threshold 0.5), degrading to distinct speakers when embeddings
   are absent (never mislabels).
```

- [ ] **Step 3: Commit**

```bash
git add tasks/lessons.md
git commit -m "docs: mark segmented reconstruction-drop site fixed in lessons"
```

---

## Self-Review

**Spec coverage:**
- Bug = 3 dropped fields (speaker, embeddings, count) → Task 2 forwards all three; integration test asserts all three. ✓
- `SegmentSpeakerReconciler` pure helper, greedy one-to-one cosine, mean centroid, 0.5 threshold, graceful degradation → Task 1 (impl + 7 tests). ✓
- Integration into `transcribeSegmentedAudio` / `mergeSegmentTranscriptions`, language/warnings/times preserved → Task 2 Steps 4-5. ✓
- Empty → nil surfacing → Task 2 Step 5 (`== 0 ? nil`, `.isEmpty ? nil`) + reconciler `noDiarizationPassThrough` test. ✓
- Determinism, words remapped, offset preserved → reconciler `deterministic` test + integration `mergeForwardsSpeakerData` (`words?.first?.speaker`, `start == 100`). ✓
- No wire/persistence changes → only app-target files touched. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code. ✓

**Type consistency:** `SegmentSpeakerReconciler.Part(segments:speakerEmbeddings:)`, `.Result{remaps,speakerEmbeddings,speakerCount}`, `reconcile(_:)`, `matchThreshold` used identically in Task 1 and Task 2. `TranscriptionResult` initializer arg order (`text, segments, language, warnings, speakerCount, inferenceTime, diarizationTime, speakerEmbeddings`) matches `Sources/dBriefWire/Models/TranscriptionResult.swift`. `SegmentTranscriptionPiece` 4-field initializer matches across struct def and both call sites. ✓
