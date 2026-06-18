# Phase 3b — Confirm-First Speaker Review (Design)

> Deferred subset of Phase 3 (`tasks/todo.md`). The growth loop + attribution-aware
> re-run shipped in #80/#81. This spec covers the remaining piece: a **mode toggle**
> (`AppSettings.speakerIdMode`) and a **dedicated review window** that stages resolver
> speaker-ID decisions for human accept/correct **before** names commit to the AI
> analysis, markdown, and integrations.

## Goal & motivation

Optimistic mode (today) auto-applies confident voice matches silently and runs the whole
pipeline (transcribe → resolve → AI → markdown → integrations) unattended. The Phase 2
"swapped labels" incident showed a confident-but-wrong match can reach the AI summary,
markdown, and exported integrations with no human in the loop. **Confirm-first** inserts a
checkpoint: after diarization + resolution, the pipeline **holds** before AI, surfaces a
focused review window with a playable audio snippet per speaker, and only commits names —
to the transcript, the AI analysis, and downstream exports — once the user confirms.

Confirm-first is **opt-in**; optimistic stays the default and its behavior is unchanged.

## Locked decisions (from brainstorming, 2026-06-18)

| Decision | Choice |
|---|---|
| Review timing | **Hold before AI.** Pause the pipeline after resolve, before AI/markdown/integrations. Non-blocking hold (come back any time). |
| Review scope | **All speakers** — matched (accept/correct) and unmatched ("Speaker N" with near-miss suggestions to pick or name freely). |
| Audio | **Playable snippet per speaker** so the user can *hear* the voice before confirming. |
| When to hold | **Only when there's something to resolve**: `≥2 diarized speakers` OR `library non-empty`. Solo memos / diarization-off skip the hold. |
| Surface | **Dedicated review window** (`id: "speaker-review"`), not the transcript window, not a menu-bar sheet. |
| Hold persistence | **Session-only.** Quit mid-hold leaves the saved transcript un-analyzed; recording appears normally in history. No cross-restart resume. |
| Cancel semantics | **Cancel = proceed optimistically** with the resolver's own names. A recording is never stranded. |
| "This is me" in review window | **Out of scope (v1)** — stays a transcript-window action. |

## Existing seams (grounded)

| Capability | Location |
|---|---|
| Resolver + `Decision{speakerId, personId?, name?, confidence, reason}` | `Sources/dBrief/Services/VoiceIdentityResolver.swift` (Decision ll.29–35, Reason ll.19–27, `resolve` ll.43–49) |
| Resolver invocation, roster build, `resolved` extraction | `RecordingManager.swift` ll.461–500 (resolve at ~472, extracts only `.matched`) |
| Rich-transcript build seam (`resolved`, `suppressOrdinalGuess`) | `RecordingManager.swift` ll.497–500; `RichTranscriptBuilder.build` ll.23–28, priority logic ll.51–60 |
| **Branch point for the hold** | `RecordingManager.swift` after l.500 (rich transcript built) and before l.521 (AI) |
| Downstream steps to extract | `RecordingManager.swift` Step 2 AI (l.519+), Step 3 markdown (l.609+), Step 4 integrations (l.693+), completion (l.718) |
| Enum-setting pattern (`String, CaseIterable, Codable` + `didSet`→UserDefaults) | `AppSettings.swift` (e.g. `TranscriptionEngine` ll.182–211, property ll.262–263) |
| Speaker rename + voiceprint enroll | `TranscriptWindowView.renameSpeaker` ll.787–814; `RecordingManager.enrollVoiceprintOnRename` |
| Window scene registration | `DBriefApp.swift` ll.247–255 (`Window(... id: "transcript")`) |
| Models | `RichTranscript` (segments, `speakerLabels`, `meSpeakerId`), `SpeakerLabel{id, displayName, personId?}` (`Models/RichTranscript.swift`) |
| Cosine helper | `VoiceMatch.cosineSimilarity` (used by resolver + dedup) |
| Audio playback | `AudioPlayer` (used in transcript window player bar) |
| Diarization toggle (settings home) | `SettingsRecordingTab` (Settings → Recording) |

## Architecture

### 1. Setting — `AppSettings.SpeakerIdMode`

