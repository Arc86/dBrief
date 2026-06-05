# Transcription Model Catalog (Redesign Phase 1) — Design

**Date:** 2026-06-05
**Status:** Approved (design phase)

## Goal

Replace the current engine-picker-plus-model-picker layout in the Transcription
settings with a **model-first card catalog** (per the provided mockups): a
"Default Model" header, a language picker, category tabs
(Recommended / Local / Cloud / Custom), and a scrollable list of model cards.
Each card shows the model's language scope, download size, editorial Speed and
Accuracy ratings, a one-line blurb, and a context-appropriate action
(Download / Set as Default / Default Model / Add Model). Secondary controls
(diarization, custom vocabulary, large-file chunking, show-all-models) move into
an inline collapsible **Advanced** section.

This is **Phase 1** of a larger redesign. It covers only the backends that exist
today. Two later phases are explicitly out of scope here (see *Out of Scope*).

## Decomposition (for context)

- **Phase 1 (this spec):** Transcription catalog UI + model-first selection over
  *existing* backends (Apple Speech, local Whisper, Parakeet, Custom
  OpenAI-compatible endpoints). Cloud tab is a "coming soon" placeholder.
- **Phase 2 (later):** Net-new cloud transcription providers (Groq, ElevenLabs
  Scribe, Deepgram Nova, Mistral Voxtral, Gemini, …) that populate the Cloud tab.
- **Phase 3 (later):** Apply the same card design to the AI Analysis page.

## Key Decision: Presentation Layer, Not a Data Migration

The catalog is a **presentation layer over the existing settings fields**. There
is **no** new persisted selection state and **no** migration. "Set as Default"
writes the existing fields exactly as the current pickers do:

| Card kind | Writes |
|-----------|--------|
| Apple Speech | `transcriptionEngine = .appleSpeech` |
| Whisper (a variant) | `transcriptionEngine = .localWhisper`; `whisperModelName = <variant id>` |
| Parakeet (v2/v3) | `transcriptionEngine = .parakeetLocal`; `parakeetModelVariant = "v2"\|"v3"` |
| Custom (an endpoint) | `transcriptionEngine = .remoteEndpoint`; `defaultTranscriptionEndpointId = <endpoint id>` |

Because nothing changes in the persisted model, **meeting profiles and the
`effective*` resolution paths keep working unchanged**. The "Default Model"
header simply renders whatever the effective current selection resolves to.

## Background / Current State

- `AppSettings.TranscriptionEngine` enum: `.appleSpeech`, `.localWhisper`,
  `.parakeetLocal`, `.remoteEndpoint` (`Sources/dBrief/App/AppSettings.swift:133`).
- Selection today: the engine enum plus `whisperModelName` (`:259`),
  `parakeetModelVariant` (default `"v3"`, `:577`), and
  `defaultTranscriptionEndpointId` / `transcriptionEndpoints`.
- Whisper variants are parsed by `WhisperModelInfo.parse(_:)`
  (`Sources/dBrief/Models/WhisperModelInfo.swift`), with a curated offline list
  `WhisperModelInfo.fallbackModels` and a live list via
  `WhisperKit.fetchAvailableModels(from: "argmaxinc/whisperkit-coreml")`.
  Real curated variant ids include: `openai_whisper-tiny`,
  `openai_whisper-tiny.en`, `openai_whisper-base`, `openai_whisper-base.en`,
  `openai_whisper-small`, `openai_whisper-small.en`, `openai_whisper-medium`,
  `openai_whisper-medium.en`, `openai_whisper-large-v3_turbo_934MB`,
  `openai_whisper-large-v3_turbo_934MB.en`, `openai_whisper-large-v3_1550MB`,
  `openai_whisper-large-v3_1550MB.en`, `distil-whisper_distil-medium.en_600MB`,
  `distil-whisper_distil-large-v3_turbo_600MB`,
  `distil-whisper_distil-large-v3_turbo_600MB.en`,
  `openai_whisper-large-v3-v20240930_626MB`.
- `ParakeetModelInfo.variants` = `v2` (English, ~1.5 GB) and `v3` (multilingual,
  ~1.8 GB) (`Sources/dBrief/Models/ParakeetModelInfo.swift`).
