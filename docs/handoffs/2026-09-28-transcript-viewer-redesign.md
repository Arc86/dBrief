# Transcript Viewer redesign — new-agent handover

Prepared: 28 September 2026.
Workspace: `/Users/jesper.mol/code/VoiceRecorder`.
Current checkout: `main`, HEAD `7f18364` — “Fix Finder icon to fill the native macOS tile”. Recheck before execution.

## Start here

The user has approved the mock-up direction and requested an implementation plan/design, followed by this handover. **Production UI implementation has not started.** This document is an execution briefing, not evidence that any native redesign has already shipped.

Read, in order:

1. `docs/superpowers/specs/2026-09-28-transcript-viewer-redesign.md` — authoritative final behaviour and visual specification.
2. `docs/superpowers/plans/2026-09-28-transcript-viewer-redesign.md` — five implementation stages, proposed contracts, file ownership, and verification.
3. `previews/transcript-redesign/pen-review.html` — approved interactive visual reference, final state revision 13.

The plan's proposed types do not yet exist. Do not mistake code examples or tests in the plan for implemented app interfaces. The original Pen reference and earlier screenshots are superseded where they conflict with the final spec.

When the new task instructs you to implement, start at Task 1, not with another design exploration. Do not ask the user to repeat preferences already captured here. Do not publish or distribute a build without separate authorization. This handover request itself does not ask the current agent to start implementation or create a new chat.

## Model recommendation

**Recommended: GPT-6 Astra, reasoning effort High**, for the implementing agent. The task combines custom SwiftUI layout, preference migration, appearance-token consistency, playback timing, existing persistence, and live/recovery-state preservation. A model suited to complex cross-file work is useful here; raw UI generation is only part of the job.

Use native sequential execution of the five stages. Do not spawn subagents unless the user authorizes delegation. GPT-6 Sol at High is an alternative for tightly scoped stages with the same acceptance checks. This is a task-fit recommendation, not a pricing or measured performance claim.

## Approved design — retain these decisions

| Area | Final decision |
| --- | --- |
| UI approach | Custom SwiftUI/AppKit styling, closely following Pen. Native-looking controls are not a design constraint. Native window behaviour, accessibility and keyboard operation remain required. |
| Main navigation | Summary, Transcript, Actions, Meeting Insights. Initial Summary if a summary exists, otherwise Transcript. |
| Content | Shared centred maximum 920 pt column across tabs. Transcript fills available height with an internally scrolling recycling List. Long summaries remain fully readable. |
| Panels | Independently collapsible sidebar and assistant; preserve resizing and stored assistant width. Narrow layout may wrap controls without forcing document horizontal scrolling. |
| Playback | Separate bottom panel, **only in Transcript**. Actual recording waveform with time-aligned speaker colours, name legend and separate playhead. Keep actual player state across tab changes. |
| Header | One title; no duplicate copy icon or metadata row; no unused Recording options ellipsis. Metadata belongs in Meeting Insights. |
| Commands | Copy / Edit / Re-process / Spoken Summary where applicable. Re-process is between Edit and Spoken Summary. Delete stays red with confirmation. |
| Library options | Retain useful Rebuild Search Index; no decorative inert menu. |
| Assistant | Ask dBrief AI. Header sparkle is **20 pt**, no badge background/border. Compact AI toggle is approximately 32 pt high. Preserve existing chat and speech behaviour. |
| Branded buttons | Plain theme-surface interiors with dBrief gradient borders. **No colour bleed**; no ambient neon glow. |
| Appearance | Light, Dark, Paper, Dark Paper. Paper modes default to Georgia reading text; explicit fonts take precedence. |
| Accent | Source colour stays configurable/persisted. Derive primary, text and selection colours consistently per appearance, including chat/send/play. |
| Non-neon | Existing reduceNeon preference replaces dBrief gradients with the selected theme-adapted accent for button borders, sparkle and sidebar waveform. Retain distinct speaker identities. |
| Reading | Default / Georgia / OpenDyslexic / Monospace; text size retains existing 12–24 pt range and stored 16 pt default. Compact / Comfortable / Spacious transcript density is independent of point size. Preserve Speaker Names. |
| Export | One complete assistant answer: Copy, Markdown file, text file. Never include reasoning or whole conversation. Native save panel, no write on cancellation. |

