# Lessons Learned

## Extracting a method from a long pipeline — grep for ALL referenced locals, not a sample

Phase 3b split `RecordingManager.processRecording` at the resolve seam, moving Steps 2–4 into
`runAnalysisAndExport`. I pre-checked the moved block for `result`/`rich`/`resolved`/`library`/
`stepIndex` and concluded it was self-contained — but it also referenced **`perf*` accumulators**
(7 transcription-side metrics declared in Step 1, read at the completion block) and the **`transcribe`**
flag. The build caught it, but the fix rippled (a `TranscriptionPerf` struct carried across the hold +
threaded onto `SpeakerReviewSession`). Lesson: before moving a block out of a long function, enumerate
**every** identifier it reads that's declared above the cut — `awk 'NR>=START && NR<=END'` over the block
and eyeball the free variables — don't spot-check a remembered subset. Locals that accumulate across the
whole function (timers, perf counters, flags) are the easy ones to miss.


## `TranscriptionResult` has MULTIPLE reconstruction sites — forward every field at each

`TranscriptionResult` is rebuilt (not mutated) in several places. Any new field added to it
must be forwarded at **all** of them, or it silently vanishes on some recordings:

1. `dBriefWire/TranscriptCleanup.clean` — fixed once (commit 3238707) for `speakerEmbeddings`/`diarizationTime`.
2. `dBriefWire/Models/VocabularyCorrection.apply` — **missed**; dropped `speakerEmbeddings` + `diarizationTime`
   (only forwarded `inferenceTime`). Bites only when a custom vocabulary is set AND a correction fires.
   Fixed 2026-06-18.
3. `RecordingManager.transcribeSegmentedAudio` / `mergeSegmentTranscriptions` — FIXED 2026-06-19.
   Now forwards `speaker` (segments + words), `speakerEmbeddings`, and `speakerCount` via the new
   pure `SegmentSpeakerReconciler`, which unifies each part's independently-diarized speakers into one
   global space by voiceprint cosine (threshold 0.5), degrading to distinct speakers when embeddings
   are absent (never mislabels).

**Rule:** when adding a field to `TranscriptionResult`, grep for every `TranscriptionResult(` constructor
call and a `.map`/merge that produces one, and forward the field. A codable round-trip test does NOT catch this.

## Best-effort helper code must log each failure branch at `.error`, not `.info`

`SpeakerEmbeddingExtractor.embeddings` collapsed every failure (decode fail, no clusters, model-load fail,
per-speaker zero-vector) to `[:]` with a single `.info` log. macOS unified logging does NOT persist `.info`,
so an intermittent failure left zero evidence in `log show`. Diagnosing required reconstructing from saved
sidecars. Lesson: in best-effort paths whose failure degrades a feature silently, log the *distinguishing*
branch at `.error` so `log show --predicate 'process == "<helper>"'` captures it after the fact.

## Speaker auto-label swap (2026-06-18) — diagnosis pattern that worked

Symptom: "two known people swapped" in the transcript. Diagnosis without re-recording:
- `personId == None` on the rich-transcript labels → the **resolver never matched**; names came from the
  **ordinal participant fallback** in `RichTranscriptBuilder` (participants[0]→sorted Speaker 1, etc.) — a coin flip.
- Replayed the saved `.transcript.json` `speakerEmbeddings` against `library.json` offline (cosine) → would
  have matched correctly IF embeddings were present.
- `hasEmbeddings` differed across recordings of the **identical audio** (same duration to the microsecond)
  → proved the missing embeddings are an **intermittent helper-state failure**, not content/build/path/size.

Takeaway: saved sidecars (`.transcript.json`, `.richtranscript.json`, `library.json`) + offline cosine replay
are a powerful no-re-record diagnostic. `personId` presence cleanly distinguishes "resolver matched" from
"ordinal fallback guessed."

## FIXED: ordinal participant fallback no longer shows confident wrong labels (when a library exists)

Was: when typed participants existed but voice matching couldn't run (no embeddings) or didn't confidently
match, `RichTranscriptBuilder` assigned participant names by ordinal (sorted speaker-id ↔ typed order) — an
arbitrary 50/50 guess presented as fact. This is what *showed* the swap to the user.

Fix (2026-06-18): `RichTranscriptBuilder.build(..., suppressOrdinalGuess:)`. `RecordingManager` sets it true
when the voice library is non-empty (loads the library unconditionally so this holds even when embeddings
are absent). With a library, only confident voice matches name speakers; unmatched ones stay "Speaker N"
(rename-able). Ordinal mapping preserved for users with no library (legacy convenience). So a rare
embedding-extraction miss now yields a neutral "Speaker N", never a wrong name.

Still open: the rare/stateful embedding-extraction failure itself (helper returned `[:]` on `1001`/`1214`
but extracted fine on 3 fresh-build re-runs of the same audio). Now non-harmful + logged at `.error`; awaiting
a live recurrence to pinpoint the branch (decode/model-load/zero-vector).

## Verifying SwiftUI redesigns on an LSUIElement app — harness the real tokens, watch for display sleep

Redesigning the transcript window (neon-on-black, 8 phases), I couldn't drive the real app to a
screenshot: dBrief is `LSUIElement` and the transcript `Window` only opens via in-app interaction,
and `make app` is a heavy ML release build. Approach that worked: a throwaway `swiftc` harness in the
scratchpad that compiles the **real** source files whose visuals I was verifying (`TranscriptDesignTokens.swift`,
`Color+Hex.swift`) with a tiny `Theme` stub, renders the layout recipe in an `NSWindow`, and `screencapture`s it.
Same tokens → faithful preview without the ML stack. Two gotchas:
- A window wider/taller than the screen gets clipped (and `window.center()` may clamp on-screen); render one
  scheme at a time (≤ screen size) or side-by-side, and compute crop offsets from the centered rect.
- After several launches the **display went to sleep** and every `screencapture` returned all-black — including
  a re-render of a previously-good frame. All-black across *both* schemes = capture-env/sleep, not a render bug.
  Don't keep retrying; confirm by re-capturing a known-good frame.
Net: this verifies the token/visual layer, not the live wiring. A real-app integration pass (open the
Transcripts window, dark+light) is still the gold standard and worth a project `run` skill.
