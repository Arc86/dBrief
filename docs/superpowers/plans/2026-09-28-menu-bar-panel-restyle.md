# Menu Bar Panel Restyle Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task in the current chat. Steps use checkbox (`- [ ]`) syntax for tracking. Do not start implementation until the user has reviewed the plan.

**Goal:** Restyle dBrief's menu bar panel to match the four light and dark Pen mockups while keeping existing recording and processing workflows.

**Architecture:** Keep the existing `MenuBarExtra` and observation/environment model. Extract its panel view into a focused UI file and add panel-specific design tokens and button/card styles. Restyle the current child views without changing recording, persistence or queue services.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit, Swift Package Manager; macOS 14 minimum.

**Spec:** [Design reference](../specs/2026-09-28-menu-bar-panel-restyle.md). Re-read the Pen frames through MCP before implementing if the canvas has changed.

**Estimate:** 2–3 hours of implementation and visual verification, assuming the existing release build works. Native execution in this chat is recommended: these are tightly coupled presentation changes using existing actions.

## Global Constraints

- macOS 14 minimum; no new dependencies or font downloads.
- Four panel states, both light and dark; use the exact palette and baseline measurements in the spec.
- Keep current action handlers, gating, profile selection, keyboard shortcuts and observation bindings.
- Preserve existing local edits, especially `Sources/dBrief/App/DBriefApp.swift`. Initial worktree also contains audio fixes and unrelated UI changes; do not stage or revert them.
- Scope excludes meeting viewer, settings redesign, onboarding redesign, call popups and floating player. Avoid editing global `BrandKit.swift` or `TranscriptDesignTokens.swift` to achieve panel styling.

## Review Focus

1. Small display / large participant roster: review form scrolls; Skip, Queue, Process and footer remain reachable.
2. Long recording/profile names and unavailable artifacts: titles truncate with help; actions retain existing availability and disabled rules.
3. Pause, processing failure and recovery warnings: state remains truthful, with working Resume, Retry and dismissal actions.
4. Keyboard, VoiceOver, calm appearance and Reduced Motion: controls remain identifiable and reachable without animation.
5. Switching recent/queue expansion during playback or changing profile during review: playback continues and recording-specific profile semantics remain intact.

For a presentation-only change, use visual and interaction checks plus existing meaningful tests. Do not add tests that merely assert color constants or duplicate SwiftUI code.

---

## Task 1: Panel foundation and shell (30–40 minutes)

**Files**
- Create `Sources/dBrief/UI/MenuBarDesignTokens.swift`: scoped palette and measurements.
- Create `Sources/dBrief/UI/MenuBarComponents.swift`: button styles and card modifier.
- Create `Sources/dBrief/UI/MenuBarView.swift`: move the existing `MenuBarView` here.
- Modify `Sources/dBrief/App/DBriefApp.swift`: remove only the extracted view definition; retain `MenuBarExtra` and existing app changes.

**Interfaces**
- Consume existing `AppState`, `AppSettings`, `RecordingManager`, `openWindow` environment values.
- Keep the externally used `MenuBarView()` initializer unchanged.
- Produce `MenuBarPalette(scheme:)` with colors from the spec, plus `MenuBarButtonStyle(kind:height:radius:)` and `.menuBarCard(radius:padding:)`.
- Button `Kind`: `.primary`, `.secondary`, `.stop`, `.destructive`, `.quiet`; style reads color scheme, enabled state, calm appearance and pressed state.

- [ ] Capture baseline screenshots and current diff before editing. Use the current local source; do not reset the repository.
- [ ] Define tokens with explicit light/dark mapping, following the existing `Color(hex:)` utility. Starting implementation:

```swift
struct MenuBarPalette {
    let scheme: ColorScheme
    var panel: Color { Color(hex: scheme == .dark ? "0D1423" : "F9FBFE") }
    var card: Color { Color(hex: scheme == .dark ? "121A2B" : "FFFFFF") }
    var control: Color { Color(hex: scheme == .dark ? "1A2538" : "E9EDF3") }
    var text: Color { Color(hex: scheme == .dark ? "F4F7FC" : "0B1430") }
    var muted: Color { Color(hex: scheme == .dark ? "8D99AE" : "6D7892") }
}
```

