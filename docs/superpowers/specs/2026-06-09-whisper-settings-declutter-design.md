# Declutter the Local Whisper settings section

**Date:** 2026-06-09
**Status:** Approved design — ready for implementation plan
**Area:** `Settings → AI & Models → Transcription` (the `.localWhisper` engine branch)

## Problem

The Local Whisper section of `SettingsTranscriptionTab` renders every control in one
flat `VStack(alignment: .leading, spacing: 8)`
([SettingsTranscriptionTab.swift:101-214](../../../Sources/dBrief/UI/SettingsTranscriptionTab.swift#L101-L214)).
Primary controls (model picker, diarization) sit at the same visual level as rare,
advanced ones (compute units, "Show all models", refresh, re-download, purge), interleaved
with several long caption paragraphs. The result is cluttered and intimidating for
non-technical users, with no visual hierarchy.

Two latent inconsistencies surfaced while scoping:

1. The actual default model is `openai_whisper-small`
   ([AppSettings.swift:652](../../../Sources/dBrief/App/AppSettings.swift#L652)), but the
   help copy claims "Large V3 Turbo recommended." Copy and behavior disagree.
2. The genuinely best default for most Macs — `openai_whisper-large-v3-v20240930_626MB`
   (Sep-2024 large-v3 turbo, ~626 MB, much faster) — is hidden behind "Show all models"
   by the curated-list filter
   ([SettingsTranscriptionTab.swift:109-115](../../../Sources/dBrief/UI/SettingsTranscriptionTab.swift#L109-L115)).

## Goals

- A clear three-zone hierarchy that a non-technical user can navigate.
- Built-in plain-language guidance so the simplified surface stays self-explanatory.
- Surface and recommend the fast Sep-24 Turbo model.
- Keep all existing controls reachable (reorganize, do not remove).

## Non-goals

- Parakeet / Remote Endpoint / Apple Speech sections (Parakeet may get the same card
  treatment in a later pass — not here).
- The endpoints editor and large-file chunking UI.
- Any change to the transcription pipeline, model download mechanics, or `WhisperKit`
  integration. This is a settings-UI + default-value change only.

## Design

### Zone 1 — Visual structure (Layout A)

Replace the flat stack with three zones inside the existing `Form` / `Section("Engine")`:

1. **Model card** — a single bordered card (rounded rect, `secondarySystemFill`-style)
   containing:
   - Friendly model name + a `Recommended` badge when the selected model is the
     recommended one.
   - A status line merging the memory estimate and download state:
     `~626 MB · ✓ Ready to use` (replaces today's separate `~X GB required` caption and
     the standalone `ModelDownloadButton` status text).
   - A trailing `Change ⌄` menu picker (the existing model `Picker`, restyled).

   This single card absorbs three of today's separate rows.

2. **Primary toggle** — "Identify different speakers" (diarization) remains a visible
   toggle row directly under the card.

3. **`Advanced` disclosure** (`DisclosureGroup`, collapsed by default) containing:
   - Compute units picker ("Where it runs").
   - "Show all models" toggle.
   - Re-download + Purge actions.
   - The large-model memory warning and the HuggingFace-unreachable error surface
     here / contextually rather than at the top level.

The `TranscriptionEngineGuideView` ("Need some help?") stays at the bottom as today.

### Zone 2 — Guidance for non-technical users

User decisions: **plain label with the technical term kept in the caption**; **static
recommendation**.

- **ⓘ next to the "Model" group title** → popover, plain words:
  > "Smaller models are faster but less accurate. Larger models are more accurate but use
  > more memory and time. When in doubt, keep the recommended one."

- **Per-model descriptor line** under the card, changing with the selection. Copy lives on
  the model, not the view: add computed `plainDescription` (and the recommended note) to
  `WhisperModelInfo`, authored per family (tiny / base / small / medium / large turbo /
  large full). Recommended model reads, e.g.:
  > "Best balance of speed and accuracy for most Macs. Audio never leaves your device."

- **Plain labels, technical term in caption:**
  - "Identify different speakers" — caption: *"Diarization — labels who said what. Slower,
    uses ~500 MB more memory."*
  - "Where it runs" — caption mentions *compute units / Neural Engine*.

- **Friendly captions inside Advanced** so power controls self-explain, e.g.
  *"Leave on Automatic unless transcription fails on large models."*

- **Compute-units relabel:** display the `.all` case as **"Automatic"**. Display text only —
  no enum change to `WhisperComputeUnits`.

### Zone 3 — Recommended model + curated-list fix

- **Single source of truth:** add `WhisperModelInfo.recommendedModelID =
  "openai_whisper-large-v3-v20240930_626MB"`. Used for both the card badge and the picker's
  "· Recommended" suffix (mirrors the existing `TranscriptionEngine.isRecommended`).
- **Surface it in the curated list:** extend the default-list filter
  ([SettingsTranscriptionTab.swift:109-115](../../../Sources/dBrief/UI/SettingsTranscriptionTab.swift#L109-L115))
  to include the `large-v3-v20240930` family so the model appears without "Show all models."
- **New-user default:** change the `whisperModelName` default from `openai_whisper-small` to
  the recommended ID ([AppSettings.swift:652](../../../Sources/dBrief/App/AppSettings.swift#L652)).
- **Fix stale copy:** update the description paragraph that currently claims "Large V3 Turbo
  recommended" to name the actual recommended model.

### Migration (decision: leave existing users alone)

No migration code. Only the default *value* changes, so a user who explicitly picked a
model keeps it (their choice is persisted to `UserDefaults`).

**Known, deliberate edge case:** a returning user who never changed the model may have no
persisted `whisperModelName` (the property's `didSet` does not fire during `init`), so on
next launch they resolve to the *new* recommended default and trigger a one-time ~626 MB
download. Strictly avoiding this would require a first-run flag; we accept the edge case
rather than add that plumbing. Documented here so it is a conscious choice, not a surprise.

## Files touched

| File | Change |
|------|--------|
| `Sources/dBrief/UI/SettingsTranscriptionTab.swift` | Rebuild the `.localWhisper` branch into the three-zone layout; extend the curated-list filter; relabel compute-units display; possibly extract a small `ModelCard` subview. |
| `Sources/dBriefWire/Models/WhisperModelInfo.swift` | Add `recommendedModelID`; add `plainDescription` / recommended-note copy per family. |
| `Sources/dBrief/App/AppSettings.swift` | Default `whisperModelName` → recommended ID; "Automatic" display label for `.all`. |

## Testing

- Extend `WhisperModelInfoTests`: assert `recommendedModelID` is present in
  `fallbackModels`, and that every model family resolves a non-empty `plainDescription`.
- Manual: confirm the recommended model now appears with "Show all models" **off**, the
  badge renders, the Advanced disclosure starts collapsed, and captions read correctly.

## Docs (repo convention)

- Update `CLAUDE.md` (WhisperKit row / recommended model wording).
- Update `site/docs/` (+ NAV in `site/docs.js`) to reflect the new recommended model and
  relabeled controls.
