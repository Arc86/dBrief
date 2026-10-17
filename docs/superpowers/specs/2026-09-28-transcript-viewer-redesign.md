# Transcript Viewer redesign — approved design

Status: design approved for planning; production implementation has not started.
Date: 28 September 2026.

## Design authority

The latest interactive prototype is [revision 13](http://127.0.0.1:8793/pen-review.html?revision=13&theme=dark-paper&mode=summary&nonneon=1). Its local source is `previews/transcript-redesign/pen-review.html`. The HTML, not earlier screenshots or Pen frames, captures the final interaction and appearance decisions. The preview server is optional for the implementation: the file and screenshots remain available locally.

The screenshots `review-ten-dark-summary.png`, `review-ten-paper-summary.png`, `review-eleven-dark-paper.png`, `review-twelve-dark-paper-accent.png`, and `review-thirteen-non-neon.png` show appearance evolution. Use the revision-13 HTML for final accents and Non-neon, rather than copying an older screenshot's colours. The Pen reference supplied the light palette and outline icon language. Original Pen frames remain reference material, not production feature requirements.

Later user decisions supersede earlier proposals: playback is Transcript-only; the chat header uses a 20 pt sparkle without a badge; button colour bleed is removed; brand gradients become the chosen accent when Non-neon is on. Dedicated Actions and Meeting Insights tabs, response export, configurable accent, reading fonts/density, and four appearance modes were explicitly requested additions to the initial existing-features-only boundary.

## Product result

A custom SwiftUI macOS workspace supports reading and searching meeting transcripts, reviewing summaries and owner-grouped actions, inspecting existing meeting information, and asking dBrief AI questions beside the content. Custom controls and styling may closely follow Pen; native macOS window behaviour, keyboard support, text selection, accessibility, and existing data operations remain intact.

Do not replace the application with a web view or ship the HTML prototype as the app. All example meeting text, action states, sentiment, speaker names, timing, and waveform samples must be replaced by the recording's actual data.

## Global constraints

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

## Workspace and layout

| Region | Layout and behaviour |
| --- | --- |
| Library sidebar | Search, existing smart views, date-grouped recordings, Record meeting, refresh, useful Library options, Settings. Collapsible; preserve native split-view resizing. Reference width 248 pt, narrower example 220 pt. |
| Main workspace | One meeting title, quiet breadcrumb, four tabs, view-specific command bar, content, and Transcript-only player. Insets approximately 24–32 pt horizontally and 20–24 pt vertically. |
| Assistant | Independent, collapsible, resizable conversation panel. Preserve current 300–480 pt range and stored width, rather than hardcoding the prototype's 374 pt. |
| Document column | Centred, maximum 920 pt; shrink to available width. Use the same left/right edges in all tabs. No width jump when switching tabs or closing panels. |
| Transcript | Card fills available vertical space. Fixed search header; recycling list scrolls within the card. Playback is a separate bottom card with a 12 pt gap. |
| Other tabs | Vertically scrolling reading column. Summary is fully readable, including summaries exceeding 1,000 words; no fixed-height truncated card. Actions and Insights use natural card heights. |

At a narrow window, allow the tab tools/AI button to wrap onto a second row. Do not shrink reading text, force horizontal document scrolling, or silently close a panel. Preserve existing window minimum-size behaviour; test a 1100 × 900 window, both panes open, either pane closed, and both closed. At larger sizes test 1536 × 1024 and the supplied 2123 × 1344 reference viewport. Dimensions in the HTML are logical pixels; native implementation uses logical points.

The browser review header, preview mode switches, accent swatches, and demonstration toasts are not production chrome. Appearance, accent, and Non-neon belong in Settings → General → Appearance. Reading options belong in the viewer's display popover.

## Navigation and commands

Tabs, in order: **Summary**, **Transcript**, **Actions**, **Meeting Insights**. Actions displays the unfinished-action count. Keep the existing initial selection rule: Summary when a nonempty summary is available, otherwise Transcript. Switching tabs must not start generation, recreate chat, discard drafts, or reset audio playback.

The title has no duplicate copy control or metadata row. Remove the unused Recording options ellipsis. A useful Library options menu retains **Rebuild Search Index**; smart-view choices are already visible in navigation and need not be duplicated.

The compact **Ask dBrief AI** toggle sits beside the tabs. It is approximately 32 pt high, uses a 14 pt sparkle, and has a light/plain interior plus a 1.5 pt brand border. Record meeting uses the same visual treatment at approximately 40 pt high. Keep adequate hit regions and keyboard focus despite smaller artwork. The assistant can also close from its own header.

The command bar contains **Copy**, **Edit**, **Re-process**, **Spoken Summary**, in that order when all apply. Transcript omits Edit and Spoken Summary. Actions and Meeting Insights omit Spoken Summary. Edit opens the existing analysis editor for the relevant fields; summary/action/tag editing must remain available. Preserve existing reprocessing choices, engine availability, read-only processing states, and confirmation flows. Delete is visibly red, independently of the selected accent, and keeps its destructive confirmation.

Copy operates on the selected view: complete summary, full transcript, complete action list, or meeting information. It does not copy only visible rows. Retain existing recording-aware clipboard handling.

Both display-options entry points open the same popover. Privacy receipt remains accessible from the viewer and from Meeting Insights.

## Content and data mapping

| Tab | Source and preserved interactions |
| --- | --- |
| Summary | `RecordingInsights.summary`; existing generation, editing/save, copying, collapsed-summary option, and spoken-summary generation/playback. Preserve stale-analysis/reanalysis and read-only banners. |
| Actions | `actionItems`, `completedActions`, and `unfinishedActionItems`; use `ActionItemParser.group` and existing owner names. Preserve exact raw-text completion keys and `InsightsStore.setActionCompleted` persistence. |
| Meeting Insights | Recording title/date/duration/file, actual participants/calendar attendees, transcript speaker labels and “This is me”, existing tags/sentiment, and processing evidence/privacy receipt. Speaker correction opens existing rename/reassignment menus. |
| Transcript | Existing rich transcript, speaker turns and segment text, timestamps, match navigation, seeking, selection, editing/cleanup and speaker correction capabilities. |

Do not invent decisions, attendee percentages, chapter analytics, new confidence scores, or AI guarantees. Omit unavailable optional metadata; distinguish missing data from zero/empty results. Show actual processing failures and recovery actions. Unnamed speakers stay identifiable. Empty Actions and Insights should explain the absence of analysis and offer only existing eligible generation/retry commands.

Analysis editing must update one shared `RecordingInsights` value. Keep tags editable even though they move to Meeting Insights. A completion failure rolls back the optimistic checkbox and shows the current error path; do not imply persistence succeeded.

## Playback and speaker colours

Keep the existing AudioPlayer instance, source file, speed choices, waveform generation, seek/follow behaviour, and separate spoken-summary player. Hiding the playback panel by switching tabs does not reset or stop the recording unless an existing app rule requires it.

Colour waveform bars using the speaker active at the bar's timestamp. Use actual `RichSegment.start/end`, recording duration, and waveform sample time. The existing weight-based speaker strip collapses gaps; do not reuse those cumulative weights for time-based waveform colouring.

Keep a stable speaker-ID → colour mapping shared by transcript labels, waveform and legend. Rename changes the label, not the colour. “This is me” does not recolour a speaker to the configurable accent. Colours distinguish speakers in Non-neon too. Light examples: blue `#3371CD`, violet `#9854BD`, teal `#16827C`; Dark uses lighter equivalents; Dark Paper uses softer blue/violet/green. Extend the existing deterministic palette for additional IDs.

Gaps use a neutral waveform colour. Clamp intervals to duration; ignore invalid/zero-length intervals. At overlapping intervals show neutral waveform plus the existing speaker strip/legend, rather than fabricating an exclusive speaker. Retain a separate playhead and accessible position value. An undiarized recording has a neutral waveform and no fabricated speaker legend. Handle missing/zero-duration audio without division by zero or an enabled seek control.

## Appearance system

One shared palette supplies all viewer surfaces; no scattered `Color.accentColor`, literal neon fills, or scheme-only colours in migrated components.

| Token | Light | Dark | Paper | Dark Paper |
| --- | --- | --- | --- | --- |
| Workspace | #FBFCFE | #1B2029 | #F5F2EB | #24211D |
| Card/chat/button interior | #FFFFFF | #242C38 | #FFFCF5 | #302C26 |
| Heading | #0B1430 | #F0F3FA | #302D28 | #F0E8D8 |
| Body text | #31405F | #D2DAE8 | #514B42 | #D8CDB9 |
| Secondary text | #65718A | #A3AFC4 | #756D60 | #B9AD98 |
| Divider | #E1E7F0 | #3A4658 | #DBD4C5 | #50483C |
| Sidebar top/bottom | #FAFBFD / #F1F5FA | #202733 / #191F29 | #F0ECE2 / #EAE5D9 | #2B2721 / #211E19 |

Standard cards/chat: 14 pt radius; Paper/Dark Paper reading cards and playback: 8 pt. Use subtle borders and modest window elevation; no ambient neon or button glow. Retain reduced-motion support.

Appearance choices: Light, Dark, Paper, Dark Paper. For existing users with no stored choice, resolve the current macOS scheme until they choose an explicit mode; persist only explicit choice. This migration behaviour preserves current expectations and is not an extra visible mode. Dark/Dark Paper use dark native control presentation; Light/Paper use light native presentation, including menus and sheets. Scope the custom palette to the viewer family; do not restyle unrelated recording or AI interfaces during this project.

### Accent derivation

Preserve the user's original hex colour. Never persist a derived colour as the new source when switching appearance.

For selected RGB `s`, effective primary = `(1−a) × s + a × target`, rounded to 8-bit channels:

| Mode | a | target |
| --- | --- | --- |
| Light | 0 | #FFFFFF |
| Dark | 0.16 | #FFFFFF |
| Paper | 0.25 | #82796A |
| Dark Paper | 0.38 | #E0D2B8 |

Selected background = 14% effective primary + 86% workspace. Primary text chooses black or white, whichever has higher WCAG sRGB contrast. Accent text starts at effective primary, then blends 10% per iteration towards white for dark modes or black for light modes until contrast is at least 4.6:1 against both the card and selected background; round and verify a minimum 4.5:1 in final tokens.

Chat user bubbles, send/play controls use primary; tabs, labelled highlights, selected navigation and answer marks use accent text; selections use selected background. Apply consistent tokens to checkbox tint, search/display controls, menus, badges, and focus rings. Delete and speaker identities have distinct semantic palettes.

### Brand and Non-neon

The fixed brand gradient uses orange `#FFA52C`, coral `#FF4B65`, pink `#FA27BB`, violet `#8B39FA`, blue `#3261FF`, cyan `#00C8FF`. Use it only for the sidebar waveform mark, branded button border, and AI sparkle. Button interiors are plain. The assistant header sparkle is 20 pt in a 24 pt layout box, with an 8 pt title gap and no badge background/border.

Label the existing `reduceNeon` preference **Non-neon** in Appearance. On: replace brand borders with primary and brand icon/waveform strokes with accent text. Off: restore the fixed gradient. This override works in every mode. It does not remove functional speaker distinction.

## Typography and density

Interface font: Inter where bundled and licensed, with system sans serif fallback. Prefer a bundled outline icon asset set matching the reference, or visually equivalent system symbols; keep accessible labels. Implement the custom sparkle as a scalable vector. Do not add an icon-font dependency.

Reading fonts: Default, Georgia, OpenDyslexic, Monospace. Default is sans serif in Light/Dark and Georgia in Paper/Dark Paper. An explicit choice remains unchanged across appearance changes. Font selection affects reading content in all tabs; navigation, timestamps, commands and chat retain interface typography.

Preserve existing stored `transcriptFontSize` and supported 12–24 pt range. The prototype's 14/15/17/19 choices are preview presets, not a reason to discard a saved 16 pt preference or narrow the native range. New users keep the current 16 pt default. Register a macOS-supported OpenDyslexic OTF/TTF resource; do not ship the prototype WOFF as a native font. Include attribution and the exact font version's licence; preserve current resource packaging.

Transcript density adjusts spacing independently of point size:

| Density | Row vertical padding | Speaker-header gap | Reading line-height target |
| --- | --- | --- | --- |
| Compact | 9 pt | 5 pt | 1.55 |
| Comfortable (default) | 17 pt | 9 pt | 1.75 |
| Spacious | 25 pt | 13 pt | 1.90 |

Native text metrics will differ from browser line-height. Translate targets to extra line spacing based on the selected font's metrics, and validate visually at 12/16/24 pt. Do not calculate spacing by multiplying the whole row height. Retain the Speaker Names toggle already present in the app. Reset Reading Appearance restores default font, 16 pt, Comfortable density, and visible speaker names; it does not change theme/accent or meeting data.

## Assistant and export

Title and toggle: **Ask dBrief AI**. Keep prompt templates, model/provider behaviours, chat history, reasoning presentation, cancellation, read-aloud controls, and scroll-follow logic. A high-contrast user bubble uses the derived primary; assistant answers sit on the panel surface. Keep Copy, Read aloud, and Share / Export reachable without hover.

Share / Export operates on one complete assistant response's `ChatMessage.displayParts.answer`, not `content`, reasoning, user input, the transcript, or the whole conversation. Menu: Copy answer, Download Markdown, Download text. Use native save-panel destinations and atomic file writes; cancel writes nothing. Preserve Markdown for `.md`; use the existing answer-cleaning path for plain text. Disable export while an answer is empty or still generating. Do not create external messaging or automatic sharing.

## Acceptance and delivery

Implementation is complete when the four tabs, panels, playback, appearance/reading preferences, Non-neon, and response export match this spec using actual recordings; current live/processing/recovery flows still work; long transcripts retain stable memory and selection; current data and settings remain compatible; and keyboard/VoiceOver operation covers every new control.

Validate missing analysis/audio, a single speaker, gaps/overlaps, many speakers, long titles/transcripts/summaries, streaming chat, corrupt/unwritable sidecars, and theme/font switches during playback. Compare all four themes with Non-neon on and off. Save final native screenshots for review before release. No publishing, installer distribution, or changes to user's recordings are authorized by this planning request.
