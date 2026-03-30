# dBrief — UI Refresh & Memory Hardening Design

**Date:** 2026-03-30
**Status:** Approved
**Audience:** Small team distribution (not public App Store)

---

## Overview

Two integrated tracks delivered together:

1. **UI Refresh** — Redesigned menu bar popover (four states), results view showing actual AI output, inline history actions, sidebar-based settings window.
2. **Memory Hardening** — Pre-flight memory checks, live memory indicator during processing, graceful partial results on failure.

The tracks are integrated because the Results view overhaul and the memory visibility work share the same surface: the processing/results state of the popover.

---

## 1. Visual Foundation

- **System appearance-aware.** Both dark and light mode are first-class. No hardcoded colors. Use macOS semantic colors: `label`, `secondaryLabel`, `tertiaryLabel`, `fill`, `secondaryFill`, `systemBackground`, `secondarySystemBackground`.
- **Style:** Clean, information-dense. No gradients, no frosted glass, no decorative shadows. Tight spacing, clear typographic hierarchy.
- **Existing patterns preserved.** `VisualEffectView`, `MaterialBackgroundView`, `SettingsSection`, `SettingsToggleRow` are reused or updated — not replaced.

---

## 2. Popover — Four States

The menu bar popover transitions between four distinct states based on `AppState.recordingState` and the presence of processing results.

### 2.1 Idle State

Shown when `appState.isIdle && !appState.hasProcessingResults`.

**Layout (top to bottom):**
- Header row: "dBrief" title (left), "Settings" link (right)
- Profile picker: label + `Picker(.menu)`, full width
- Record button: prominent, red tint, full width
- Divider
- "Recent" section label
- Recording history list (see Section 4)

### 2.2 Recording State

Shown when `appState.isRecording || appState.isPaused`.

**Layout:**
- Header row: "dBrief" title (left), animated REC indicator — pulsing red dot + "REC" label (right)
- Large timer: `title2` monospaced font, left-aligned
- Vertical bar level meter (right-aligned, replaces current horizontal `LevelMeter`): 6–8 bars of varying height, color-coded green → yellow → red by amplitude. Animated at 20 fps via existing `appState.peakLevel`.
- Controls row: Pause (or Resume) button + Stop button, equal width
- Audio source chips row: "🎙 Mic" and/or "🔊 System Audio" — green when active, grey when inactive
- Obsidian folder picker (conditional, unchanged logic)
- Error label (unchanged)

Profile picker is hidden during recording — profile was already selected.

### 2.3 Processing State

Shown when `appState.isProcessing`.

**Layout:**
- Header: "Processing…" title
- Pre-flight memory warning banner (conditional — see Section 5.1): shown at the top of the step list before the relevant model is loaded, if memory is insufficient. Yellow bordered box, warning icon, action buttons.
- Step list: each step shows icon (pending circle / spinning `ProgressView` / green checkmark / red ✕) + step name + optional "⚠ Low RAM" badge (shown when `MemoryPressureMonitor` is in warning/critical state)
- Live inference text: scrollable monospaced view showing `appState.liveInferenceText`, max height 150 pt — already implemented, surfaced here
- Memory bar (new): compact bar at bottom of step list — label "Memory", used/total GB, color-coded fill (green <60%, yellow 60–85%, red >85%). Updates every 2 seconds via `MemoryPressureMonitor.getMemoryStats()`. Hidden on desktop Macs where `total == 0`.
- Cancel button (existing, unchanged)

Transitions automatically to Results State when all steps complete.

### 2.4 Results State (new)

Shown when `appState.hasProcessingResults && !appState.isProcessing`.
Replaces the current step-checklist as the post-processing view.

**Layout:**
- Header row: recording title (left, truncated), duration (right, secondary)
- Status strip: compact inline chips — "✓ Transcribed · ✓ Summary · ✕ AI" — using `appState.processingSteps`. Each step name abbreviated. Failed steps shown in red.
- Collapsible sections — each section has a tappable header row (label + chevron), defaults to expanded:
  - **Summary** — `recording.summary` text, full wrap, `callout` font
  - **Action Items** — bulleted list from `recording.actionItems`, with "+N more" truncation at 3 visible if >3 items (tap header to see all)
  - **Tags & Sentiment** — tag chips + sentiment label
- Retry banner (conditional — shown when AI step failed and a remote endpoint is configured): blue bordered box, "Retry AI with remote endpoint?" + Retry button
- **Pinned action bar** (always visible, not scrollable):
  - "Copy Notes" — primary blue button, copies formatted markdown (existing `ObsidianFormatter.format` logic)
  - "Open File" — reveals markdown file in Finder
  - "Dismiss" — clears `appState.processingSteps`, returns to Idle state

**Partial results:** If transcription succeeded but AI failed, Summary/Action Items/Tags sections are hidden, transcript is shown in a "Transcript" section instead. The recording is not considered failed — files are already on disk.

---

## 3. Recording History

Replaces `RecordingHistoryView` inline list.

### Row (collapsed)

- Play/pause button (`play.circle.fill` / `pause.circle.fill`)
- Recording name (truncated, `callout`)
- Secondary line: date + duration + profile name + AI badge ("✓ AI" in green, or "—" in tertiary if no transcript)
- Disclosure chevron (right)

### Row (expanded, inline)

Tapping a row expands it in place. Other expanded rows collapse. Expanded state shows the collapsed content plus an action chip row:

| Chip | Action |
|---|---|
| Copy Summary | Copies `recording.summary` to pasteboard; shows "Copied!" for 2s. Hidden if no transcript. |
| Open File | `NSWorkspace.shared.selectFile` on the markdown file if it exists, otherwise on the audio file |
| Re-run AI | Calls existing `recordingManager.retryAIAnalysis(for:)` |
| Delete | Confirmation alert → deletes audio + transcript + markdown files, removes from list |

Loading is lazy: `loadRecordings()` called on `.onAppear` and on manual refresh. List capped at 20 most recent entries to keep memory footprint bounded.

---

## 4. Settings — Sidebar Layout

`SettingsView` switches from `TabView` to a two-column layout: fixed-width sidebar (140 pt) + scrollable content area.

### Sidebar sections

| Icon | Label | Notes |
|---|---|---|
| ⚙️ | General | Recording folder, dock icon, shortcut, call detection, permissions. Content from current `SettingsGeneralTab`. |
| 🎙 | Recording | Audio source preference, auto-segmentation threshold. Currently split across General and Transcription tabs — consolidated here. |
| ✨ | AI & Models | Transcription + AI engines, endpoints, prompts, model management |
| 🔗 | Integrations | All 8 destinations (unchanged content) |
| 👤 | Profiles | Profile CRUD, import/export (unchanged content) |

**About** moves to a footer row at the bottom of the sidebar: app version number + small "About" link. No dedicated tab.

**Permissions tab removed.** Content folds into General as a "Permissions" section with a single "Check Permissions" button that opens the relevant system panel, plus inline status indicators (mic: ✓ / ✕, screen recording: ✓ / ✕).

### Existing tab content

All existing settings content is preserved — no settings are removed. `SettingsGeneralTab`, `SettingsTranscriptionTab`, `SettingsAITab`, `SettingsIntegrationsTab`, `SettingsProfilesTab` are refactored into the new sidebar layout, not rewritten from scratch. `SettingsSection` and `SettingsToggleRow` reused throughout.

---

## 5. Memory Hardening

### 5.1 Pre-flight Memory Check

**When:** Immediately before `LocalAIPluginService.transcribe()` or `LocalAIPluginService.analyzeTranscript()` is called in `RecordingManager`.

**Thresholds:**
- WhisperKit (whisper-small): 1.2 GB required
- Qwen3 4B: 4.5 GB required

**Implementation:** Call `MemoryPressureMonitor.hasSufficientMemory(requiredBytes:)`. If it returns `false`:
- If a remote endpoint is configured for that engine type → show the pre-flight warning banner in the Results/Processing view with "Try anyway" and "Use remote endpoint" options. "Use remote endpoint" temporarily overrides the engine selection for this processing run only (does not save to settings).
- If no remote endpoint is configured → show warning banner with "Try anyway" and "Close other apps and retry" suggestion. Processing proceeds on "Try anyway".

**Pre-flight warning banner design:** Yellow border, warning icon, "Low available memory" title, "Local AI requires X GB. Only Y GB available." body, action buttons.

### 5.2 Live Memory Indicator

**When:** Visible during Processing State whenever `MemoryPressureMonitor.getMemoryStats()` returns a non-nil value.

**Update interval:** Every 2 seconds via a `Timer` in `TranscriptionProgressView` (or its replacement). Timer is cancelled when the view disappears.

**Color thresholds:**
- Green: used < 60% of total
- Yellow: 60–85%
- Red: > 85%

**Per-step badge:** When `MemoryPressureMonitor` fires a `.warning` or `.critical` event during processing, the currently in-progress step gains a "⚠ Low RAM" badge (amber text, no icon). This is additive — it does not replace the step's status icon.

**Hidden on:** Desktop Macs (where `total == 0` from `getMemoryStats()`).

### 5.3 Graceful Partial Results

**Current behavior:** If AI analysis throws, the step is marked failed and the view stays in processing state showing a red ✕.

**New behavior:**
- Processing state transitions to Results state regardless of whether all steps succeeded.
- Results state renders whatever is available: transcript section if `recording.transcription != nil`, summary section if `recording.summary != nil`, etc.
- Failed steps shown in the status strip with red ✕ and a short failure reason (first line of the error message, truncated to 60 chars).
- If the AI step failed and a remote endpoint is configured, the retry banner is shown (see Section 2.4).
- `RecordingManager` does not throw on partial failure — it marks steps failed and continues to the next step where possible.

---

## 6. Out of Scope

- Transcript viewer / full transcript browsing (separate feature)
- Search/filter in history (not needed at team scale)
- Waveform display during recording
- Notification center integration beyond existing power-state nudge
- Any changes to audio capture, transcription engines, AI engines, or integration dispatch logic

---

## 7. Files Affected

| File | Change |
|---|---|
| `UI/RecordingControlsView.swift` | Rewrite — four-state layout, vertical level meter |
| `UI/TranscriptionProgressView.swift` | Extend — memory bar, per-step RAM badge, auto-transition to Results |
| `UI/RecordingHistoryView.swift` | Extend — expanded row with action chips, 20-item cap |
| `UI/SettingsView.swift` | Rewrite — sidebar layout |
| `UI/SettingsPermissionsTab.swift` | Delete — folded into General |
| `UI/AboutTab.swift` | Simplify — becomes sidebar footer |
| `UI/ResultsView.swift` | New file — Results State view (collapsible sections, action bar) |
| `Services/MemoryPressureMonitor.swift` | Extend — 2-second polling timer, per-step badge state stream |
| `Services/RecordingManager.swift` | Extend — pre-flight checks, partial failure tolerance |
| `App/AppState.swift` | Extend — `memoryPressureLevel` observable property |
