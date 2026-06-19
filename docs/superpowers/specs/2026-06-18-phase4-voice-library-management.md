# Phase 4 — Voice Library Management UI + Enrollment Affordance

> Design spec. Closes the management/polish phase of the diarization + voice-library track.
> Phases 0–3b are on `main`: extraction, storage, identity resolution, growth loop, and
> confirm-first review all ship. The library can grow but cannot be *managed* — there is no
> way to see, rename, merge, or forget the people it has learned. Phase 4 adds that surface,
> an explicit enrollment affordance, and tests.

## Goals

1. A **Voice Library** settings tab that lists known people and supports rename, merge,
   delete/forget, and per-voiceprint forget.
2. An explicit **"Save this voice to library"** action in the transcript turn-card menu, so a
   correctly-named speaker can be banked without renaming.
3. Tests for the new store operations.

## Non-goals (explicitly deferred)

- Mic-energy "me" classification (Decision A).
- The `transcribeSegmentedAudio` embeddings-drop fix (long recordings).
- `dBriefMLHostStub` embedding-post-pass test and "me"-classification test (belong to the
  deferred ML items above).

## Locked decision — identity decoupling (Approach A)

`KnownPerson.id` is currently the lowercased trimmed name, and `SpeakerLabel.personId` (saved in
`.richtranscript.json` sidecars) references it. Rename and Merge both change *which id owns a set
of voiceprints*, so identity must be decoupled from the display name.

**Approach A (chosen):** stop *deriving* id from name.

- `id` is **immutable** once a person exists. New people get a `UUID().uuidString`. Existing
  name-derived ids stay as-is — they are opaque strings, so old sidecar `personId` references keep
  matching. **No destructive migration.**
- `VoiceLibraryStore.upsert` changes its lookup from `id == key` to a **case-insensitive name
  match**, reusing the found person's existing id; it only mints a fresh id for a genuinely new
  name. This is the only behavioral change to existing code.
- Rename mutates only `name` → id stable → every reference (sidecars, resolver output) survives.

Rejected: full UUID migration (orphans existing sidecar `personId`s for no benefit); name-as-id
with rename = delete+recreate (silently loses links; rename-to-existing becomes a surprising
implicit merge).

`VoiceIdentityResolver`, `RichTranscriptBuilder`, and `SpeakerReassignment` are unaffected — they
already treat `personId` as opaque.

## Section 1 — Data model + store operations

No new stored fields. Derived per person:

- **sample count** = `voiceprints.count`
- **last seen** = `max(voiceprints.capturedAt)`

New `VoiceLibraryStore` actor methods (best-effort atomic save, mirroring `upsert`):

| Method | Behavior |
|---|---|
| `rename(id:to:) -> RenameResult` | Mutates `name` only. If the new name collides (case-insensitive) with **another** person, performs no change and returns a signal (e.g. `.collision(existingId:)`) so the UI can offer merge instead of creating a duplicate. Returns `.renamed` on success, `.notFound` if id absent. |
| `merge(sourceId:into:) -> Bool` | Appends source's voiceprints into the survivor, deduped via `VoiceEnrollment.isDuplicate` and bounded to `maxPerPerson` (newest kept), then drops the source person. No-op/false if either id missing or ids equal. |
| `delete(id:) -> Bool` | Removes the person entirely. |
| `removeVoiceprint(personId:capturedAt:) -> Bool` | Drops the matching sample (matched by `capturedAt`). If it was the person's last voiceprint, the person is removed too. |
| `upsert` (changed) | Lookup by case-insensitive **name** instead of `id == key`; reuse found id; new people get `UUID().uuidString`. |

`KnownPerson` initializer/dedup semantics otherwise unchanged.

## Section 2 — Voice Library settings tab

- New `SettingsView.SettingsTab.voiceLibrary` case, **always visible** (not power-user gated),
  SF Symbol `person.wave.2` (fallback `waveform`).
- New `SettingsVoiceLibraryTab` view, reading `voiceLibraryStore` + `AppContext` via
  `@Environment`. Because the store is an `actor`, the view holds
  `@State private var library: VoiceLibrary`, loaded in `.task`/`.onAppear` and **reloaded after
  every mutating op** (same pattern the transcript viewer uses for `knownPeopleNames`).
- Layout via the existing `SettingsSection` pattern:
  - **Privacy header** — voiceprints are stored locally in Application Support, never uploaded;
    consistent with dBrief's on-device posture.
  - **People list** — one row per `KnownPerson`, sorted by last-seen desc:
    `name` · `N samples · last heard <relative date>`. Row actions:
    - **Rename** — inline field / small popover; on name-collision prompt "Merge into existing
      <name>?" (routes to `merge`).
    - **Merge** — pick another person as the target (survivor).
    - **Delete** — confirmation alert ("Forget <name>'s voice?").
    - **Expand** — reveals individual voiceprints (captured date), each with a delete control
      (per-voiceprint forget).
  - **Empty state** — explains voices are added automatically when you name a speaker, or via
    "Save voice to library."

## Section 3 — Enrollment affordance (turn-card menu)

In `TranscriptWindowView.speakerMenuContent`, add **"Save [name]'s voice to library"**, shown when:

- the turn's speaker has a **non-blank display name** (not a raw "Speaker N"), **and**
- an embedding is **resolvable** for that speaker (from memory or the `.transcript.json`
  sidecar — the same path `enrollVoiceprintOnRename` already uses).

It reuses the existing enrollment path:
`RecordingManager.enrollVoiceprintOnRename(recording:speakerId:name:)` → `VoiceLibraryStore.upsert`,
then links the returned id onto `SpeakerLabel.personId` and refreshes `knownPeopleNames`. This
surfaces the growth-loop that today fires only on rename, letting a user bank a voice for an
already-correctly-named speaker. When the embedding is unavailable (segmented-recordings drop,
older transcript) the item is **hidden** rather than shown-and-failing. Brief feedback when
already enrolled this session (checkmark / disabled).

## Section 4 — Tests

- **`VoiceLibraryStoreTests`** (extend): round-trip plus new ops — `rename` (id stable, name
  changed), rename-collision signal, `merge` (combined + deduped + bounded, source dropped),
  `delete`, `removeVoiceprint` (incl. last-sample-removes-person), and `upsert` matching by name
  (reuses existing id, doesn't fork on case difference).
- **Pure derived-display helper** — if row formatting (sample count + last-seen) is extracted
  into a pure function, unit-test it; otherwise inline and skipped.
- **Menu visibility predicate** (named + embedding available) — tiny pure-helper test if
  extracted.
- Enrollment affordance is otherwise covered indirectly via the store/upsert tests (it reuses
  `enrollVoiceprintOnRename`).

## Verification

- `swift build` + `swift test` green.
- `make app` builds, signs, and launches.
- Manual: name a speaker → appears in the Voice Library tab; rename it there (transcript links
  survive); merge two people; forget a person and a single voiceprint; "Save voice" from the
  turn-card menu banks a correctly-named speaker.