Extend with all named roles from the spec; keep gradient and dimension constants in the same file. Styles must use `@Environment(\.isEnabled)` and `configuration.isPressed`; native buttons retain their focus and accessibility behavior.

- [ ] Extract `MenuBarView` and update its section composition: 450-point target width, 20-point padding, 12-point section gap, 34-point existing logo, 17-point title. Replace divider-heavy layout with the reference surfaces. Show active Recording/Paused/Processing status; omit the idle Ready pill to match Pen.
- [ ] Style viewer/import/footer actions. Use “Open meeting viewer”, “Transcribe file…”, “YouTube URL…”, “Settings…”, “Quit dBrief”. Preserve viewer window id `transcript`, Settings close behavior and all current action closures.
- [ ] Add display-aware height capping using the screen containing the status-bar window, with visible-frame height minus a 40-point safety margin. Use natural content height until capped. Scroll overflowing content; keep footer outside scrolling. Do not enforce mockup heights or add a second heavy shadow over native popover chrome.
- [ ] Build with `swift build --target dBrief`. Inspect light/dark idle shell; verify ⌘, and ⌘Q bindings and onboarding branch still work.

## Task 2: Idle and active recording controls (25–35 minutes)

**Files:** modify `Sources/dBrief/UI/RecordingControlsView.swift`; use the new components. Style `MicrophoneInputMenu.swift` / `ObsidianFolderPicker.swift` only with an opt-in panel mode if caller-side modifiers are insufficient.

**Interfaces:** Keep `RecordingControlsView()` and `LiveWaveStrip(level:active:)` entry points. Consume existing `recordingManager` actions, audio permissions, device selection, `appState.peakLevel` and duration.

- [ ] Wrap idle profile and record button in the reference capture card. Make the selector 156 × 34, the CTA 54 points tall, and place the current recording shortcut hint inside the button as a visual badge. The badge does not install a competing shortcut handler.
- [ ] Apply the recording layout: 42-point timer with `.monospacedDigit()`, 58-point waveform, equal Pause/Resume and Stop buttons at height 58, green source labels, optional folder label/path and Choose action.

```swift
Text(formattedDuration)
    .font(.system(size: 42, weight: .bold))
    .monospacedDigit()

LiveWaveStrip(level: appState.peakLevel, active: appState.isRecording)
    .frame(height: 58)
```

Use purple-to-blue waveform fill rather than global brand fill. Respect `accessibilityReduceMotion`; maintain meaningful live amplitude without decorative pulse animations when disabled.

- [ ] Keep the current start/pause/resume/stop closures, error copy/dismiss, recovery notices, microphone switching, live-transcript link and folder persistence. Do not make system-audio availability unconditional.
- [ ] Check start → pause → resume → stop in a safe test session; check timer after one hour, missing microphone/system-audio permissions, disabled imports, long device and folder names. Compare against `sUu5f` / `JuhXW` and their idle equivalents.

## Task 3: Recent recordings and Queue & Recovery (25–35 minutes)

**Files:** modify `RecordingListComponents.swift`, `RecordingHistoryView.swift`, `ProcessingQueueView.swift`; all under `Sources/dBrief/UI/`.

**Interfaces:** Retain `RecordingHistoryView(expanded:)`, `ProcessingQueueView(expanded:)`, shared list generic closures, status data and action callbacks. Any new visual variant parameters must have defaults so queue rows remain valid callers.

- [ ] Update section type hierarchy, compact refresh button and disclosure geometry. Queue gets the bordered rounded card; recent list remains flat.
- [ ] Replace violet row emphasis and playback circles with reference blue surfaces. Use selected/expanded row radius 14 and collapsed row radius 10; adapt leading play diameter to 40/36 without breaking non-playback queue rows.
- [ ] Replace history `FlowLayout` actions with two flexible three-column rows. Order: Copy summary/transcript, Show in Finder/Open file, Transcript; Reprocess, Integrations, Delete recording. Keep existing artifact gating and menus; missing artifacts use disabled controls rather than invoking nonexistent files.

