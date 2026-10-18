# Transcript Viewer Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Use delegation only if the user authorizes that execution method.

**Goal:** Implement the approved Pen-inspired Transcript Viewer with four document tabs, a separate assistant, four appearance modes, consistent configurable accents, Non-neon, reading preferences, time-correct speaker playback, and answer export.

**Architecture:** Keep SwiftUI/AppKit and the existing recording, insights, chat, audio, and recovery services. Introduce shared appearance/reading preferences and semantic palette resolution, then compose the existing detail view from focused presentation components. Preserve the recycling transcript List and current persistence paths.

**Tech Stack:** Swift 6.2, macOS 14+, SwiftUI, AppKit, Foundation, existing Swift Testing suite. No new UI framework or AI dependency.

**Spec:** `docs/superpowers/specs/2026-09-28-transcript-viewer-redesign.md`.

## Global Constraints

- Minimum macOS version: 14; Swift tools version: 6.2.
- Implementation: SwiftUI and AppKit; no new third-party UI framework.
- Transcript rendering: retain the recycling List and stable transcript segment/turn IDs.
- Storage: preserve existing recording, transcript, insights, chat, and privacy-receipt formats.
- Recording and AI engines: no changes to capture, transcription, inference, routing, or recovery behaviour.
- Appearance and reading preferences: app-wide, not meeting-profile overrides.
- Playback panel: visible only in the finished-recording Transcript tab; no playback panel in Summary, Actions, or Meeting Insights.
- Content maximum width: 920 pt, shared across all four tabs and the Transcript playback panel.
- Non-neon: reuse the existing reduceNeon preference; no second competing preference.
- Button interiors: plain theme surface; no inward colour bleed or ambient neon glow.

## Review Focus

1. Existing/invalid stored preferences: preserve old point sizes, speaker names, assistant state and Non-neon; invalid values recover without modifying meeting profiles. Owned by Task 1.
2. Long or partially unavailable recording content: stable selection/list memory, aligned columns, honest missing-data states, and working live/recovery views. Owned by Task 2.
3. Failed or concurrent insights edits: completion and edits reflect actual saved data, with no overwritten unrelated fields. Owned by Task 3.
4. Missing/zero-duration audio and sparse/overlapping speaker segments: no invalid seek or false waveform speaker attribution. Owned by Task 4.
5. Streaming/reasoning-bearing chat and export cancellation/write failure: export only the answer, preserve conversation, and report failures without losing state. Owned by Task 5.

## Preparation and sequencing

Estimate: 5–8 engineering days including integration and native visual/regression review; revise after the first stage. Each task below produces an independently reviewable result. Execute sequentially because the later views consume shared preferences/palette contracts.

The checkout already contains unrelated modified app/audio/AI/summary files and tests. Before implementation, record the current status and account for those edits. Use a suitable isolated managed worktree for execution if needed. Do not revert or include other work in redesign commits. This plan does not authorize shipping or changing the user's recordings.

```sh
git status --short
swift test --filter 'TranscriptSearchTests|ChatMessageActionsTests|RecordingInsightsTests|AppSettingsTests'
```

Record pre-existing test failures separately. Read both this plan and the design spec before changing app code. Existing resources are excluded from the Swift package target and copied by Makefile; keep that packaging pattern when adding fonts/icons.

## File responsibilities

| Responsibility | Existing files | New files |
| --- | --- | --- |
| Preferences and semantic palette | `App/AppSettings.swift`, `UI/SettingsGeneralTab.swift`, `UI/SettingsSearch.swift`, `UI/TranscriptDesignTokens.swift`, `UI/Theme.swift` | `Models/ViewerAppearancePreferences.swift`, `UI/ViewerTheme.swift`, `UI/ViewerReadingOptions.swift`, `UI/ViewerBrandButtonStyle.swift` |
| Viewer shell and modes | `UI/TranscriptBrowserView.swift`, `UI/TranscriptWindowView.swift` (`TranscriptDetailView`) | `Models/ViewerPresentationPolicy.swift`, `UI/ViewerHeader.swift` |
| Analysis presentation | `UI/SummaryView.swift`, existing InsightsStore callbacks | `UI/RecordingActionsView.swift`, `UI/MeetingInsightsView.swift`, `UI/RecordingAnalysisEditor.swift` |
| Playback timing | `UI/TranscriptPlayerBar.swift` (also contains SpeakerStripSegment/ActivityStrip), `UI/WaveformView.swift`, `UI/TranscriptWindowView.swift`, existing AudioPlayer | `Models/SpeakerTimeline.swift` |
| Assistant/export | `UI/TranscriptChatView.swift`, `Models/TranscriptChat.swift`, existing chat service | `Services/ChatAnswerExport.swift` |

