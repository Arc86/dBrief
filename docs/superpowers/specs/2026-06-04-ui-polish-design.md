# UI Polish — Design Spec

**Date:** 2026-06-04  
**Scope:** Four independent polish items: record button tint, level meter system audio, mini-player collapse, recent recordings list.

---

## A · Record/Stop button inconsistently red

**Root cause:** `.borderedProminent` buttons lose their custom `.tint()` when the menu bar popover window is not "key" (focused). macOS renders them grey in inactive windows, which is the typical state of a `MenuBarExtra` popover between user interactions.

**Fix:** Add `.environment(\.controlActiveState, .active)` to the `HStack` wrapping the control buttons inside `RecordingControlsView`. This tells SwiftUI to always render buttons as if the window is active, which is semantically correct — the popover is only visible when the user has deliberately opened it.

**File:** `Sources/dBrief/UI/RecordingControlsView.swift` — the `HStack(spacing: 12)` at the bottom of the controls VStack.

---

## B · Level meter reacts to mic only

**Root cause:** `AudioCaptureManager.startTimer()` computes `peakLevel` using nil-coalescing:

```swift
self.peakLevel = self.micWriter?.peakLevel ?? self.systemWriter?.peakLevel ?? 0
```

When both writers exist (mixed mode), `micWriter?.peakLevel` always wins — even when it's 0 and system audio is loud. The system audio level is silently discarded.

**Fix:** Take the maximum of both sources:

```swift
self.peakLevel = max(self.micWriter?.peakLevel ?? 0, self.systemWriter?.peakLevel ?? 0)
```

Whichever source is louder drives the meter. This is correct in all modes: mic-only (systemWriter is nil → 0), system-only (micWriter is nil → 0), mixed (max of both).

**File:** `Sources/dBrief/Audio/AudioCaptureManager.swift` line 241.

---

## C · Floating mini-player collapse

**Behaviour:** A chevron button (`chevron.up` / `chevron.down`) in the top-right of the panel toggles between expanded and collapsed states. Collapsed state hides the waveform and action button row, showing only the top status row (app icon + red dot + "Recording/Paused" label + monospaced timer). No persistence — always starts expanded when a recording session begins.

**Architecture:**

1. Add `var isCollapsed: Bool = false` to `FloatingMiniPlayerController` (already `@Observable`).
2. Add `func toggleCollapse()` to the controller that flips `isCollapsed` and calls `updatePanelSize()`.
3. `updatePanelSize()` reads `hosting.fittingSize` after the layout settles and calls `window.setContentSize()`, then re-anchors the panel to the top-right of the screen (same logic as the initial positioning in `show()`).
4. `MiniPlayerView` reads `isCollapsed` from the controller via a new `@Environment` or direct injection, and wraps the waveform + buttons in `if !isCollapsed`.
5. The chevron button in `MiniPlayerView` calls `controller.toggleCollapse()`.

**Panel injection:** The controller passes itself into `MiniPlayerView` via `.environment()` so the view can call `toggleCollapse()` without needing a callback closure.

**Sizing:** After `isCollapsed` changes, SwiftUI recomputes layout on the next render pass. The controller calls `updatePanelSize()` inside a short `DispatchQueue.main.async` to let SwiftUI finish layout before reading `fittingSize`. The panel position is re-anchored to keep the top-right corner stationary.

**Collapsed dimensions (approximate):** 220 × 40px (same width, just the top row + padding).

---

## D · Recent Recordings list

### Sizing fix

Replace `.frame(maxHeight: 260)` with `.frame(height: 200)` on the `ScrollView`. A fixed height eliminates the ambiguous intrinsic-size calculation that causes the tiny-render bug at launch. 200px fits ~4 collapsed rows comfortably and is a reasonable default for the 360px-wide popover.

### Display name

Add `var displayName: String` computed property to `HistoryItem`:

```swift
var displayName: String {
    let parts = name.split(separator: "_", maxSplits: 2)
    guard parts.count == 3 else { return name }
    return parts[2].replacingOccurrences(of: "-", with: " ")
}
```

This strips the `YYYY-MM-DD_HHMM_` prefix produced by `RecordingFinalizer` and converts hyphens back to spaces. If the filename doesn't match the expected pattern (e.g. user-dropped file), falls back to the raw name.

Use `displayName` in place of `item.name` in `historyRow`.

### Relative timestamps

Replace the `formattedDate` implementation with a relative formatter:

- **Same day:** "Today 7:38 PM"
- **Previous day:** "Yesterday 2:15 PM"
- **Within 7 days:** day-of-week + time ("Mon 3:00 PM")
- **Older:** short month + day ("Jun 4") — omit year unless different calendar year

Implementation: use `Calendar.current` to compare date components against `Date.now`. No third-party dependency needed.

---

## Files changed

| File | Change |
|------|--------|
| `Sources/dBrief/UI/RecordingControlsView.swift` | Add `.environment(\.controlActiveState, .active)` to button HStack |
| `Sources/dBrief/Audio/AudioCaptureManager.swift` | `max(mic, system)` for peakLevel |
| `Sources/dBrief/UI/FloatingMiniPlayer.swift` | Add `isCollapsed` + `toggleCollapse()` to controller; collapse logic in `MiniPlayerView` |
| `Sources/dBrief/UI/RecordingHistoryView.swift` | Fixed height, `displayName`, relative timestamps |

No new files. No new dependencies. No changes to `AppState`, `AppSettings`, or any service layer.