```swift
enum SpeakerIdMode: String, CaseIterable, Codable, Hashable, Sendable {
    case optimistic    // auto-label confident matches, run straight through (default)
    case confirmFirst  // hold before AI; review speaker IDs first
    var displayName: String { ... }      // "Optimistic" / "Confirm first"
    var shortDescription: String { ... } // one line for the picker help
}

var speakerIdMode: SpeakerIdMode {
    didSet { UserDefaults.standard.set(speakerIdMode.rawValue, forKey: Keys.speakerIdMode) }
}
```
- `Keys.speakerIdMode = "speakerIdMode"`; load in init with `.optimistic` fallback (lenient — absent key → optimistic).
- Global setting (no profile override) for scope. UI: a `Picker` in **Settings → AI & Models → Transcription** (`SettingsTranscriptionTab`), co-located with the diarization toggle that gates it (the toggle lives at `SettingsTranscriptionTab.swift:296`, not the Recording tab), shown only when `diarizationEnabled`, with a one-line description of each mode.

### 2. Hold trigger — pure predicate

```swift
// Pure, unit-tested.
enum SpeakerReviewGate {
    static func shouldHold(mode: SpeakerIdMode, speakerCount: Int, libraryCount: Int) -> Bool {
        mode == .confirmFirst && (speakerCount >= 2 || libraryCount > 0)
    }
}
```
`speakerCount` = distinct speaker ids in the built rich transcript; `libraryCount` = `library.people.count` (already loaded at l.466).

### 3. Pipeline split + session hold

Extract today's Step 2 → Step 4 + completion from `processRecording` into a private
continuation method that takes the recording plus the existing per-recording processing
flags (transcribe/summary/actionItems/tags — currently threaded through `processRecording`,
captured into the session as needed):

```swift
private func runAnalysisAndExport(recording: Recording, /* processing flags */ ) async
```

- **No hold:** `processRecording` calls `runAnalysisAndExport` inline (behavior identical to today).
- **Hold:** instead of calling it, `processRecording`:
  1. Threads the **full** resolver `decisions: [String: Decision]` (not just `.matched`) into the session.
  2. Sets `appState.pendingSpeakerReview = SpeakerReviewSession(...)` capturing: `recording`, built `richTranscript`, `decisions`, `clusterEmbeddings`, `options`, and the master audio URL.
  3. Suppresses the Phase 1/2 auto-enroll for this recording (enrollment deferred to Confirm).
  4. Sets a status note ("Waiting for speaker confirmation"), opens the `speaker-review` window, and returns. `recordingState` stays `.processing` (paused) so the UI reflects a mid-pipeline state.

Resume entry points on `RecordingManager`:
```swift
func finishReview(confirmed: [String: ConfirmedSpeaker]) async  // Confirm
func cancelReview() async                                       // Cancel / close
```
- `finishReview` applies confirmed names/personIds to the session's rich transcript (via `SpeakerReassignment.rename`, which already handles swaps), persists it (`transcriptStore`), enrolls confirmed voiceprints (reuse `enrollVoiceprintOnRename` logic per named speaker), clears `pendingSpeakerReview`, then calls `runAnalysisAndExport`.
- `cancelReview` keeps the resolver's own names (the rich transcript already built optimistically), clears the session, then calls `runAnalysisAndExport`. Never strands the recording.

`SpeakerReviewSession` is `@MainActor`-held state on `AppState` (or a dedicated holder); `ConfirmedSpeaker { name: String, personId: String? }`. The session captures the existing transcribe/summary/actionItems/tags flags already threaded through `processRecording` so the continuation can run with the same options.

### 4. Review window — `SpeakerReviewView` (`Window id: "speaker-review"`)

Registered alongside the transcript window in `DBriefApp.swift`, bound to `appState.pendingSpeakerReview`. One card per diarized speaker (sorted by speaker id):

- **Name field** — editable `TextField`, prefilled with the matched name or "Speaker N".
- **Reason + confidence badge** — derived from `Decision.reason`/`.confidence` ("Matched · 0.82", "Off roster", "Below threshold", "No match"…). Color-coded (matched = affirmative, uncertain = neutral/amber).
- **Candidate chips** — top library matches for this cluster by cosine, computed in a pure helper:
  ```swift
  enum SpeakerReviewCandidates {
      static func topMatches(clusterEmbedding: [Float], library: VoiceLibrary, k: Int = 3)
          -> [(name: String, personId: String, score: Float)]
  }
  ```
  (reuses `VoiceMatch`, so the resolver itself is untouched), plus roster names (participants + calendar attendees) as no-score chips. Clicking a chip fills the name field and remembers the `personId`.
- **▶ Play snippet** — plays this speaker's representative turn from the master M4A. Range from a pure helper:
  ```swift
  enum SpeakerSnippet {
      // Longest turn for `speakerId`, capped to `maxLength` seconds from its start.
      static func representative(for speakerId: String, in transcript: RichTranscript,
                                 maxLength: Double = 6) -> (start: Double, end: Double)?
  }
  ```
  Playback via the existing `AudioPlayer`, bounded-stopped at the snippet `end` (the view observes `currentTime` and pauses at `end`, or `AudioPlayer` gains a small `playRange(from:to:)`).