Use `Sources/dBrief/` as the prefix for all listed implementation paths. Do not create a second recording browser or duplicate service ownership. Replace obsolete token use within the viewer incrementally; do not globally change unrelated consumers of Theme.

## Task 1: Shared appearance, reading preferences, and settings

**Files:** create the five appearance/reading files above; modify AppSettings, SettingsGeneralTab, SettingsSearch, TranscriptDesignTokens, and relevant Settings reset/search tests. Create `Tests/dBriefTests/ViewerAppearanceTests.swift` and `ViewerPreferenceTests.swift`. Add approved OTF/TTF fonts and licence notices under `Sources/dBrief/Resources/Fonts/`; update Makefile resource copying and registration startup as needed.

**Interfaces — new contracts to implement:**

```swift
enum ViewerAppearanceMode: String, Codable, CaseIterable, Sendable {
    case light, dark, paper, darkPaper
}
enum ViewerReadingFont: String, Codable, CaseIterable, Sendable {
    case systemDefault, georgia, openDyslexic, monospace
}
enum ViewerDensity: String, Codable, CaseIterable, Sendable {
    case compact, comfortable, spacious
}
struct ViewerAppearancePreferences: Equatable, Sendable {
    var mode: ViewerAppearanceMode? // nil = follow existing system scheme
    var sourceAccentHex: String
    var readingFont: ViewerReadingFont
    var density: ViewerDensity
    var fontSize: Int
    var showSpeakerNames: Bool
    static func load(from defaults: UserDefaults) -> Self
    func save(to defaults: UserDefaults)
    func effectiveMode(systemIsDark: Bool) -> ViewerAppearanceMode
}
struct ViewerRGB: Equatable, Sendable {
    let red: Double, green: Double, blue: Double // normalized 0...1
    init?(hex: String)
    var hex: String { get }
    func mixed(with target: Self, fraction: Double) -> Self
}
struct ViewerPalette: Equatable, Sendable {
    let canvas, surface, heading, text, secondary, divider: ViewerRGB
    let primary, onPrimary, accentText, selected: ViewerRGB
    let brandStops: [ViewerRGB] // all equal to primary in Non-neon
}
enum ViewerThemeResolver {
    static func resolve(mode: ViewerAppearanceMode,
                        sourceHex: String, nonNeon: Bool) -> ViewerPalette
    static func contrast(_ first: ViewerRGB, _ second: ViewerRGB) -> Double
}
```

- [ ] **Step 1: Add failing preference and palette tests.** Use dedicated UserDefaults suites, not the real app domain. Cover round-tripping every mode/reading choice and reduceNeon separately; malformed hex → blue; unknown enum → nil/default; point size outside 12–24 → clamped; old 16 pt and Speaker Names false preserved. Start with these executable test cases against the proposed contracts:

```swift
import Foundation
import Testing
@testable import dBrief

@Test func preservesLegacyReadingPreferences() {
    let name = "viewer-preferences-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(16, forKey: "transcriptFontSize")
    defaults.set(false, forKey: "showSpeakerNames")
    let value = ViewerAppearancePreferences.load(from: defaults)
    #expect(value.fontSize == 16)
    #expect(!value.showSpeakerNames)
    #expect(value.mode == nil)
    #expect(value.effectiveMode(systemIsDark: true) == .dark)
    value.save(to: defaults)
    #expect(ViewerAppearancePreferences.load(from: defaults) == value)
}

@Test func accentsRemainReadableAcrossModes() {
    for mode in ViewerAppearanceMode.allCases {
        for source in ["#1268F5", "#7054D9", "#19745B", "#FF962C", "#000000", "#FFFFFF"] {
            let p = ViewerThemeResolver.resolve(mode: mode, sourceHex: source, nonNeon: true)
            #expect(ViewerThemeResolver.contrast(p.primary, p.onPrimary) >= 4.5)
            #expect(ViewerThemeResolver.contrast(p.accentText, p.surface) >= 4.5)
            #expect(ViewerThemeResolver.contrast(p.accentText, p.selected) >= 4.5)
            #expect(p.brandStops.allSatisfy { $0 == p.primary })
        }
    }
}
```

- [ ] **Step 2: Run the new tests and record the expected missing-contract failure.**

```sh
swift test --filter 'ViewerAppearanceTests|ViewerPreferenceTests'
```

- [ ] **Step 3: Implement the preferences, resolver, and shared UI adapters.** Use preference keys `viewerAppearanceMode`, `viewerAccentHex`, `viewerReadingFont`, `viewerTranscriptDensity`, plus existing `transcriptFontSize` and `showSpeakerNames`. Keep `reduceNeon` in AppSettings as the single persisted Non-neon value. Add `viewerAppearance` to AppSettings using load/save, and make viewer changes observe that value; replace legacy per-view reading stores to avoid two sources of truth. Preserve assistant keys and profile behaviour.

Implement mixing and contrast with the spec's exact formula. Core resolver calculations must follow:

```swift
let mixed = source.mixed(with: target, fraction: fraction)
let selected = mixed.mixed(with: canvas, fraction: 0.86)
let onPrimary = contrast(mixed, white) >= contrast(mixed, black) ? white : black
var accentText = mixed
while min(contrast(accentText, surface), contrast(accentText, selected)) < 4.6 {
    accentText = accentText.mixed(with: isDark ? white : black, fraction: 0.10)
}
```

Define `source`, `target`, `fraction`, `canvas`, `surface`, `white`, `black`, and `isDark` from the spec's palette/mode tables. Round each exported token to 8-bit channels, then verify final contrast; malformed input uses #1268F5. Keep sourceHex unchanged across theme switches. Expose the palette through a viewer-scoped SwiftUI environment value. Use palette.primary on fills and palette.accentText on accent text/strokes; Non-neon brand style uses these rather than a fixed coral.

Add Appearance controls to General Settings, including accent presets/custom ColorPicker and Non-neon. Put font, 12–24 pt size, density, Speaker Names, and reset in the common display popover. Font registration must use a native-supported file, preserve exact licence/attribution, and fall back gracefully to system sans serif if unavailable. Paper defaults to Georgia only for systemDefault; explicit font choices survive mode changes. Use theme-consistent native colour schemes for menus/sheets.

- [ ] **Step 4: Run preference/palette and relevant settings tests; visually inspect one viewer control in four modes and Non-neon on/off.** Add cases for invalid values and reset isolation: resetting reading does not change mode, source accent, reduceNeon, assistant state, or profiles.

```sh
swift test --filter 'ViewerAppearanceTests|ViewerPreferenceTests|SettingsSearchTests|SettingsResetTests|SettingsProfileScopeTests'
```

- [ ] **Step 5: Commit only Task 1 files with message `feat: add viewer appearance and reading preferences`.** Record any intentional font fallback in the review notes.

## Task 2: Four-tab shell, aligned content, and preserved viewer states

**Files:** create ViewerPresentationPolicy and ViewerHeader; modify TranscriptBrowserView and TranscriptWindowView. Test `Tests/dBriefTests/ViewerPresentationPolicyTests.swift`; retain existing TranscriptSearch/RestoredChatLayout/ProcessingTranscriptPreview coverage.

**Interfaces:** consumes AppSettings.viewerAppearance and the shared palette. Produces `ViewerDocumentMode` and a pure presentation policy; the shell retains current recording/insights/chat/player state.

