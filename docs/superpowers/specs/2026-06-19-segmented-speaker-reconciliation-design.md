# Cross-Part Speaker Reconciliation in Segmented Transcription

> Spec — 2026-06-19. Fixes the long-standing "segmented recordings lose speaker
> data" bug (the 3rd `TranscriptionResult` reconstruction site noted in
> `tasks/lessons.md`), and does so correctly by reconciling speaker identities
> across independently-diarized parts via voiceprint similarity.

## Problem

Recordings longer than 30 minutes are auto-segmented into 30-minute parts
(`RecordingFinalizer`, `_partNN.m4a`). `RecordingManager.transcribeSegmentedAudio`
transcribes each part separately and merges the pieces via the static
`mergeSegmentTranscriptions`. That merge rebuilds every segment with only
`start / end / text / words`:

```swift
.init(start: segment.start + piece.offsetSeconds,
      end:   segment.end   + piece.offsetSeconds,
      text:  segment.text,
      words: segment.words)   // ← no `speaker`
```

and returns `TranscriptionResult(text:segments:)` with everything else defaulted.
Consequences for any segmented (long) recording:

1. **All speaker labels are dropped** — `segment.speaker` and `word.speaker` are
   never forwarded, so a long meeting shows no "Speaker N" attribution at all.
2. **`speakerEmbeddings` is dropped** — no voice-library match, no enrollment, no
   growth loop on long recordings (the originally-reported symptom).
3. **`speakerCount` is dropped** — wrong Benchmark / metadata counts.

This is the latent third reconstruction-drop site flagged in `tasks/lessons.md`
("`TranscriptionResult` has MULTIPLE reconstruction sites — forward every field").
It is broader than "forward one field" because each part is diarized
**independently**: part 1's "Speaker 1" and part 2's "Speaker 1" are not
necessarily the same person, so the speaker labels cannot simply be concatenated —
they must be **reconciled into a single global speaker space** first.

## Approach

A new pure helper reconciles each part's local speakers into a unified global
speaker space using voiceprint cosine similarity, then `transcribeSegmentedAudio`
forwards the remapped speakers, merged embeddings, and speaker count.

We intentionally do **not** match against the persisted voice library here. The
existing `VoiceIdentityResolver` already does library matching downstream (at the
rich-transcript build seam) once `speakerEmbeddings` is populated. This helper's
sole job is to make the parts mutually consistent.

### New unit: `SegmentSpeakerReconciler` (pure)

Location: `Sources/dBrief/Services/SegmentSpeakerReconciler.swift` (app target,
beside `VoiceMatch` / `VoiceIdentityResolver` — it reuses
`VoiceMatch.cosineSimilarity`, which lives in the app target, and is consumed only
by `RecordingManager`). Pure, deterministic, no I/O.

**Input** — an ordered array of per-part inputs, each:
- `segments: [TranscriptionResult.Segment]` (with the part's *local* speaker ids,
  offsets **not yet applied** — the existing merge applies offsets),
