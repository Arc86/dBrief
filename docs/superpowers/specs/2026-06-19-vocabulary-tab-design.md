# Vocabulary Settings Tab — Design Spec

**Date:** 2026-06-19  
**Status:** Approved

## Problem

Custom Vocabulary is currently buried inside Settings → AI & Models → Transcription, gated behind Power User Mode, and only shown when the transcription engine is Local Whisper or a Remote Endpoint. The UI label ("Whisper prompt") and its placement imply the feature is Whisper-specific. In reality, the vocabulary now drives two engine-agnostic features: post-transcription spell-correction and AI analysis prompt injection. The feature should be discoverable by all users and clearly explain its actual purpose.

## Solution

Move Custom Vocabulary into its own top-level Settings tab ("Vocabulary"), visible to all users, with clear explanatory copy and a structured list UI supporting inline editing.

---

## Section 1 — Data Model

### Storage

Change `AppSettings.whisperPrompt: String` (comma-separated) to:

```swift
var customVocabulary: [String]
```

Stored as a JSON array in UserDefaults under key `"customVocabulary"`.

### Migration

On first load: if `customVocabulary` key is absent but the legacy `whisperPrompt` key exists, split on commas, trim whitespace, filter empties, and write to `customVocabulary`. Delete the old key after migration.

### Effective setting

`AppSettings+EffectiveSettings` gains:

```swift
var effectiveCustomVocabulary: [String] {
    activeProfile.overrides.customVocabulary ?? customVocabulary
}
```

Remove `effectiveWhisperPrompt`.

### Profile overrides

`MeetingProfile.Overrides.whisperPrompt: String?` → `customVocabulary: [String]?`

### Call sites

All usages of `effectiveWhisperPrompt` switch to `effectiveCustomVocabulary`. Where a prompt builder or API needs a string, join the array with `", "`.

---

## Section 2 — Tab & Navigation

### New tab case

```swift
case vocabulary = "Vocabulary"
```

- Icon: `"text.word.spacing"` (SF Symbol)
- Position: after `aiAndModels`, before `watchedFolders`
- Visibility: always visible (no Power User Mode gate)

### Removals

- Remove `vocabularySection` and its engine-gated condition from `SettingsTranscriptionTab`
- Remove the `vocabularySection` call from `SettingsTranscriptionTab`'s body

### Profile overrides update

In `SettingsProfilesTab`, update the vocabulary override row:
- Label: `"Vocabulary"` (was `"Whisper prompt"`)
- Binding: `\.customVocabulary` (`[String]?`)
- UI control: replace `NativeTextView` with a `TextField` that accepts comma-separated terms. On commit, split on commas, trim, filter empties, and write as `[String]?` (nil when the field is empty). Display the current value as a comma-joined string. This keeps the profile override row compact and consistent with other single-row overrides.

---

## Section 3 — Vocabulary Tab UI

### File

`Sources/dBrief/UI/SettingsVocabularyTab.swift`

### Layout

#### Header / description

Two-sentence description at the top of the content area:

> "Terms you add here help the AI understand your domain. After transcription, the AI corrects misspellings of these terms in the transcript. During analysis, they're provided to generate more accurate summaries and action items."
>
> "Add names, acronyms, product names, and technical terms your recordings commonly include."

Styled `.font(.callout)` / `.foregroundStyle(.secondary)`.

#### Term list

A `List` of `customVocabulary` terms. Each row:

- Term text, left-aligned
- Trash button on the right, revealed on `.onHover`
- Double-click switches the row to an inline `TextField`:
  - Return or click-away: confirm edit
  - Escape: cancel (restore original value)
- Duplicate terms ignored on confirm (case-insensitive comparison)

#### Empty state

When the list is empty, centered placeholder text:

> "No terms yet — add your first one below."

#### Add row

Pinned below the list:

- `TextField` with placeholder `"Add a term…"`
- "Add" button to the right
- Return in the field triggers add
- Field clears after successful add
- Duplicate (case-insensitive) terms silently ignored
- Leading/trailing whitespace trimmed; empty strings rejected

---

## Out of Scope

- Bulk import / paste-list feature (can be added later)
- Per-term metadata (categories, notes)
- Re-dispatching integrations when vocabulary changes

---

## Files Changed

| File | Change |
|------|--------|
| `Sources/dBrief/App/AppSettings.swift` | `whisperPrompt: String` → `customVocabulary: [String]` with migration |
| `Sources/dBrief/App/AppSettings+EffectiveSettings.swift` | `effectiveWhisperPrompt` → `effectiveCustomVocabulary: [String]` |
| `Sources/dBrief/App/AppSettings+Persistence.swift` | Update persistence helpers if needed |
| `Sources/dBrief/Models/MeetingProfile.swift` | `whisperPrompt: String?` → `customVocabulary: [String]?` in Overrides |
| `Sources/dBrief/UI/SettingsView.swift` | Add `vocabulary` tab case, icon, position |
| `Sources/dBrief/UI/SettingsVocabularyTab.swift` | New file — full tab implementation |
| `Sources/dBrief/UI/SettingsTranscriptionTab.swift` | Remove `vocabularySection` and its engine-gated condition |
| `Sources/dBrief/UI/SettingsProfilesTab.swift` | Update vocabulary override row label + binding |
| `Sources/dBrief/Services/RecordingManager.swift` | `effectiveWhisperPrompt` → `effectiveCustomVocabulary` (joined) |
| `Sources/dBriefWire/` | Any wire types referencing `whisperPrompt` |