```swift
enum ViewerDocumentMode: String, CaseIterable, Sendable {
    case summary, transcript, actions, meetingInsights
}
enum ViewerPresentationPolicy {
    static func initialMode(hasSummary: Bool) -> ViewerDocumentMode
    static func showsPlayback(mode: ViewerDocumentMode,
                              hasFinalizedAudio: Bool, isLive: Bool) -> Bool
}
```

- [ ] **Step 1: Write policy tests.**

```swift
@Test func transcriptOwnsPlayback() {
    for mode in ViewerDocumentMode.allCases {
        #expect(ViewerPresentationPolicy.showsPlayback(
            mode: mode, hasFinalizedAudio: true, isLive: false) == (mode == .transcript))
        #expect(!ViewerPresentationPolicy.showsPlayback(
            mode: mode, hasFinalizedAudio: false, isLive: false))
        #expect(!ViewerPresentationPolicy.showsPlayback(
            mode: mode, hasFinalizedAudio: true, isLive: true))
    }
    #expect(ViewerPresentationPolicy.initialMode(hasSummary: true) == .summary)
    #expect(ViewerPresentationPolicy.initialMode(hasSummary: false) == .transcript)
}
```

- [ ] **Step 2: Implement policy and shell layout.** Replace the private two-case ViewerMode with ViewerDocumentMode. Keep the existing live, recovery-not-ready, loadFailed, loading, and reprocessing branches. Replace only the finished-recording chrome. Compose the document and fixed player inside a bounded VStack:

```swift
VStack(spacing: 12) {
    selectedDocument
        .frame(maxWidth: 920, maxHeight: .infinity)
    if ViewerPresentationPolicy.showsPlayback(
        mode: mode, hasFinalizedAudio: recording.finalizedAudioURL != nil, isLive: isLive) {
        playerBar.frame(maxWidth: 920)
    }
}
.frame(maxWidth: .infinity, maxHeight: .infinity)
```

`selectedDocument` is the shell's view builder for the four mode cases. Remove playerBar from the old transcriptBody to avoid duplication. Leave audio ownership in the existing AudioPlayer. Preserve transcriptList as List, ScrollViewReader, stable IDs, search debounce/match navigation and follow rules. Keep the sidebar native split-view behaviour and assistant resize handle/keys.

Create the single title/tab/header and mode-aware command bar specified in the design. Eliminate duplicated toolbar copy/metadata/unused ellipsis. Both display controls use ViewerReadingOptions. Library options retains Rebuild Search Index. Keep red deletion, privacy receipt, reprocessing choices and source actions. Use outline icons and the 20 pt unbadged header sparkle; no prototype review controls in production.

- [ ] **Step 3: Run policy and current viewer regressions.**

```sh
swift test --filter 'ViewerPresentationPolicyTests|TranscriptSearchTests|RestoredChatLayoutTests|ProcessingTranscriptPreviewTests|LiveTranscriptMappingTests'
```

- [ ] **Step 4: Manually inspect long recordings and absent data.** At 1100 × 900 and 1536 × 1024, switch all tabs with both/either/neither panel open; verify equal content edges, nontruncated titles, selected text, search, and no nested competing scrollbars. Scroll a long real transcript repeatedly and verify memory does not grow with every visited row. Open a live capture, queued/reprocessing job, failed transcript, and recording without analysis; ensure the existing state-specific actions remain available. Record the result for each fixture in `docs/reviews/2026-09-28-transcript-viewer-redesign.md`.

- [ ] **Step 5: Commit the shell with message `feat: compose the four-tab transcript workspace`.** The tab content moves are completed in Task 3; no removed capability is accepted as a finished state.

## Task 3: Summary, Actions, Meeting Insights, and shared analysis editing

**Files:** create RecordingActionsView, MeetingInsightsView, RecordingAnalysisEditor; modify SummaryView and TranscriptWindowView; retain RecordingInsights and InsightsStore persistence. Extend `ActionItemParserTests`, `RecordingInsightsTests`, `InsightsStoreTests`, and `MarkdownInsightsUpdaterTests` only where new behaviour needs coverage.