- The just-merged download system (`RecordingManager.downloadModel(_:)`,
  `modelDownloads: [LocalModelKind: ModelDownloadPhase]`) downloads the
  **currently-selected** model only; it is keyed by `LocalModelKind`
  (`.whisper`/`.parakeet`/`.gemma`). Phase 1 must extend this (see below).
- Current Transcription tab sections to be replaced/relocated:
  `engineSection`, `languageSection`, `vocabularySection`, `chunkingSection`,
  plus the diarization toggle and "Show all models" toggle
  (`Sources/dBrief/UI/SettingsTranscriptionTab.swift`). The endpoint editor
  (`endpointEditor`, `endpointsSection`) is kept and reused by the Custom tab.

**Grounding note:** the mockup's idealized list does not perfectly match the real
WhisperKit catalog (e.g. it shows plain "Large v2" and unquantized "Large v3" at
2.9 GB, which are not separate CoreML variants in `fallbackModels`). The curated
catalog is **grounded in real variant ids**; the mockup's titles, sizes, and
ratings are an **editorial overlay** applied to whichever real variants exist.
Curated entries with no real backing variant are dropped. Download size shown
comes from the variant's real metadata where available, falling back to the
editorial size.

## Components

### 1. `TranscriptionModelDescriptor` + `TranscriptionModelCatalog` (new, pure)

`Sources/dBrief/Models/TranscriptionModelCatalog.swift`

```swift
enum ModelLanguageScope: Sendable { case englishOnly, multilingual, nativeApple }
enum ModelLocation: Sendable { case onDevice, builtIn, cloud }
enum ModelCategory: Sendable, CaseIterable { case recommended, local, cloud, custom }

struct TranscriptionModelDescriptor: Identifiable, Sendable, Equatable {
    let id: String                  // "apple", "whisper:<variant>", "parakeet:v2", "custom:<uuid>"
    let title: String
    let engine: AppSettings.TranscriptionEngine
    let backingModelName: String?   // whisper variant id / parakeet "v2"|"v3" / nil for apple/custom
    let endpointID: UUID?           // custom only
    let languageScope: ModelLanguageScope
    let location: ModelLocation
    let sizeMB: Int?                // download size; nil for apple/custom/cloud
    let speed: Double?             // editorial 0–10; nil for "show all" dynamic extras
    let accuracy: Double?
    let blurb: String
    let categories: Set<ModelCategory>  // e.g. [.recommended, .local]
}
```

A `TranscriptionModelCatalog` assembles the list:
- **Static curated table** of Apple Speech + common Whisper + Parakeet entries
  with the editorial ratings below. Each Whisper entry's `backingModelName` is a
  **real** variant id; entries whose id is absent from
  `WhisperModelInfo.fallbackModelNames` ∪ the live list are dropped.
- **Custom** entries derived from `appSettings.transcriptionEndpoints` (one per
  endpoint, `engine: .remoteEndpoint`, `endpointID` set).
- **Show all models** (Advanced toggle on): merge the full live/fallback Whisper
  list as extra `.local` cards with `speed/accuracy == nil` (ratings shown as
  "—").
- **Cloud:** empty in Phase 1 (the Cloud tab renders a placeholder).

**Editorial ratings (Phase 1, local only — from the mockup):**

| Catalog title | engine / backing | scope | size | Speed | Accuracy | categories |
|---|---|---|---|---|---|---|
| Apple Speech | apple | nativeApple | — | — | — | local |
| Parakeet V2 | parakeet:v2 | englishOnly | 474 MB | 9.9 | 9.4 | recommended, local |
| Parakeet V3 | parakeet:v3 | multilingual | 494 MB | 9.9 | 9.4 | local |
| Tiny | whisper:openai_whisper-tiny | multilingual | 75 MB | 9.5 | 6.0 | local |
| Tiny (English) | whisper:openai_whisper-tiny.en | englishOnly | 75 MB | 9.5 | 6.5 | local |
| Base | whisper:openai_whisper-base | multilingual | 142 MB | 8.5 | 7.2 | local |
| Base (English) | whisper:openai_whisper-base.en | englishOnly | 142 MB | 8.5 | 7.5 | recommended, local |
| Large v3 (1.5 GB) | whisper:openai_whisper-large-v3_1550MB | multilingual | 1.5 GB | 3.0 | 9.8 | local |
| Large v3 Turbo (Quantized) | whisper:openai_whisper-large-v3_turbo_934MB | multilingual | 934 MB | 7.5 | 9.5 | recommended, local |
| Distil Large v3 Turbo | whisper:distil-whisper_distil-large-v3_turbo_600MB | englishOnly | 600 MB | 9.0 | 9.0 | local |