```swift
let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
LazyVGrid(columns: columns, spacing: 6) {
    // Retain each existing action closure and its availability condition.
}
```

Apply 34-point action styling to the existing `RecordingListAction` wrappers; do not nest playback buttons inside disclosure buttons. Keep the queue's variable action set flexible instead of forcing the history grid on every queue row.

- [ ] Retain existing bounded list scrolling, mini-player, refresh task cancellation, queue editing locks, recovery detail, reprocessing window presentation and the mutually exclusive list expansion behavior.
- [ ] Run `swift test --filter RecordingListPresentationTests`. Verify empty/recent/queued/recovery states, expanded actions, long titles and list switching while audio plays. Review all six history actions in both schemes.

## Task 4: Completion review and output (30–45 minutes)

**Files:** modify `Sources/dBrief/UI/PostRecordingSheet.swift`, `ResultsView.swift`, `TranscriptionProgressView.swift`. Reuse existing `TokenField` and native text input. Limit any styling changes to shared inputs/folder controls to an opt-in panel variant.

**Interfaces:** Keep `PostRecordingSheet()`, `ResultsView()`, and `TranscriptionProgressView(onCancel:)`. Preserve review-local state, profile resolution, participant loading, result sections and processing-step status.

- [ ] Restyle completion header, profile badge, metrics, title and participant surfaces, checkbox rows, folder selection and bottom action row from `b65oAI` / `bdnji`. Preserve all existing validation, calendar details, automation countdown, endpoint warnings and integration destinations. Keep delete confirmation.
- [ ] Place the existing review form in bounded scrolling when needed, with its existing status/action controls below it. Preserve participant field's internal 168-point cap and native Return/token editing. Check keyboard focus scrolls fields into view.
- [ ] Restyle output from `A5FmqI` / `gWX10`: “Meeting notes” header, duration, real success/failure indicators, collapsible transcript/summary/action/tag surfaces, and four equal-width action slots. Use “Copy notes”, “Open file”, “Transcript”, “Done”; make Done the blue primary action and reuse the current Dismiss handler.

```swift
Button("Done") {
    appState.processingSteps.removeAll()
    appState.preflightWarning = nil
}
.buttonStyle(MenuBarButtonStyle(kind: .primary, height: 40, radius: 9))
```

Do not remove summary/action/tag content just because the reference shows only a transcript. Keep existing output content scrolling, real copy status, missing-file disabling and rich-transcript availability.

- [ ] Bring processing progress into the same palette while preserving cancellation, retry, step details and partial failures. Show success only when the current result is actually successful.
- [ ] Run `swift test --filter 'PostRecordingActionStateTests|PostRecordingAutomationTests|ProfileBehaviorTests|ResultsViewTests'`. Visually check review with many participants, review profile different from the active capture profile, busy queue, automation pending, transcript-only output, AI failure and missing markdown file.

## Task 5: Release build and visual acceptance (15–25 minutes)

**Files:** update the plan checkboxes and add concise verification results here. No source changes unless verification finds a defect.

- [ ] Run the relevant existing test suites once after the final changes; run additional tests only for failures or newly changed behavior. Record actual results and any pre-existing failures.
- [ ] Run `make app` to produce the release `dBrief.app`. Launch only when it will not interrupt an active recording. Do not substitute debug-only compilation for the final bundle check.
- [ ] Capture and compare all four states in light and dark against the eight Pen references. Check section ordering, width, padding, fonts, button heights and real enabled/disabled states. On a small display, all controls remain reachable and nothing is clipped.
- [ ] Verify keyboard focus, VoiceOver names/values, Reduced Motion and calm appearance. Confirm settings/viewer/import/YouTube entry, playback, queue recovery and post-recording actions still work.
- [ ] Inspect the final diff against the initial baseline. Confirm no unrelated local edits were removed or included inadvertently. Report implementation, release-build result, meaningful tests and any remaining visual limitation.

## Completion criteria

All four menu-panel states match the corresponding light/dark designs in composition and palette. Existing operations and runtime exceptions remain available. Smaller displays scroll safely, and the final release bundle builds. No change to audio capture services is needed for this restyle.