**Interfaces:** all views receive the shell's current RecordingInsights and use the existing callbacks. No new insights sidecar format or competing cached completion set.

```swift
// Preserve these existing callback contracts at composition boundaries.
let onSave: (RecordingInsights) async -> Void
let onSetActionCompleted: (String, Bool) async throws -> RecordingInsights
// RecordingActionsView also consumes owners: [String], isReadOnly: Bool.
// MeetingInsightsView consumes recording: Recording,
// richTranscript: RichTranscript?, insights: RecordingInsights?,
// onPrivacyReceipt: () -> Void, and the existing speaker-menu callbacks.
```

- [ ] **Step 1: Pin completion identity and failure behaviour.** Extend existing tests with duplicate-looking but distinct raw strings, renamed action text, sidecar write failure, and an action completion arriving while summary/tag edits are being saved. Do not reimplement the parser. Minimum model assertions:

```swift
@Test func rewrittenActionsDoNotInheritCompletion() {
    var insights = RecordingInsights(summary: "Summary", actionItems: ["Review draft"],
                                    tags: ["UWV"], sentiment: "", markdownPath: nil)
    insights.completedActionItems = ["Review draft"]
    insights.actionItems = ["Review final draft"]
    #expect(insights.completedActions.isEmpty)
    #expect(insights.unfinishedActionItems == ["Review final draft"])
    #expect(insights.tags == ["UWV"])
}
```

Use InsightsStoreTests' existing temporary-sidecar fixtures for async save/error cases. Verify a failed write leaves both stored data and the visible completion state unchanged after rollback.

- [ ] **Step 2: Extract presentation sections without replacing save logic.** Summary becomes the full-height reading document. Move owner grouping/actions into RecordingActionsView, tags/sentiment/meeting data into MeetingInsightsView. Extract the existing combined summary/actions/tags editor into RecordingAnalysisEditor so no editing capability disappears during the split. Route every edit to the same saveInsights pathway and update the shell's shared insights from the successful store result; never save a stale snapshot over a newer completion set.

Keep every raw action key unchanged unless the user edits its text. Use `insights.unfinishedActionItems.count` for the badge; `insights.completedActions.count` for completed totals. Resolve participants and speakers from existing Recording/calendar/RichTranscript data. Do not copy illustrative start times or example sentiment into native views. Empty/missing fields are omitted or explained, never invented. Mark pending reprocessing as read-only in every tab and editor.

- [ ] **Step 3: Run analysis persistence regressions.**

```sh
swift test --filter 'ActionItemParserTests|RecordingInsightsTests|InsightsStoreTests|MarkdownInsightsUpdaterTests'
```

- [ ] **Step 4: Exercise actual edit paths.** Edit a summary, action text, and tag; complete an action; reopen the same recording; verify shared counts and persisted state. Repeat with a failed save and while reprocessing. Review a >1,000-word summary and a recording with no analysis, no tags, unnamed speakers, or unavailable calendar data. Verify copy returns the complete selected view and existing recording-aware clipboard behaviour. Confirm speaker rename/assignment and Privacy receipt still use their original workflows.

- [ ] **Step 5: Commit with message `feat: separate actions and meeting insights without changing storage`.**

## Task 4: Time-correct speaker waveform and reading density

**Files:** create Models/SpeakerTimeline.swift; modify TranscriptPlayerBar.swift, WaveformView.swift, TranscriptWindowView.swift and the actual transcript row rendering; use ViewerReadingOptions preferences from Task 1. Create `Tests/dBriefTests/SpeakerTimelineTests.swift`.

**Interfaces:** derives from actual RichSegment timestamps, not current SpeakerStripSegment weights.

```swift
struct SpeakerTimeRange: Equatable, Sendable {
    let start: Double
    let end: Double
    let speakerID: String
}
enum SpeakerTimeline {
    static func normalize(_ segments: [RichSegment], duration: Double) -> [SpeakerTimeRange]
    static func speakerID(at time: Double, in ranges: [SpeakerTimeRange]) -> String?
}
```