Do not reintroduce intermediate proposals: logo badge in chat, 32 pt header sparkle, full-width Transcript while other tabs are narrow, playback on all tabs, inward button colour washes, or raw bright accent fills that ignore the selected appearance.

The original “existing functionality only” constraint was explicitly expanded by the user for separate Actions/Insights tabs, font/density choices, configurable accents/appearances, and assistant response export. It was not expanded to new meeting analytics, folders, starred/shared/archive navigation, chapter systems, attendee percentages, or external messaging.

## Current artefacts and preview

The stable prototype file is:
`/Users/jesper.mol/code/VoiceRecorder/previews/transcript-redesign/pen-review.html`.

Preview URL:
`http://127.0.0.1:8793/pen-review.html?revision=13&theme=dark-paper&mode=summary&nonneon=1`.

The `revision` query is a review/cache marker, not a versioned file selector: earlier review URLs load the same current HTML. Actual archived variants are separate files. The latest HTML is the visual authority. Appearance/reading/accent choices persist in browser local storage; query parameters can override them for reproducible review. Do not carry those localStorage keys into app preferences as a second storage system.

If the existing server is not running, start a local preview from the workspace:

```sh
python3 -m http.server 8793 --bind 127.0.0.1 --directory previews/transcript-redesign
```

If port 8793 is already in use, check the existing server before starting another. Useful query parameters: `theme=light|dark|paper|dark-paper`, `mode=summary|transcript|actions|insights`, `sidebar=closed`, `chat=closed`, `display=open`, `font=default|serif|dyslexic|mono`, `density=compact|comfortable|spacious`, `nonneon=1|0`, and `accent=%231268F5`.

Historical screenshots and verification are indexed in `previews/transcript-redesign/README.md`. `PRODUCT.md` contains the review history but points to the consolidated spec as authoritative. Pen's canvas was unavailable during later revisions because no document was open; do not assume its browser frames reflect every final state. Do not access encrypted `.pen` files through shell tools.

## Protect existing work

There are **pre-existing, unrelated changes** in this checkout. At handover time, modified tracked files include:

```text
Sources/dBrief/App/AppSettings.swift
Sources/dBrief/Audio/AudioCaptureManager.swift
Sources/dBrief/Models/ActionItemGrouping.swift
Sources/dBrief/Services/AIService.swift
Sources/dBrief/UI/SummaryView.swift
Tests/dBriefTests/ActionItemParserTests.swift
packaging/beta-build-number
```

Untracked work also includes microphone investigation/implementation files, existing agent directories, preview artefacts, browser logs and documentation. Inspect the entire status; the list above is not exhaustive. AppSettings, SummaryView, ActionItemGrouping and action-parser tests overlap with the redesign, so merge carefully rather than replacing them from an older baseline.

```sh
git status --short
git diff --stat
```

Do not revert other changes, clean the checkout, indiscriminately stage files, or assume all untracked work belongs to this redesign. No redesign commits were made in this planning session. Use a suitable managed worktree if isolation is needed; first inspect available attached worktrees. Respect the user's AGENTS.md and the actual current source before executing the plan.

## Existing implementation facts