Footer: **Confirm** → builds `[speakerId: ConfirmedSpeaker]` from the cards and calls `finishReview`. **Cancel** (and window close) → `cancelReview`.

### 5. Enrollment timing

In confirm-first the auto-enroll that Phase 1/2 runs at build time is **suppressed** for held recordings; `finishReview` enrolls one voiceprint per confirmed *named* speaker (skipping "Speaker N" placeholders), deduped via the existing `VoiceLibraryStore.upsert`. Optimistic mode keeps auto-enroll exactly as today.

## Data flow

```
processRecording
  ├─ finalize → transcribe → diarize → resolve (full decisions kept)
  ├─ richTranscriptBuilder.build(resolved:, suppressOrdinalGuess: hasLibrary)
  ├─ SpeakerReviewGate.shouldHold(mode, speakerCount, libraryCount)?
  │     NO  → runAnalysisAndExport(recording, options)        [unchanged path]
  │     YES → appState.pendingSpeakerReview = session
  │           open "speaker-review" window; return (paused)
  │                              │
  │            ┌─────────────────┴─────────────────┐
  │        Confirm                              Cancel/close
  │   finishReview(confirmed)                 cancelReview()
  │   apply names + personIds                 keep resolver names
  │   persist transcript                      (transcript already built)
  │   enroll confirmed voiceprints            clear session
  │   clear session                                 │
  │           └─────────────┬───────────────────────┘
  └──────────────── runAnalysisAndExport(recording, options)
                     (AI → markdown → integrations → idle)
```

## Components & responsibilities

| Unit | Purpose | Depends on |
|---|---|---|
| `AppSettings.SpeakerIdMode` + property | Persisted mode flag | UserDefaults |
| `SpeakerReviewGate.shouldHold` (pure) | Decide whether to pause | — |
| `SpeakerSnippet.representative` (pure) | Pick a representative audio range per speaker | `RichTranscript` |
| `SpeakerReviewCandidates.topMatches` (pure) | Rank library people for a cluster (display chips) | `VoiceLibrary`, `VoiceMatch` |
| `SpeakerReviewSession` / `ConfirmedSpeaker` | Carry held-pipeline state to the window and back | models only |
| `RecordingManager` split (`runAnalysisAndExport`, `finishReview`, `cancelReview`) | Hold/resume the pipeline | session, stores, enrollment |
| `SpeakerReviewView` + `Window("speaker-review")` | The review UI | session, `AudioPlayer`, the pure helpers |

## Error handling / edge cases

- **No embeddings / resolver didn't run** but `shouldHold` true (≥2 speakers, empty library): cards show "No match" + "Speaker N"; user can still name + play snippets. No candidate chips (empty library), roster chips only.
- **Snippet unavailable** (speaker has no turn, or audio missing): hide the ▶ button for that card; confirmation still works.
- **User confirms with a name that matches another speaker's name**: `SpeakerReassignment.rename` already swaps display names — reused as-is.
- **Window closed without Confirm**: treated as Cancel → optimistic proceed.
- **App quit during hold**: session lost (session-only); transcript already saved, recording appears in history un-analyzed; user can rename + re-run AI from the transcript window via existing paths.
- **Multiple recordings**: processing is serial (existing invariant); at most one `pendingSpeakerReview` at a time.

## Testing

Pure / unit (swift-testing):
- `SpeakerReviewGateTests` — truth table over (mode, speakerCount, libraryCount).
- `SpeakerSnippetTests` — longest-turn selection, `maxLength` cap, none when no turns.
- `SpeakerReviewCandidatesTests` — ranking + k cap + empty-library → [].

Build + documented manual check:
- Confirm-first on, real 2-speaker recording with ≥1 library member: pipeline holds, window opens, each card plays its snippet, candidate chips populate, Confirm commits names → AI/markdown reflect them + voiceprints enrolled; Cancel proceeds with resolver names.
- Optimistic mode + diarization-off + solo memo: no hold (regression check).

## Out of scope (v1)

- "This is me" toggle in the review window (transcript-window action; mic-energy "me" is its own deferred track).
- Cross-restart resume / "Needs review" history badge (session-only by decision).
- Per-profile override of `speakerIdMode`.
- Pruning a wrongly auto-enrolled voiceprint when a match is corrected (noted in Phase 3 risks; future Phase 3b/4 cleanup).