- [ ] **Step 1: Add interval edge-case tests.** Use half-open intervals `[start,end)`; overlapping distinct speakers return nil. Ignore nonfinite/reversed/empty intervals, clip to valid duration, and treat an unknown speaker as neutral. Start with:

```swift
@Test func gapsAndOverlapsAreNeutral() {
    let ranges = [SpeakerTimeRange(start: 0, end: 2, speakerID: "A"),
                  SpeakerTimeRange(start: 3, end: 5, speakerID: "B"),
                  SpeakerTimeRange(start: 4, end: 6, speakerID: "C")]
    #expect(SpeakerTimeline.speakerID(at: 1, in: ranges) == "A")
    #expect(SpeakerTimeline.speakerID(at: 2.5, in: ranges) == nil)
    #expect(SpeakerTimeline.speakerID(at: 4.5, in: ranges) == nil)
    #expect(SpeakerTimeline.normalize([], duration: 0).isEmpty)
}
```

Add tests with out-of-order segments, negative times, duration clipping, same-speaker overlaps, renamed labels retaining speaker ID, and unknown IDs. Build any waveform lookup cache outside Canvas rendering; do not scan the entire transcript for each bar on every redraw.

- [ ] **Step 2: Implement actual-time waveform colouring and the standalone player.** Feed normalized ranges and actual recording duration to WaveformView. For N bars, sample bar-centre time as `duration * (Double(index) + 0.5) / Double(N)`; use speakerID lookup and the shared identity palette, not accent for “me”. Unknown/gap/overlap uses neutral. Keep a distinct playhead and played/unplayed styling that does not erase speaker identity.

Preserve AudioPlayer.togglePlayPause, seek, playbackRate and the existing speed menu. Use recording metadata for duration before the player loads where available; disable seeking when no trustworthy duration/audio exists. No waveform sample generation from example content. Use the existing waveform generator and cancel/ignore stale results when audioURL changes. Speaker legend maps actual IDs/names and uses the same colours in all views.

Apply selected font and density to the real transcriptList rows, not only TranscriptSegmentRow if it is not the active rendering path. Padding/header gaps follow the spec; measure line spacing with the selected font's metrics. Selection/search attribution must still work after font/density changes. The List remains the only transcript scroll container.

- [ ] **Step 3: Run timeline/speaker and search regressions.**

```sh
swift test --filter 'SpeakerTimelineTests|SpeakerTurnTests|SpeakerReassignmentTests|SpeakerClipRangesTests|TranscriptSearchTests'
```

- [ ] **Step 4: Verify playback and text on native fixtures.** Seek into speech, silence, and overlaps, including near the end; rename a speaker and verify waveform colour stays stable. Toggle “This is me”, Non-neon, every theme and density while playing. Switch away from Transcript and back without resetting playback. Verify no-audio/zero-duration and single-speaker recordings, retained speed settings, independently played spoken summaries, readable waveform/legend, and keyboard-accessible seek values. Compare density at 12/16/24 pt with Default and OpenDyslexic.

- [ ] **Step 5: Commit with message `feat: align speaker waveform with recording time`.**

## Task 5: Assistant styling, answer export, and release-quality verification

**Files:** modify TranscriptChatView, create Services/ChatAnswerExport.swift; keep existing chat-service/store/cancellation/read-aloud and scroll-follow logic. Add `Tests/dBriefTests/ChatAnswerExportTests.swift`; update the native review report and README links.

**Interfaces:** formatting is pure; destinations and filesystem errors belong to the save action.

```swift
enum ChatAnswerExportFormat: Sendable { case markdown, plainText }
enum ChatAnswerExport {
    static func payload(for message: ChatMessage, format: ChatAnswerExportFormat) -> String
    static func write(_ payload: String, to destination: URL) throws
}
```

- [ ] **Step 1: Add export tests before implementing it.**

