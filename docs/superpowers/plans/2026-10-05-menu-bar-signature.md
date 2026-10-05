# Menu Bar "Signature" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle the menu bar panel, mini player and call-detected popup to the Pen "Signature · Light / Dark" frames, in all four appearance modes (Light, Dark, Paper, Dark Paper).

**Architecture:** The Signature frames use the Transcript Viewer palette value for value, so the menu reads the existing `\.viewerPalette` (already injected by `AppAppearanceScope`). One small pure resolver adds the status colours (success / danger / warning) per mode. A focused component kit (`MenuPanel*`) replaces native bordered buttons and `Divider()`s; the existing views keep their state, handlers and gating and only swap their chrome.

**Tech Stack:** Swift 6.2, SwiftUI (macOS 14+), swift-testing, SPM.

**Spec:** [docs/superpowers/specs/2026-10-05-menu-bar-signature-design.md](../specs/2026-10-05-menu-bar-signature-design.md) — token table, component measurements, the 12 states, decisions and out-of-scope list. Re-read the Pen frames (`Signature · Light · *`, `Signature · Dark · *`) via the pencil MCP before each visual task; export PNGs with `Export([...], "png", <scratchpad>)` to compare.

**Supersedes:** `docs/superpowers/plans/2026-09-28-menu-bar-panel-restyle.md` (never executed).

**Estimate:** 2–2.5 days total. Tasks 1–3 ≈ 2 h; tasks 4–9 ≈ 1.5–2.5 h each; task 10 ≈ 1.5 h.

## Global Constraints

- macOS 14 minimum; no new package dependencies; no bundled fonts for the menu (system font via `.uiFont`).
- Colours come only from `\.viewerPalette` and `\.menuPanelPalette`. No `Brand.*`, `Color.red/.green/.blue`, `.secondary` or hard-coded hex in restyled menu views.
- Panel card width 360 pt, radius 18, section padding 14 v / 16 h, full-bleed hairlines between sections (spec §3).
- Every text colour reaches 4.5:1 on `surface` in all four modes.
- `reduceNeon` (calm appearance): logo bars and gradient borders flatten to the accent — handled by `palette.brandStops`; never read `Brand.gradient` in the menu.
- Keep every existing action handler, `.disabled(...)` rule, keyboard shortcut and accessibility label. This is presentation only: no change to `RecordingManager`, `AppState`, queue, calendar or capture code.
- The working tree may contain unrelated edits from other sessions (Settings tabs). Stage by pathspec only; never `git add -A`.
- Copy: sentence case ("Recent recordings", "Transcribe file…", "Keep audio only"), ellipsis character `…`.

## Review Focus

1. **Record while processing:** a capture starts while a job runs. Header must say "Recording", the Record/Stop controls must stay live, and the processing section must remain visible below. Pinned by `MenuPanelStatus` tests (Task 2) and the visual pass (Task 10).
2. **Post-recording sheet while an earlier job processes:** the panel shows "Recording completed", not "Processing". Pinned in Task 2.
3. **Long titles / 20 participants / small display:** the completed form scrolls inside a height cap; the footer and Process button stay reachable; titles wrap to 3 lines then truncate with a tooltip. Checked in Task 7 and Task 10.
4. **Missing artifacts in the 3×2 action grid:** no insights → "Copy summary" disabled; no rich transcript → "Transcript" disabled; reprocessing → Delete disabled. The grid never reflows. Checked in Task 6.
5. **Custom accent + Paper modes:** a yellow or very dark accent must still give readable Record label (`onPrimary`) and visible play-circle borders (`accentBorder`). Pinned in Task 1.

---

### Task 1: Menu panel status palette

**Files:**
- Create: `Sources/dBrief/Models/MenuPanelPalette.swift`
- Modify: `Sources/dBrief/UI/ViewerTheme.swift` (environment key)
- Modify: `Sources/dBrief/UI/AppTypography.swift:154-174` (`AppAppearanceScope` injects it)
- Test: `Tests/dBriefTests/MenuPanelPaletteTests.swift`

**Interfaces:**
- Consumes: `ViewerRGB`, `ViewerPalette`, `ViewerAppearanceMode`, `ViewerThemeResolver.resolve(mode:sourceHex:nonNeon:)`, `ViewerThemeResolver.contrast(_:_:)`.
- Produces: `struct MenuPanelPalette { success, successFill, danger, dangerFill, dangerBorder, warning, accentBorder: ViewerRGB }`, `MenuPanelPalette.resolve(mode: ViewerAppearanceMode, base: ViewerPalette) -> MenuPanelPalette`, `EnvironmentValues.menuPanelPalette`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import dBrief