| Fact | Consequence |
| --- | --- |
| `TranscriptDetailView` lives in `UI/TranscriptWindowView.swift`; mode is currently a private two-case enum. | Extend the existing composition rather than create a parallel viewer. |
| Current `transcriptList` is a recycling List because selection-backed views in LazyVStack caused memory growth. | Preserve List, stable IDs, search and follow logic. |
| Assistant width persists in transcriptAssistantPanelWidth, clamped 300–480 pt; assistantOpen is also stored. | Keep these keys and resize behaviour. |
| `AppSettings.reduceNeon` exists and is exposed in General Settings. | Reuse it; do not add a second Non-neon boolean. |
| Reading uses transcriptFontSize and showSpeakerNames; current size default is 16. | Migrate compatibly; HTML's 15 pt preview default is not the native default. |
| `SummaryView` combines editing of summary/actions/tags; completion uses raw action strings. | Extract presentation/editor carefully; preserve all editing and saved completion identity. |
| `RecordingInsights` already has summary/actions/completion/tags/sentiment/title/provenance. | Meeting Insights displays existing fields; no new analytics schema needed. |
| `TranscriptPlayerBar.swift` also defines SpeakerStripSegment and SpeakerActivityStrip. | There is no standalone SpeakerActivityStrip.swift file. |
| Current speaker strip weights sum speech durations and collapse gaps. | Build waveform attribution from segment timestamps, not cumulative strip weights. |
| “This is me” currently sometimes resolves to Color.accentColor. | Use stable speaker colour for timeline identity as specified. |
| `ChatMessage.displayParts.answer` excludes reasoning. | Use it for answer export; do not export message.content. |
| SwiftPM excludes `Sources/dBrief/Resources`; Makefile copies resources. | Add native font assets and notices to the actual app bundle path. Prototype WOFF is not a macOS font resource. |

Minimum platform is macOS 14 with Swift tools 6.2. Use `swift test` and `swift build`; `make app` assembles the release app bundle. Only Command Line Tools are available: do not use xcodebuild or swift package generate-xcodeproj. No test/build was run for the native redesign during planning because only documents and mock-ups were changed.

The prototype OpenDyslexic WOFF includes older embedded licence/attribution notices in `previews/transcript-redesign/fonts/FONT-NOTICE.txt`. Acquire/verify a native OTF/TTF file and the exact version's licence before shipping. Do not assume a newer website's licence applies to that older file. Plan default sans serif uses bundled Inter where properly licensed, otherwise system fallback.

## Execute the five stages

1. Shared appearance/reading preferences, palette resolver, Settings, font resources and Non-neon reuse.
2. Four-tab shell, aligned document column, panel behaviour and preservation of live/processing/recovery states.
3. Split Summary/Actions/Meeting Insights presentation while preserving shared analysis editing and persistence.
4. Speaker-timestamp waveform, standalone Transcript player, reading font/density and long-list behaviour.
5. Assistant styling/export, full regression checks, native screenshots and branch review.

Each stage has proposed interfaces, test snippets and acceptance steps in the implementation plan. Interfaces are design contracts; adjust them if actual integration requires it, and update the plan consistently. Do not blindly paste sketches into the app. Review Focus failures in the plan have an owning stage.

Begin by recording baseline test results and the current worktree state. Prefer native sequential execution unless the user chooses delegation. Build/review before any release action; do not modify real recordings for test fixtures.

## Verification already performed

Clean-browser checks cover four views, pane closing/reopening, common widths, long-summary scrolling, actual preview font loading, density/persistence/reset, response file download, theme switching, Non-neon restoration, and narrow layout. Accent checks covered 24 combinations: six colours × four appearances, with primary and selected-surface text contrast at least 4.5:1.

These are **prototype checks**, not native-app acceptance results. They do not validate SwiftUI layout, VoiceOver, actual recording playback, native font registration, existing recovery behaviour or service persistence after the redesign. Complete the plan's native acceptance matrix after implementation.

## Ready-to-use prompt for the new agent

Implement the approved dBrief Transcript Viewer redesign in `/Users/jesper.mol/code/VoiceRecorder`. Read `docs/handoffs/2026-09-28-transcript-viewer-redesign.md`, the referenced design specification, and implementation plan first. Treat revision-13 HTML as the final visual reference. Follow the five stages sequentially, beginning with shared appearance/reading preferences. Preserve all unrelated checkout edits, existing storage, live/recovery behaviour, recycling transcript List and service ownership. Reuse reduceNeon; keep Transcript-only playback; maintain theme-adapted accents and Non-neon; do not reintroduce button colour bleed. Run meaningful tests and native visual checks for each stage, record baseline failures separately, and continue until the implementation and acceptance checks are complete. Do not publish/distribute a build or message anyone. Do not delegate unless I explicitly authorize it.