> The implementer reconciles titles/sizes against the real variant metadata. Where
> the mockup's exact model (e.g. plain "Large v2" 2.9 GB) has no real variant, it
> is omitted. Editorial ratings are the mockup's where a row matches, otherwise a
> sensible value consistent with the family. The current app default
> (`whisperModelName` initial value `openai_whisper-small`) need not be the
> catalog's "recommended" highlight — the header always reflects the *actual*
> current selection.

Pure helper functions (unit-tested):
- `func cardState(for:isCached:isSelected:) -> CardState` →
  `.download | .setAsDefault | .defaultModel | .builtInSelectable` etc.
- `func descriptors(endpoints:dynamicWhisper:showAll:) -> [TranscriptionModelDescriptor]`
- `func selectionWrites(for:) -> SettingsSelection` (which fields "Set as Default"
  must write) — see the mapping table above.

### 2. Per-model download (extend the merged system)

`RecordingManager` / `LocalAIPluginService` / `ParakeetTranscriptionService`:
- `modelDownloads` is re-keyed from `[LocalModelKind: …]` to
  `[String: ModelDownloadPhase]` keyed by **descriptor id** (so each card tracks
  its own download).
- `downloadModel(descriptorID:engine:whisperModelName:parakeetVariant:)` downloads
  the **specified** model (not the currently-selected one). For Whisper it builds
  a `WhisperRuntimeConfig` with the target `modelName`; for Parakeet it passes the
  target variant. `cancelDownload(descriptorID:)` and `isModelCached(descriptorID:)`
  follow suit.
- `LocalAIPluginService.isWhisperModelCached(name:)` already takes a model name
  (good). `WhisperKitTranscriptionService.isModelDownloaded(name:)` already exists.
  Parakeet cache check is coarse (per the prior spec) — acceptable.
- The `.gemma` keying is unaffected (AI tab still uses the old per-kind path until
  Phase 3); both keyings can coexist if the dictionary key becomes a `String` and
  the AI tab uses fixed string keys like `"gemma"`. The `canDownloadModels` guard
  and `cancelAllActiveDownloads()` continue to apply (sweep all keys).

### 3. `RatingDotsView` (new)

`Sources/dBrief/UI/RatingDotsView.swift` — renders a label ("Speed"/"Accuracy"),
five dots filled proportionally to a 0–10 value, color-coded (green ≥ 8, yellow
5–8, red < 5), and the numeric value. Renders "—" when the value is nil.

### 4. `TranscriptionModelCard` (new)

`Sources/dBrief/UI/TranscriptionModelCard.swift` — one card:
- Title; a metadata row of badges (language-scope globe + label, size with disk
  icon, location icon for built-in/cloud); two `RatingDotsView`s; the blurb.