@Suite struct MenuPanelPaletteTests {
    private func palettes(accent: String = "#1268F5") -> [(ViewerAppearanceMode, ViewerPalette, MenuPanelPalette)] {
        ViewerAppearanceMode.allCases.map { mode in
            let base = ViewerThemeResolver.resolve(mode: mode, sourceHex: accent, nonNeon: false)
            return (mode, base, MenuPanelPalette.resolve(mode: mode, base: base))
        }
    }

    @Test func matchesThePenSignatureValues() {
        let light = MenuPanelPalette.resolve(mode: .light, base: ViewerThemeResolver.resolve(mode: .light, sourceHex: "#1268F5", nonNeon: false))
        let dark = MenuPanelPalette.resolve(mode: .dark, base: ViewerThemeResolver.resolve(mode: .dark, sourceHex: "#1268F5", nonNeon: false))
        #expect(light.success.hex == "#23804C")
        #expect(light.danger.hex == "#B93852")
        #expect(light.dangerFill.hex == "#FFF2F5")
        #expect(dark.success.hex == "#7BDCAA")
        #expect(dark.danger.hex == "#FF91A6")
        #expect(dark.dangerFill.hex == "#382935")
    }

    @Test func statusTextIsReadableInEveryMode() {
        for (mode, base, panel) in palettes() {
            #expect(ViewerThemeResolver.contrast(panel.success, base.surface) >= 4.5, "success in \(mode)")
            #expect(ViewerThemeResolver.contrast(panel.danger, base.surface) >= 4.5, "danger in \(mode)")
            #expect(ViewerThemeResolver.contrast(panel.danger, panel.dangerFill) >= 4.5, "danger on fill in \(mode)")
            #expect(ViewerThemeResolver.contrast(panel.success, panel.successFill) >= 4.5, "success on fill in \(mode)")
        }
    }