```swift
@Test func exportContainsOnlyTheAnswer() {
    let message = ChatMessage(role: .assistant,
        content: "<think>Private reasoning</think>\n## Answer\nSend the notes.")
    #expect(ChatAnswerExport.payload(for: message, format: .markdown)
            == "## Answer\nSend the notes.")
    #expect(!ChatAnswerExport.payload(for: message, format: .plainText)
             .contains("Private reasoning"))
    let pending = ChatMessage(role: .assistant, content: "<think>Still thinking")
    #expect(ChatAnswerExport.payload(for: pending, format: .markdown).isEmpty)
}
```

Add temporary-file tests for UTF-8/Unicode, Markdown preservation, atomic overwrite, nonexistent/unwritable destination failure, and a user-role message returning no assistant export payload. View-level manual tests cover cancellation because a cancelled native save panel does not call write.

- [ ] **Step 2: Apply assistant styles and export controls without changing conversation ownership.** Use shared palette in user bubbles, send control, templates, answer marks and composer; use the compact unbadged sparkle and exact Ask dBrief AI label. Keep chat state across tab/theme changes and inspector hiding. Reuse current Copy/Read aloud actions. Add a Share / Export menu operating on one message.

Formatter implementation starts with the existing answer representation:

```swift
static func payload(for message: ChatMessage, format: ChatAnswerExportFormat) -> String {
    guard message.role == .assistant else { return "" }
    let answer = message.displayParts.answer
    switch format {
    case .markdown: return answer
    case .plainText: return SpokenSummaryScript.clean(answer)
    }
}
static func write(_ payload: String, to destination: URL) throws {
    try payload.write(to: destination, atomically: true, encoding: .utf8)
}
```

Use NSSavePanel for Markdown/text destinations; offer suggested name `dBrief-answer.md`/`.txt` and correct types. Do not write on cancellation. Disable export for empty/streaming messages; preserve current copy/redaction behaviour and never export reasoning. Write errors surface a recoverable message with the answer retained. No external messaging or transmission is introduced.

- [ ] **Step 3: Run focused export/chat tests, then the full suite once.**

```sh
swift test --filter 'ChatAnswerExportTests|ChatMessageActionsTests|ChatScrollFollowTests|ChatStoreTests|TranscriptChatCancellationTests'
swift test
swift build --product dBrief
```

Record unrelated baseline failures and require no new regression. Build failures are resolved before calling implementation complete. To assemble the native bundle, use `make app` (debug swift build alone is not an app bundle); do not use xcodebuild on this CLT-only machine. Assembly may touch other packaging/resources, so review the resulting diff separately and do not start publishing/distribution.

- [ ] **Step 4: Complete the native acceptance matrix and record screenshots.** Test the four themes × Non-neon on/off; six accent examples including black/white; every tab; all pane states; Default/Georgia/OpenDyslexic/Monospace; density/size changes; search and text selection; actual playback; action editing/completion; chat streaming/cancellation/read-aloud/export; and recording processing/live/recovery states. Use meaningful fixtures rather than implementation-mirroring screenshot assertions. Check VoiceOver labels/values, logical focus order, tab/space/escape handling, high contrast, reduced motion and window resizing. Compare final screenshots against revision-13 HTML, not superseded Pen images.

- [ ] **Step 5: Commit with message `feat: complete viewer assistant export and visual redesign`.** Review the complete branch for hardcoded accent/neon colours left in migrated views, changed service behaviour, incidental edits, and resource licences. Attach the design/spec/review notes to any resulting review request. Release only under a separate user-authorized execution/release workflow.

## Definition of ready for review

The five tasks' checks are recorded, the full suite has no new failure, the app bundle builds, native screenshots demonstrate all four appearances and Non-neon, real recording data replaces every example, and current capture/transcription/recovery behaviours remain intact. No required capability is replaced by a demonstration toast or an empty menu.

## Handoff

This planning request delivers the design and execution steps, not app implementation. The design spec is authoritative for final behaviour; the implementation plan is authoritative for contracts, file ownership and verification. Review the two documents before starting Task 1. A native sequential execution is a reasonable default because all five stages depend on the same palette/preferences and existing detail-view state. Subagent-driven execution remains an option if explicitly requested.