- A trailing action area driven by the computed `CardState`, reading download
  state from `recordingManager.modelDownloads[descriptor.id]`:
  - not cached → **Download** (inline cancelable progress while downloading;
    reuses the `ModelDownloadButton` rendering logic).
  - cached & not selected → **Set as Default**.
  - cached & selected (or built-in selected) → **Default Model** + a `⋯` menu.
  - built-in not selected (Apple Speech) → **Set as Default**.
  - custom → **Set as Default** + edit/**Configure** (opens the existing endpoint
    editor); plus the list's **Add Model** button.
- `⋯` menu options (local, cached): *Set as Default* (if not default),
  *Re-download* (`forceRedownload: true`), *Delete* (purge). Apple Speech has no
  `⋯`.
- Selected card is highlighted (accent border/fill), matching the mockup.

### 5. `TranscriptionModelCatalogView` (new)

`Sources/dBrief/UI/TranscriptionModelCatalogView.swift` — composes the page:
1. **Default Model** header card (title of the effective current selection).
2. **Transcription Language** picker (moved from `languageSection`; blurb adapts
   to the selected descriptor's `languageScope`).
3. **Tabs** (`Recommended / Local / Cloud / Custom`) as a segmented row.
4. The card list for the active tab. **Cloud** renders a "Cloud transcription
   providers are coming soon" placeholder. **Custom** renders endpoint cards +
   the **Add Model** button + the "Only OpenAI-compatible…" note, wired to the
   existing `endpointEditor`.
5. Inline collapsible **Advanced** disclosure: diarization toggle, custom
   vocabulary field, large-file chunking (shown when the default is a remote
   endpoint), and "Show all models" toggle.

### 6. `SettingsTranscriptionTab` (modify)

Swap the `Form`'s engine/language/vocabulary/chunking sections for
`TranscriptionModelCatalogView`. Keep `isEditing`/`endpointEditor` and the
endpoint state so the Custom tab can present add/edit. Remove the now-dead
`engineSection`, `languageSection`, `vocabularySection`, `chunkingSection`, and
the `showAllWhisperModels`/whisper-fetch state that moves into the catalog view.

## Data Flow

```
Open Transcription settings
  → TranscriptionModelCatalogView builds descriptors
      (curated table ∩ real variant ids) ∪ (custom from endpoints) ∪ (showAll dynamic)
  → header reads effective current selection → renders title
Tap Download on a card
  → recordingManager.downloadModel(descriptorID: id, …target model…)
  → inline progress on that card (modelDownloads[id]); Cancel supported
  → on finish, card recomputes → "Set as Default"
Tap Set as Default
  → writes existing fields per the mapping table → header updates → card → "Default Model"
Tap ⋯ → Re-download / Delete (purge) / Set as Default
```

## Error Handling

- Download errors → the card shows the failed state + Retry (reuses the merged
  download phase model).
- Selecting a model whose cache was later cleared → transcription's existing lazy
  download remains the safety net (the loadWhisperKit/loadManager path).
- Live HuggingFace fetch failure → catalog falls back to `fallbackModels`
  (existing behavior) and "Show all models" simply shows the offline set.
- Downloads disabled during recording/processing (`canDownloadModels`), with the
  existing tooltip.

## Testing (swift-testing)

`Tests/dBriefTests/TranscriptionModelCatalogTests.swift`:
- **Card state:** `cardState(for:isCached:isSelected:)` across the matrix
  (not-cached → download; cached+unselected → setAsDefault; cached+selected →
  defaultModel; apple selected → defaultModel; apple unselected → setAsDefault).
- **Selection mapping:** `selectionWrites(for:)` returns the correct
  engine/model/endpoint fields for each card kind (table above).
- **Catalog assembly:** curated entries with unknown variant ids are dropped;
  custom endpoints become `.custom` descriptors; show-all merges dynamic entries
  with nil ratings; a curated entry present in the variant list is retained.
- **Rating color thresholds:** the pure color function (green ≥ 8, yellow 5–8,
  red < 5) returns expected buckets.

UI composition (the views) is verified via `swift build` and manual run.

## Out of Scope (Phase 1)

- All cloud provider integrations (Groq/ElevenLabs/Deepgram/Mistral/Gemini) — the
  Cloud tab is a placeholder. (Phase 2.)
- The AI Analysis page redesign. (Phase 3.)
- A unified persisted model-registry / migration — selection stays in the
  existing engine + model fields.
- The mockup's gear (⚙️) control — advanced settings live inline instead.

## Touched Files

- New: `Sources/dBrief/Models/TranscriptionModelCatalog.swift`
- New: `Sources/dBrief/UI/TranscriptionModelCatalogView.swift`
- New: `Sources/dBrief/UI/TranscriptionModelCard.swift`
- New: `Sources/dBrief/UI/RatingDotsView.swift`
- New: `Tests/dBriefTests/TranscriptionModelCatalogTests.swift`
- Modify: `Sources/dBrief/Services/RecordingManager.swift` (per-model download,
  `modelDownloads` keyed by descriptor id)
- Modify: `Sources/dBrief/UI/ModelDownloadButton.swift` (accept a string key /
  descriptor id; reuse rendering inside the card)
- Modify: `Sources/dBrief/UI/SettingsTranscriptionTab.swift` (host the catalog,
  keep the endpoint editor)
- Possibly Modify: `Sources/dBrief/Services/LocalAIPluginService.swift` /
  `ParakeetTranscriptionService.swift` only if the per-model download needs new
  parameters (Whisper already takes a config; Parakeet already takes a variant).