    @Test func accentBorderFollowsTheConfiguredAccent() {
        let blue = palettes(accent: "#1268F5")
        let orange = palettes(accent: "#E8590C")
        for (b, o) in zip(blue, orange) {
            #expect(b.2.accentBorder != o.2.accentBorder, "accent border ignores accent in \(b.0)")
            // Halfway between primary and surface: visible but quieter than the primary.
            #expect(ViewerThemeResolver.contrast(o.2.accentBorder, o.1.surface) < ViewerThemeResolver.contrast(o.1.primary, o.1.surface))
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter MenuPanelPaletteTests`
Expected: FAIL — `cannot find 'MenuPanelPalette' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Status colours the menu bar panel needs on top of the viewer palette.
/// Light and dark match the Pen "Signature" frames; the paper values are tuned
/// to the paper surfaces and held to 4.5:1 by `MenuPanelPaletteTests`.
struct MenuPanelPalette: Equatable, Sendable {
    let success: ViewerRGB
    let successFill: ViewerRGB
    let danger: ViewerRGB
    let dangerFill: ViewerRGB
    let dangerBorder: ViewerRGB
    let warning: ViewerRGB
    let accentBorder: ViewerRGB

    static func resolve(mode: ViewerAppearanceMode, base: ViewerPalette) -> MenuPanelPalette {
        let hex: (success: String, danger: String, dangerFill: String, dangerBorder: String, warning: String) = switch mode {
        case .light: ("#23804C", "#B93852", "#FFF2F5", "#D5B3C1", "#E0A21B")
        case .dark: ("#7BDCAA", "#FF91A6", "#382935", "#755C6F", "#E0A21B")
        case .paper: ("#3D7046", "#A63A3A", "#F8EAE3", "#D9B2A8", "#C08A2E")
        case .darkPaper: ("#9BD3A4", "#F2A08F", "#3D2C27", "#7A564C", "#D9A54A")
        }
        let success = rgb(hex.success)
        return MenuPanelPalette(
            success: success,
            successFill: rounded(success.mixed(with: base.surface, fraction: 0.92)),
            danger: rgb(hex.danger),
            dangerFill: rgb(hex.dangerFill),
            dangerBorder: rgb(hex.dangerBorder),
            warning: rgb(hex.warning),
            accentBorder: rounded(base.primary.mixed(with: base.surface, fraction: 0.5))
        )
    }

    private static func rgb(_ hex: String) -> ViewerRGB { ViewerRGB(hex: hex)! }
    private static func rounded(_ colour: ViewerRGB) -> ViewerRGB { ViewerRGB(hex: colour.hex)! }
}
```

In `ViewerTheme.swift`, next to the other keys:

```swift
private struct MenuPanelPaletteKey: EnvironmentKey {
    static let defaultValue = MenuPanelPalette.resolve(mode: .light, base: ViewerPaletteKey.defaultValue)
}

extension EnvironmentValues {
    var menuPanelPalette: MenuPanelPalette {
        get { self[MenuPanelPaletteKey.self] }
        set { self[MenuPanelPaletteKey.self] = newValue }
    }
}
```

In `AppAppearanceScope.body`, after `.environment(\.viewerMode, mode)`:

```swift
.environment(\.menuPanelPalette, MenuPanelPalette.resolve(mode: mode, base: palette))
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter 'MenuPanelPaletteTests|ViewerAppearanceTests'`
Expected: PASS. If a paper contrast fails, darken (light modes) or lighten (dark modes) that hex in 5 % steps and record the final value in the spec table.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Models/MenuPanelPalette.swift Sources/dBrief/UI/ViewerTheme.swift Sources/dBrief/UI/AppTypography.swift Tests/dBriefTests/MenuPanelPaletteTests.swift docs/superpowers/specs/2026-10-05-menu-bar-signature-design.md
git commit -m "feat(menu): status palette for the Signature menu panel in all four modes"
```

---

### Task 2: Panel status and progress presentation

**Files:**
- Create: `Sources/dBrief/Models/MenuPanelStatus.swift`
- Test: `Tests/dBriefTests/MenuPanelStatusTests.swift`

**Interfaces:**
- Consumes: `ProcessingStep` / `ProcessingStep.Status` (`App/AppState.swift:104`).
- Produces:
  - `enum MenuPanelStatus { ready, recording, paused, processing, recordingCompleted, briefReady }` with `label: String`, `tone: Tone` (`Tone = success | danger | warning | accent`), and `static func resolve(isRecording:isPaused:isProcessing:showsPostRecording:hasResults:) -> MenuPanelStatus`.
  - `enum MenuPanelProgress` with `static func doneLabel(_ steps: [ProcessingStep]) -> String?` and `static func briefContents(summary: Bool, actions: Bool, tags: Bool, notes: Bool) -> String?`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import dBrief

@Suite struct MenuPanelStatusTests {
    private func status(rec: Bool = false, paused: Bool = false, proc: Bool = false, post: Bool = false, results: Bool = false) -> MenuPanelStatus {
        .resolve(isRecording: rec, isPaused: paused, isProcessing: proc, showsPostRecording: post, hasResults: results)
    }

    @Test func idleIsReady() { #expect(status() == .ready); #expect(status().label == "Ready") }
    @Test func captureWinsOverABackgroundJob() {
        #expect(status(rec: true, proc: true) == .recording)
        #expect(status(paused: true, proc: true) == .paused)
    }
    @Test func reviewFormWinsOverABackgroundJob() {
        #expect(status(proc: true, post: true) == .recordingCompleted)
        #expect(status(proc: true, post: true).label == "Recording completed")
    }
    @Test func processingThenBrief() {
        #expect(status(proc: true) == .processing)
        #expect(status(results: true) == .briefReady)
        #expect(status(results: true).label == "Brief ready")
    }
    @Test func tones() {
        #expect(MenuPanelStatus.ready.tone == .success)
        #expect(MenuPanelStatus.recording.tone == .danger)
        #expect(MenuPanelStatus.paused.tone == .warning)
        #expect(MenuPanelStatus.processing.tone == .accent)
    }

    @Test func countsCompletedSteps() {
        let steps = [
            ProcessingStep(name: "Finalizing audio", status: .completed),
            ProcessingStep(name: "Identifying speakers", status: .completed),
            ProcessingStep(name: "Generating summary", status: .inProgress),
            ProcessingStep(name: "Extracting action items", status: .pending),
            ProcessingStep(name: "Analyzing tags", status: .failed("x")),
        ]
        #expect(MenuPanelProgress.doneLabel(steps) == "2 of 5 done")
        #expect(MenuPanelProgress.doneLabel([]) == nil)
    }

    @Test func briefContentsListsOnlyWhatExists() {
        #expect(MenuPanelProgress.briefContents(summary: true, actions: true, tags: true, notes: true) == "Summary · Actions · Tags · Notes")
        #expect(MenuPanelProgress.briefContents(summary: true, actions: false, tags: false, notes: true) == "Summary · Notes")
        #expect(MenuPanelProgress.briefContents(summary: false, actions: false, tags: false, notes: false) == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter MenuPanelStatusTests`
Expected: FAIL — `cannot find 'MenuPanelStatus' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// What the menu panel header says. Capture always wins (a recording can start
/// while an earlier job processes); the review form wins over background work.
enum MenuPanelStatus: Equatable {
    case ready, recording, paused, processing, recordingCompleted, briefReady

    enum Tone: Equatable { case success, danger, warning, accent }

    static func resolve(isRecording: Bool, isPaused: Bool, isProcessing: Bool, showsPostRecording: Bool, hasResults: Bool) -> MenuPanelStatus {
        if isRecording { return .recording }
        if isPaused { return .paused }
        if showsPostRecording { return .recordingCompleted }
        if isProcessing { return .processing }
        if hasResults { return .briefReady }
        return .ready
    }

    var label: String {
        switch self {
        case .ready: "Ready"
        case .recording: "Recording"
        case .paused: "Paused"
        case .processing: "Processing"
        case .recordingCompleted: "Recording completed"
        case .briefReady: "Brief ready"
        }
    }

    var tone: Tone {
        switch self {
        case .ready, .recordingCompleted, .briefReady: .success
        case .recording: .danger
        case .paused: .warning
        case .processing: .accent
        }
    }
}

enum MenuPanelProgress {
    static func doneLabel(_ steps: [ProcessingStep]) -> String? {
        guard !steps.isEmpty else { return nil }
        let done = steps.filter { if case .completed = $0.status { true } else { false } }.count
        return "\(done) of \(steps.count) done"
    }

    static func briefContents(summary: Bool, actions: Bool, tags: Bool, notes: Bool) -> String? {
        let parts = [(summary, "Summary"), (actions, "Actions"), (tags, "Tags"), (notes, "Notes")]
            .filter { $0.0 }.map { $0.1 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
```

- [ ] **Step 4: Run tests** — `swift test --filter MenuPanelStatusTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Models/MenuPanelStatus.swift Tests/dBriefTests/MenuPanelStatusTests.swift
git commit -m "feat(menu): header status and processing progress presentation"
```

---

### Task 3: Component kit

**Files:**
- Create: `Sources/dBrief/UI/MenuPanelComponents.swift`

**Interfaces:**
- Consumes: `\.viewerPalette`, `\.menuPanelPalette`, `\.isEnabled`, `.uiFont(...)`, `ViewerBrandButtonStyle`.
- Produces (used by Tasks 4–9):
  - `MenuPanelButtonStyle(kind: Kind, height: CGFloat = 33)` — `Kind = .hero | .secondary | .row | .danger | .dangerFilled | .accentOutline | .tile | .dangerTile | .quiet`
  - `MenuPanelSection<Content>(showsDivider: Bool = true, content:)` — 14/16 padding + bottom hairline
  - `MenuPanelSectionHeader<Actions>(title:count:expanded:actions:)` — replaces `RecordingListSectionHeader`
  - `MenuPanelSelectorLabel(text:tint:)` — chrome for `Menu` labels (Profile, Mic, Meeting)
  - `BrandBarsMark(height: CGFloat = 24)`, `MenuPanelLevelBars(level: Float, active: Bool, height: CGFloat)`, `MenuPanelStatusDot(tone:pulse:)`
  - `View.menuPanelCard()` — 360 pt, radius 18, surface fill, divider border, clip

- [ ] **Step 1: Write the kit.** Key pieces (complete the remaining kinds the same way, values from spec §3):

```swift
import SwiftUI

struct MenuPanelButtonStyle: ButtonStyle {
    enum Kind { case hero, secondary, row, danger, dangerFilled, accentOutline, tile, dangerTile, quiet }
    var kind: Kind
    var height: CGFloat = 33
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let radius: CGFloat = kind == .hero ? 11 : 8
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .uiFont(.system(size: kind == .hero ? 18 : 13, weight: kind == .hero ? .semibold : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .quiet ? 0 : 11)
            .frame(maxWidth: kind == .quiet ? nil : .infinity, minHeight: height)
            .background(background, in: shape)
            .overlay { if let border { shape.strokeBorder(border, lineWidth: kind == .accentOutline ? 1.5 : 1).allowsHitTesting(false) } }
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
            .contentShape(shape)
    }

    private var foreground: Color {
        switch kind {
        case .hero: palette.onPrimary.color
        case .danger, .dangerTile: status.danger.color
        case .dangerFilled: .white
        case .accentOutline: palette.heading.color
        case .quiet: palette.secondary.color
        default: palette.text.color
        }
    }
    private var background: Color {
        switch kind {
        case .hero: palette.primary.color
        case .row: palette.canvas.color
        case .danger, .dangerTile: status.dangerFill.color
        case .dangerFilled: status.danger.color
        case .quiet: .clear
        default: palette.surface.color
        }
    }
    private var border: Color? {
        switch kind {
        case .hero, .quiet, .dangerFilled: nil
        case .danger, .dangerTile: status.dangerBorder.color
        case .accentOutline: palette.primary.color
        default: palette.divider.color
        }
    }
}

struct BrandBarsMark: View {
    @Environment(\.viewerPalette) private var palette
    var height: CGFloat = 24
    private let ratios: [CGFloat] = [9, 18, 24, 15, 7].map { $0 / 24 }

    var body: some View {
        HStack(alignment: .center, spacing: height / 12) {
            ForEach(Array(ratios.enumerated()), id: \.offset) { index, ratio in
                RoundedRectangle(cornerRadius: 2)
                    .fill(palette.brandStops[min(index + 1, palette.brandStops.count - 1)].color)
                    .frame(width: height / 8, height: height * ratio)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct MenuPanelSection<Content: View>: View {
    var showsDivider = true
    @ViewBuilder var content: Content
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                if showsDivider { Rectangle().fill(palette.divider.color).frame(height: 1) }
            }
    }
}
```

`MenuPanelLevelBars`: port `LiveWaveStrip`'s level → height mapping (find it with `grep -rn "struct LiveWaveStrip" Sources`), draw 3 pt bars with 3 pt gaps in `palette.primary`, `Canvas` based so 50+ bars stay cheap; honour `accessibilityReduceMotion` by freezing the pattern. `MenuPanelStatusDot`: 7 pt circle in the tone colour (success → `status.success`, danger → `status.danger`, warning → `status.warning`, accent → `palette.primary`), pulse only when `pulse && !reduceMotion`.

- [ ] **Step 2: Build** — `swift build` → no errors, no new warnings in the new file.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/UI/MenuPanelComponents.swift
git commit -m "feat(menu): Signature component kit (buttons, sections, logo bars, level bars)"
```

---

### Task 4: Panel shell — card, header, footer

**Files:**
- Create: `Sources/dBrief/UI/MenuBarView.swift` (move `MenuBarView` out of `DBriefApp.swift:357-525`)
- Modify: `Sources/dBrief/App/DBriefApp.swift` (delete the moved struct and `MenuBarSettingsMenu` once unused)

**Interfaces:**
- Consumes: `MenuPanelStatus.resolve(...)`, `MenuPanelSection`, `MenuPanelButtonStyle`, `BrandBarsMark`, `MenuPanelStatusDot`.
- Produces: `MenuBarView()` with the same initializer; sections composed in the order of spec §4.

- [ ] **Step 1: Move `MenuBarView` verbatim** into the new file. `swift build` → green. Commit: `refactor(menu): move MenuBarView into its own file`.
- [ ] **Step 2: Header.** `BrandBarsMark(height: 24)`, "dBrief" `.uiFont(.system(size: 17, weight: .semibold))` in `heading`, `MenuPanelStatusDot` + `status.label` 12 pt `secondary`. Padding 16 (17 bottom), bottom hairline. Accessibility: one element, label "dBrief, \(status.label)". Remove the header gear (`MenuBarSettingsMenu`).
- [ ] **Step 3: Footer.** `canvas` fill, padding 10/16: `Button { … } label: { Label("Settings…", systemImage: "gearshape") }` with `.keyboardShortcut(",", modifiers: .command)` and `Button("Quit dBrief") { NSApp.terminate(nil) }` with `.keyboardShortcut("q")`, both `MenuPanelButtonStyle(kind: .quiet, height: 25)` at 12 pt. Reuse `closeMenuBarExtraWindow()` before opening settings.
- [ ] **Step 4: Card + layout.** Replace the root `VStack(spacing: 10)` + `.padding(12)` + every `Divider()` with: header, a `ScrollView` (shown only when content exceeds `NSScreen.main.visibleFrame.height - 120`; use `ViewThatFits(in: .vertical)` with the plain `VStack` first) holding the sections, then the footer pinned. Apply `.menuPanelCard()` and `.frame(width: 360)`; background outside the card = `palette.canvas`. Onboarding keeps its current path unchanged.
- [ ] **Step 5: Build, launch `make run-beta`, screenshot the Ready state in Light and Dark.** Header and footer match `cI9JN`/`bnCuX` within 2 pt.
- [ ] **Step 6: Commit** — `git add Sources/dBrief/UI/MenuBarView.swift Sources/dBrief/App/DBriefApp.swift` → `feat(menu): Signature panel shell with status header and settings footer`.

---

### Task 5: Ready and Recording controls, viewer row, import row, video URL panel

**Files:**
- Modify: `Sources/dBrief/UI/RecordingControlsView.swift`
- Modify: `Sources/dBrief/UI/MenuBarView.swift` (viewer row, import row)
- Modify: `Sources/dBrief/UI/YouTubeURLInputView.swift`
- Modify: `Sources/dBrief/UI/MicrophoneInputMenu.swift` (label chrome only, via a `labelStyle`/tint parameter — do not change its menu content)

**Interfaces:**
- Consumes: Task 3 kit, `appSettings.recordHotkey.displayString`, `appState.peakLevel`.
- Produces: nothing new for later tasks.

- [ ] **Step 1: Ready (frame 03).** Hero button 58 pt: `RecordGlyph`-style 20 pt ring + "Record meeting" (keep the existing start action). Below, one `HStack(spacing: 8)`: "Profile" 12 pt `secondary`; the existing profile `Menu` with `MenuPanelSelectorLabel(text: activeProfile.name)` (fills remaining width); `recordHotkey.displayString` 11 pt `secondary`. Delete the centred `⌃ ⌥ ⌘ R` line.
- [ ] **Step 2: Recording (frame 07).** Timer `.uiFont(.system(size: 30, weight: .semibold)).monospacedDigit()` in `heading`; trailing "Recording"/"Paused" 12/500 in `status.danger` / `status.warning`. `MenuPanelLevelBars(height: 37)`. Pause/Resume `.secondary` + Stop `.danger`, height 35, equal width. Mic selector + "System audio" label in `status.success` with `speaker.wave.2`. Obsidian folder block: 12 pt caption, path 13 pt `text`, "Choose…" `.secondary`. Keep "Live Transcript" and the error/recovery notices, restyled with the kit (recovery notice → `successFill` banner with ✕, as in frame 11).
- [ ] **Step 3: Viewer row.** `Label("Transcript viewer", systemImage: "rectangle.split.2x1")` + trailing `arrow.up.right`, `MenuPanelButtonStyle(kind: .row, height: 36)`, in its own `MenuPanelSection` (padding 12/13).
- [ ] **Step 4: Import row.** Two `.secondary` buttons "Transcribe file…" (`doc.badge.plus`) and "YouTube URL…" (`play.rectangle`), 12 pt, height 33; existing `.disabled(!appState.isIdle)` keeps them dimmed while recording (frame 07). Last section: `showsDivider: false`.
- [ ] **Step 5: Video URL panel (frame 06).** Hairline on top, "YouTube / Video URL" 13/600 + ✕ (`.quiet`); field 33 pt with `canvas` fill + `divider` border; "Go" as `.hero` at height 33 width 52 (disabled when the URL is empty — reuse the existing validity check); status line 11 pt `secondary`. Keep the yt-dlp install hint and error text, error text in `status.danger`.
- [ ] **Step 6: Visual check** frames 03, 06, 07 in Light + Dark against the Pen exports. Then `swift test --filter 'ProfileBehaviorTests'` → PASS.
- [ ] **Step 7: Commit** (pathspec the four files) — `feat(menu): Signature ready and recording controls`.

---

### Task 6: Recent recordings and Queue & Recovery

**Files:**
- Modify: `Sources/dBrief/UI/RecordingListComponents.swift`
- Modify: `Sources/dBrief/UI/RecordingHistoryView.swift:167-270`
- Modify: `Sources/dBrief/UI/ProcessingQueueView.swift`
- Test: existing `Tests/dBriefTests/RecordingListPresentationTests.swift`

**Interfaces:**
- Consumes: Task 3 kit, `MenuPanelPalette.success`/`accentBorder`.
- Produces: `RecordingListAction(..., style: .tile)` tile variant (icon over label, height 47).

- [ ] **Step 1: Section headers (frames 03–05).** `RecordingListSectionHeader` renders title 13/600 `heading` + count 11 `secondary` inline (move today's subtitle into the count slot when it is a number; otherwise keep it as an 11 pt line under the title — the queue uses this for "Processing" / "No pending work", frames 11–12). Chevron `chevron.right`/`chevron.down` 11 pt. Refresh: 28 pt `.quiet` icon button.
- [ ] **Step 2: Rows (frame 04).** Leading play button: 30 pt circle, `surface` fill, 1 pt `accentBorder`, `play.fill`/`pause.fill` 12 pt in `primary`. Title 13/500 `heading`; meta 11 pt `secondary`; `RecordingListStatus` tint for Analyzed = `status.success` (map in `HistoryItem.status.tint` → move tint choice into the view so it reads the palette). Rows are separated by hairlines, not backgrounds; remove the `Brand.violet` selected/hover fill (use `palette.selected` for the playing row only).
- [ ] **Step 3: 3×2 action grid.** Replace the `FlowLayout` with `Grid(horizontalSpacing: 6, verticalSpacing: 6)` of two `GridRow`s: [Copy summary, Show in Finder, Reprocess] / [Transcript, Integrations, Delete]. Every tile always renders; availability becomes `.disabled(...)`:
  - Copy summary → `.disabled(!item.hasTranscript)`; label stays "Copy summary" (falls back to transcript text exactly as today; help text says which).
  - Show in Finder → always enabled (drop the Open File / Show in Finder swap; Open File remains in the viewer).
  - Reprocess → existing `ReprocessingMenu`, label chrome = tile.
  - Transcript → `.disabled(!item.hasRichTranscript)`.
  - Integrations, Delete → existing rules; Delete uses `.dangerTile`.
- [ ] **Step 4: Queue empty state (frame 05).** `tray` icon, "No pending work" 13/600, caption 12 pt `secondary`. Do **not** add "Pause queue" (spec §6). Queue row actions keep their variable set as compact `.secondary` buttons (height 28), not the tile grid.
- [ ] **Step 5: Mini player strip** in the history list: restyle to `canvas` strip with hairline; no behaviour change.
- [ ] **Step 6:** `swift test --filter RecordingListPresentationTests` → PASS. Visual check frames 04 and 05 in Light + Dark, plus one row with no insights (Copy summary disabled) and one without a rich transcript.
- [ ] **Step 7: Commit** (pathspec) — `feat(menu): Signature recent recordings grid and queue section`.

---

### Task 7: Recording completed and delete confirmation

**Files:**
- Modify: `Sources/dBrief/UI/PostRecordingSheet.swift`
- Test: existing `PostRecordingActionStateTests`, `PostRecordingAutomationTests`

**Interfaces:**
- Consumes: Task 3 kit; existing `BrandCheckRow` toggles (`transcribe`, `summary`, `actionItems`, `tags`), `TokenField`, calendar picker, `refreshCalendarPicker(for:force:)`.
- Produces: none.

- [ ] **Step 1: Title block (frame 08/09).** Centred title `.uiFont(.system(size: 22, weight: .semibold))`, `.lineLimit(3)`, `.help(fullTitle)`; meta line 12 pt `secondary`: duration · size · `Label("Calendar linked", systemImage: "calendar")` when linked. Hairline below.
- [ ] **Step 2: Meeting details.** Header row "Meeting details" 13/500 `heading` + trailing `.quiet` "Refresh" with `arrow.clockwise` (keep the spinner while refreshing). Meeting picker label → `MenuPanelSelectorLabel` at height 36. "Updated at …" 11 pt `secondary`. Calendar attendees: existing "Load during processing" toggle + "Load now" `.secondary` button with `person.2`.
- [ ] **Step 3: Participants.** Label "Participants" / "Participants (n)"; `TokenField` inside a `canvas` box (radius 10, `divider` border, padding 12); token chips `palette.selected` fill, `heading` text, ✕. Caption "Matched to speakers in order of first appearance." centred 11 pt. Keep the 168 pt internal cap and Return/token editing.
- [ ] **Step 4: Processing settings row.** Replace the inline `BrandCheckRow` list with a disclosure row: "Processing settings" 13/500 + "\(profile.name) profile · \(n) tasks selected" 11 pt + `chevron.right`. Tapping expands the existing checkboxes (and the existing output-folder control) **inline** below it with `chevron.down` — same `@State` bindings, so automation and validation are untouched. `n` = count of true among the four toggles (when `transcribe` is false, n = 0).
- [ ] **Step 5: Actions.** Hero "Process recording" (`play` icon) height 44; caption "Output folder · \(folderName)" 11 pt centred; row: "Keep audio only" (= existing Skip handler) `.secondary`, "Queue" `.secondary`, and a `.quiet` `•••` `Menu` containing "Delete recording…" which sets the existing delete-confirmation state.
- [ ] **Step 6: Delete confirmation (frame 10).** When confirming, the actions area is replaced in place by a card: `dangerFill` + `dangerBorder`, radius 10, padding 16: "Delete this recording?" 13/600 `heading`, "The audio file is permanently removed from disk. This can’t be undone." 12 pt `text`, trailing "Cancel" `.secondary` and "Delete" `.dangerFilled` (existing handlers). Escape = Cancel.
- [ ] **Step 7: Scrolling.** The form scrolls (Task 4's `ViewThatFits`); keep focus-scroll for the participant field. Check with 20 participants on a 13" display: footer and Process button reachable.
- [ ] **Step 8:** `swift test --filter 'PostRecordingActionStateTests|PostRecordingAutomationTests|ProfileBehaviorTests'` → PASS. Visual check frames 08, 09, 10 in Light + Dark.
- [ ] **Step 9: Commit** (pathspec) — `feat(menu): Signature recording-completed review and delete confirmation`.

---

### Task 8: Processing and Brief ready

**Files:**
- Modify: `Sources/dBrief/UI/TranscriptionProgressView.swift`
- Modify: `Sources/dBrief/UI/ResultsView.swift`
- Test: existing `ResultsViewTests`

**Interfaces:**
- Consumes: `MenuPanelProgress.doneLabel`, `MenuPanelProgress.briefContents`, `ViewerBrandButtonStyle`, Task 3 kit.

- [ ] **Step 1: Processing (frame 11).** Header "Processing recording" 16/600 + trailing `doneLabel` 12 pt `secondary`. Step rows (spacing 14): icon 18 pt — completed `checkmark.circle` in `status.success`; inProgress `ProgressView().controlSize(.small)` tinted `primary`; pending `circle` in `divider`; failed `xmark.circle` in `status.danger` — name 14 pt (`secondary` when completed, `heading` otherwise), detail 11 pt. Engine caption 12 pt `secondary`. Keep the Low RAM tag (now `status.warning` text). Actions: Stop `.danger` (fixed width ~70) + "View transcript" `.secondary` (`text.viewfinder`) filling the rest; keep Review speakers / Close.
- [ ] **Step 2: Brief ready (frame 12).** Title 22/600 centred; "date · duration" 12 pt; `checkmark.circle` + `briefContents(...)` in 12 pt `secondary` with the icon in `status.success`. "Summary" 13/600 + summary paragraph 14 pt `text` (`lineLimit(4)`). "More details" disclosure (`chevron.right` 11 pt, 13 pt `secondary`) expands the existing action-item / tags / transcript sections. Primary action: "View transcript" with `ViewerBrandButtonStyle(height: 40)`; row: "Copy notes" `.secondary` + "Open file" `.secondary` (existing disabled rule when the file is missing). Partial-failure notes (recovered export, integrations not sent, AI failure + Retry) render as one hairline-topped row: `chevron.right` + 12 pt text + ✕. "Dismiss brief" `.quiet` centred (existing Dismiss handler).
- [ ] **Step 3:** `swift test --filter ResultsViewTests` → PASS. Visual check frames 11 and 12 in Light + Dark, plus a transcript-only result (no AI) and an AI-failure result.
- [ ] **Step 4: Commit** (pathspec) — `feat(menu): Signature processing progress and brief`.

---

### Task 9: Call-detected popup and mini player

**Files:**
- Modify: `Sources/dBrief/UI/CallDetectedPopup.swift`
- Modify: `Sources/dBrief/UI/FloatingMiniPlayer.swift:103-285`
- Modify (only if it shares `CallDetectedPopup`'s chrome): `Sources/dBrief/UI/CallEndedPopup.swift`

- [ ] **Step 1: Popup (frame 01).** Card radius 16, `surface` fill, 1.5 pt border `LinearGradient(palette.brandStops)` (flat when calm). Leading `BrandBarsMark(height: 40)`; "\(app) call detected" 16/600 `heading`; caption 12 pt `secondary`; ✕ 28 pt `.quiet` top-right; actions trailing: "Not now" `.secondary` and "Record call" `.accentOutline` with `mic`, height 37. Keep the auto-dismiss timer and existing handlers.
- [ ] **Step 2: Mini player (frame 02).** 298 pt card, radius 14. Header strip on `canvas` with bottom hairline: `BrandBarsMark(height: 20)`, "dBrief" 13/600, `MenuPanelStatusDot(.danger)` + "Recording" 13/500, timer 15/600 monospaced, collapse chevron 28 pt. Body: `MenuPanelLevelBars(height: 26)`, Pause `.secondary` + Stop `.danger`, height 36. Keep drag area and collapse behaviour.
- [ ] **Step 3: Visual check** frames 01 and 02 in Light + Dark; trigger the popup via the existing debug path (or a Zoom/Teams call), mini player via a test recording.
- [ ] **Step 4: Commit** (pathspec) — `feat(menu): Signature call popup and mini player`.

---

### Task 10: Paper modes, accessibility and acceptance

**Files:** this plan (tick boxes + results), the spec (final paper hex values if changed). No source changes unless a check fails.

- [ ] **Step 1:** `swift test` (full suite). Record the result. Load-related timing flakes: re-run the failing suite alone and compare against `main` before treating it as a regression.
- [ ] **Step 2:** `make run-beta`. For each of Light, Dark, Paper, Dark Paper (Settings → Appearance), capture states 03, 04, 07, 08, 11, 12, the popup and the mini player. Compare Light/Dark against the Pen PNG exports; for Paper check warm surfaces, no cold blue-grey leftovers, readable status colours.
- [ ] **Step 3:** Set accent to orange `#E8590C` and to a dark green; check the Record button label, play circles and level bars. Turn on Reduce neon: logo bars and gradient borders flat.
- [ ] **Step 4:** Review Focus checks 1–5 by hand (record while processing; review form during a job; 20 participants on a small display; missing artifacts grid; custom accent in Paper).
- [ ] **Step 5:** VoiceOver pass over header, Record, list rows, tiles, processing steps; keyboard: Tab reaches all controls, ⌘, and ⌘Q work, Escape cancels delete. Reduced Motion: no pulsing dot, static level bars.
- [ ] **Step 6:** `grep -nE "Brand\.|Color\.(red|green|blue|orange)|\.foregroundStyle\(\.secondary\)" Sources/dBrief/UI/{MenuBarView,MenuPanelComponents,RecordingControlsView,RecordingListComponents,RecordingHistoryView,ProcessingQueueView,PostRecordingSheet,TranscriptionProgressView,ResultsView,YouTubeURLInputView,CallDetectedPopup,FloatingMiniPlayer}.swift` → only intentional leftovers, each justified in the commit message.
- [ ] **Step 7: Commit** plan/spec updates — `docs(menu): Signature acceptance results`.

## Completion criteria

All 12 Signature states match the Pen frames in Light and Dark (composition, spacing within 2 pt, palette), and render coherently in Paper and Dark Paper with the configured accent. Existing recording, processing, queue and review behaviour is unchanged; the full test suite passes; `make run-beta` builds and launches.