- `speakerEmbeddings: [String: [Float]]?` (the part's local `speakerId → vector`).

**Algorithm**
1. Global registry: `globalId → { rep: [Float] (running mean), vectors: [[Float]] }`.
   Global ids are `"Speaker 1"`, `"Speaker 2"`, … assigned in first-seen order.
2. **Part 1:** each distinct local speaker present in the part's segments seeds a new
   global speaker, in local-id sort order. If the part has an embedding for that
   local id, seed the registry with it.
3. **Part N (N>1):** collect the part's local speakers. For locals that have an
   embedding, compute cosine to each current global `rep`; form all
   (local, global) candidate pairs, sort by cosine descending, and assign **greedily
   one-to-one** (skip a pair whose local or global is already taken), accepting a
   match only when cosine `≥ matchThreshold`. A matched local folds its embedding
   into that global's `vectors` and recomputes `rep` as the mean. Every remaining
   local — below threshold, lost contention, or **no embedding at all** — becomes a
   new global speaker (appended after the existing globals, in local-id order).
4. Produce a per-part remap table `localId → globalId`.

**Output** — a value carrying:
- `remaps: [[String: String]]` (one `localId → globalId` map per input part), and
- `speakerEmbeddings: [String: [Float]]` (`globalId → mean vector`; entries only for
  globals that received ≥1 embedding), and
- `speakerCount: Int` (number of global speakers; `0` when no part had speakers).

**Threshold** — `matchThreshold = 0.5`, a named constant. Justification: observed
cross-speaker cosine ≈ 0.28 and self ≈ 1.0 (Phase 2 live data), and all parts come
from the **same recording / same mic / same session**, so same-speaker cosine across
parts is high. One-to-one assignment within a part prevents two distinct clusters of
one part collapsing onto a single global.

**Determinism** — global ids are assigned in (part order, then local-id sort order);
contention is resolved by sorting candidate pairs by cosine descending with a stable
tiebreak on (globalId, localId). No randomness.

**Graceful degradation** — if no part carries embeddings (diarization produced
clusters but extraction failed, or short clusters), step 3 never matches, so each
part's speakers become new distinct globals. The result over-counts speakers but
**never mislabels** — consistent with the project's `suppressOrdinalGuess` stance
(neutral "Speaker N" beats a confident wrong name). If diarization was off entirely,
segments carry `speaker == nil`; the helper produces empty remaps, no embeddings, and
`speakerCount == 0` (→ surfaced as `nil`), i.e. pure pass-through.

### Integration

- `SegmentTranscriptionPiece` gains `speakerEmbeddings: [String: [Float]]?`.
- `transcribeSegmentedAudio` populates that field per part from
  `result.speakerEmbeddings` (alongside the existing `inferenceSum` / `diarizationSum`
  / `language` / `warnings` accumulation, which is unchanged).
- `mergeSegmentTranscriptions` calls `SegmentSpeakerReconciler` to obtain the per-part
  remaps + global embeddings + count, then, when rebuilding each offset segment, sets
  `speaker = remap[localId]` and maps each `word.speaker` through the same remap.
- The final `TranscriptionResult` is assembled with the reconciled `segments`,
  `speakerEmbeddings` (nil when empty), and `speakerCount` (nil when 0), plus the
  language / warnings / inferenceTime / diarizationTime that `transcribeSegmentedAudio`
  already computes. (Reconciler runs on the *un-offset* per-part segments; the offset
  is still applied by the merge — reconciliation is offset-independent since it only
  touches speaker ids.)

No wire protocol, `MLEvent`, helper-process, or persistence changes. Purely app-side
plus one new pure file.

### Out of scope

- Matching against the persisted voice **library** during the merge (the downstream
  `VoiceIdentityResolver` already owns that).
- The intermittent per-clip embedding-extraction failure in
  `dBriefMLHost/SpeakerEmbeddingExtractor` (separate open item; this fix degrades
  gracefully when it bites).
- Mic-energy "me" classification (Decision A, still deferred).

## Testing

`Tests/dBriefTests/SegmentSpeakerReconcilerTests.swift` (swift-testing), all on the
pure helper:

1. **Same speaker across two parts** (high cosine) → one global, `speakerCount == 1`,
   global embedding equals the mean of the two part vectors.
2. **Different speakers across two parts** (low cosine) → two globals,
   `speakerCount == 2`, both remaps point to distinct globals.
3. **Three parts, two real people** → correct merge to 2 globals; verify a person
   appearing in parts 1 & 3 but not 2 still unifies.
4. **One part missing embeddings** → that part's speakers become new distinct globals
   (no mislabel); other parts still reconcile normally.
5. **Words remapped** → `word.speaker` is rewritten through the same table as
   `segment.speaker`.
6. **No diarization** (`speaker == nil` everywhere) → empty remaps, no embeddings,
   `speakerCount == 0`.
7. **Determinism** → identical input yields identical global-id assignment; a second
   speaker introduced only in part 2 gets the next sequential id.
8. **Offset preserved** (integration-level on `mergeSegmentTranscriptions`) → existing
   time-offset behavior is unchanged while speakers are now populated.

## Risks

- **Threshold mis-tune** — too low merges two real people; too high fragments one
  person. Mitigated by same-session acoustics + the 0.5 default sitting well between
  the observed 0.28 / 1.0 clusters; the constant is centralized for easy tuning, and
  fragmentation is user-fixable via the existing turn-card merge.
- **`TranscriptionResult` reconstruction discipline** — this very fix exists because a
  reconstruction site dropped fields. The new assembly forwards every field; a test
  asserts speaker + embeddings + count survive the merge.
