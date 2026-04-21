# Disable AI Processing Toggle — Design Spec

**Date:** 2026-04-21  
**Status:** Approved

## Summary

Add a single global boolean to AppSettings that disables all AI processing (summary, action items, tags, title generation). When off, recordings are transcribed only. The toggle lives in Settings → AI Analysis tab. No per-recording override.

## 1. Settings Model

**File:** `Sources/dBrief/App/AppSettings.swift`

Add one property:

```swift
var aiProcessingEnabled: Bool  // default: true
```

- Persisted to `UserDefaults` via `didSet`, consistent with all other settings
- No profile override — this is a global switch only
- `autoSummary`, `autoActionItems`, `autoTags` are left untouched so user defaults are preserved when AI is re-enabled

Add a `Keys` constant: `static let aiProcessingEnabled = "aiProcessingEnabled"`

## 2. PostRecordingSheet UI

**File:** `Sources/dBrief/UI/PostRecordingSheet.swift`

When `settings.aiProcessingEnabled == false`:
- Hide the AI checkboxes section (summary, action items, tags) entirely
- Show a small secondary note in its place: `"AI processing is disabled in Settings"`
- Transcription toggle, title field, and participants field remain visible and functional

When `settings.aiProcessingEnabled == true`:
- Sheet renders exactly as today — no change

## 3. RecordingManager Pipeline

**File:** `Sources/dBrief/Services/RecordingManager.swift`

After the transcription step completes, add a guard before the AI block:

```swift
guard appSettings.aiProcessingEnabled else {
    // skip preflight, summary, action items, tags, title generation
    // fall through to markdown generation and integration dispatch
    ...
}
```

- Memory preflight check (`preflightCheck`) is also skipped — no point warning about models that won't run
- The `summary`, `actionItems`, `tags` booleans passed from PostRecordingSheet are ignored when AI is disabled (guard fires first)
- Markdown output is generated transcript-only (existing behaviour — no AI fields populated)
- Integration dispatch proceeds normally

## 4. Settings UI

**File:** `Sources/dBrief/UI/SettingsAITab.swift`

Add a toggle at the very top of the AI Analysis tab, above the engine picker:

```
[toggle] Enable AI processing
         When off, recordings are transcribed only — no summary,
         action items, or tag analysis.
```

- When toggle is off, the rest of the tab (engine picker, prompts, endpoints) remains visible — settings are preserved, just inactive
- No collapsing or hiding of other settings in this view

## Out of Scope

- Per-recording override of the AI toggle
- Changes to `autoSummary` / `autoActionItems` / `autoTags` defaults
- Profile-level override
