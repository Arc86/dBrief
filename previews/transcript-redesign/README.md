# Transcript Viewer concepts

The approved design is consolidated in `docs/superpowers/specs/2026-09-28-transcript-viewer-redesign.md`; execution steps are in `docs/superpowers/plans/2026-09-28-transcript-viewer-redesign.md`. The implementation handoff uses revision 13 as the visual authority and preserves existing app data/services.

## Current round: Non-neon toggle, revision 13

Open [Non-neon](http://127.0.0.1:8793/pen-review.html?revision=13&theme=dark-paper&mode=summary&nonneon=1). The toggle beside Appearance replaces the multicolour dBrief button borders, AI sparkles, and sidebar waveform strokes with the selected theme-adapted accent. Button interiors remain plain. Switching it off restores the dBrief gradients. The choice persists locally and works across all four appearance modes. Speaker identity colours are retained for distinguishing transcript speakers.

Verified all four themes, shared accent strokes, configurable accent changes, gradient restoration, and persistence. Screenshot: review-thirteen-non-neon.png. App source remains unchanged by mock-up work.

## Previous round: consistent theme-adapted accents, revision 12

Open [the corrected Dark Paper preview](http://127.0.0.1:8793/pen-review.html?revision=12&theme=dark-paper&mode=transcript&accent=%231268F5).

The earlier theme logic adjusted accent text and soft surfaces but left chat bubbles and send/play controls at the raw selected colour. All configurable accent components now derive from a shared effective theme colour: unchanged in Light, brighter in Dark, muted in Paper, and softly warmed in Dark Paper. The original chosen colour stays in the picker and local preference. Foreground text selects white or black for contrast; accent text is adjusted against both the card and selected surface. Fixed dBrief brand gradients and speaker identity colours remain separate from the configurable accent.

Browser checks passed across 24 combinations (blue, violet, green, custom orange, black, and white × four appearances). Chat, send, and play use the same effective primary; tabs, selected library view, and answer label use the same readable accent text. Primary and selected-surface text contrast exceeded 4.5:1. Screenshots: review-twelve-dark-accent.png, review-twelve-paper-accent.png, review-twelve-dark-paper-accent.png. Application source remains unchanged by mock-up work.

## Previous round: Dark Paper, revision 11

Open [Dark Paper](http://127.0.0.1:8793/pen-review.html?revision=11&theme=dark-paper&mode=summary&font=default). This fourth appearance combines warm charcoal and brown-grey surfaces, cream reading text, Georgia by default, muted speaker colours, and restrained borders. It preserves explicit font choices and configurable accent.

Verified theme switching, Georgia rendering, accent contrast (5.05:1 against the card surface for the default blue), local persistence, Transcript playback, and narrow layout. Screenshot: review-eleven-dark-paper.png. App source remains unchanged.

## Previous round: Light, Dark, and Paper, revision 10

Open [Dark](http://127.0.0.1:8793/pen-review.html?revision=10&theme=dark&mode=summary&font=default&accent=%231268F5) or [Paper](http://127.0.0.1:8793/pen-review.html?revision=10&theme=paper&mode=summary&font=default&accent=%231268F5). The Appearance control switches all three modes in place and remembers the selection locally.

Button colour bleed is reverted. Both branded buttons retain the dBrief gradient border and a plain surface interior (white in Light, charcoal in Dark, cream in Paper).

Dark uses charcoal canvas/sidebar surfaces, lighter slate cards, bright text, visible dividers, and lighter speaker colours. Paper uses warm cream cards, beige sidebar and canvas, brown-grey text, restrained borders, and Georgia reading text by default. An explicit font choice such as OpenDyslexic remains selected when switching modes. Interface typography remains sans serif. Configurable accent stays independent and derives readable accent text against each theme surface.

Verification passed for three palettes, removed interior washes, accent contrast, theme persistence, explicit font preservation, Transcript-only playback, 920 px collapsed-panel content width, narrow layout, and picker bounds. Summary and Transcript screenshots for each theme are named review-ten-light/dark/paper-summary/transcript.png. Visual review completed for Dark and Paper. Application source remains unchanged by mock-up work.

## Previous round: button colour wash and useful options, revision 9

Open [the updated mock-up](http://127.0.0.1:8793/pen-review.html?revision=9&mode=summary&accent=%231268F5).

Record meeting and Ask dBrief AI retain their gradient borders and light centre, with orange, pink, and cyan radial colour washes extending inside. Brand colours stay independent of the configurable accent. The chat sparkle is 20 px with a 24 px layout box (revision 8).

The unused Recording options ellipsis is removed: current viewer commands already appear in dedicated controls. Library options remains useful because TranscriptBrowserView.swift exposes Rebuild Search Index there. The preview now opens a menu with that existing command; executing it shows an existing-workflow placeholder rather than rebuilding anything. Duplicate smart-view choices are omitted because they are already in the sidebar.

Verified both button washes, accent independence, Recording options removal, the Library options command, menu closing, and AI toggling. Screenshot: review-nine-buttons-library.png. Application source remains unchanged by the mock-up work.

## Previous round: density and icon-only AI header, revision 7

Open [the density picker](http://127.0.0.1:8793/pen-review.html?revision=7&mode=transcript&accent=%231268F5&display=open).

Display options from either toolbar now includes Compact, Comfortable (default), and Spacious transcript density. Density adjusts row padding, speaker-header spacing, and line spacing independently of font size. Font and size still apply to reading content across all tabs; density applies only to transcript rows. The selection persists locally and Reset to default restores Comfortable plus default font and size.

The chat header uses the dBrief gradient sparkle alone, with no badge background, border, or rounded shape.

Browser verification passed for distinct density row heights (101.5 / 127.5 / 152 px at the checked width), unchanged 15 px text size, font compatibility, reload persistence, reset, both picker triggers, transparent icon container, Escape dismissal, and picker bounds at 1100 × 900. Placement uses fractional bounds to preserve its window margin. Screenshots: review-seven-density.png and review-seven-narrow.png. Application source remains unchanged by this mock-up work.

## Previous round: reading appearance, revision 6

Open [the font-picker preview](http://127.0.0.1:8793/pen-review.html?revision=6&mode=transcript&accent=%231268F5&display=open&font=dyslexic).

All four new annotations are applied. The AI toggle is reduced from 40 px to 32 px high. Playback appears only in Transcript. Summary, Transcript, Actions, and Meeting Insights use the same centred 920 px maximum column; the Transcript player aligns with that column. At narrower widths all views shrink to available space. Transcript keeps its full-height internally scrolling list.

Display options opens a working Reading appearance picker: default sans serif, Georgia, OpenDyslexic, and monospace, with 14/15/17/19 px text sizes and a live preview. Selection applies to reading content across all four tabs, persists locally, and can reset. Toolbar, navigation, and chat retain their interface typography. OpenDyslexic is a proposed new font-family option explicitly requested in this review; actual app source currently exposes font-size choices. Font asset provenance and embedded attribution are recorded in fonts/FONT-NOTICE.txt. Font choice is a user preference; no reading-performance guarantee is claimed.

Verified in the browser: AI height 32 px, all four collapsed-panel columns exactly 920 px, aligned player, Transcript-only playback, real OpenDyslexic font load, font and size changes across tabs, picker dismissal, reset, and narrow layout with the picker inside the viewport. Screenshots: review-six-focus.png, review-six-font-picker.png, review-six-narrow.png. Application source remains unchanged by the mock-up work.

## Previous round: playback and brand revision, revision 5

Open [the transcript preview](http://127.0.0.1:8793/pen-review.html?revision=5&mode=transcript&accent=%231268F5).

All five new annotations are applied. Playback is in its own fixed panel at the bottom of the workspace, available in all four document views. The transcript card fills the remaining height with a fixed search row and independently scrolling turns. Thirteen illustrative turns demonstrate a longer recording.

The waveform colours identify Jesper (blue), Stella (violet), and Speaker 3 (teal), with a name legend and a separate playhead. Colours stay stable across accent changes. Wave heights and speaker intervals are illustrative; implementation must use the existing recording audio and transcript speaker intervals. Seeking updates the position label and marker; actual audio playback remains represented by the existing-workflow placeholder.

Ask dBrief AI and Record meeting are white buttons with the fixed dBrief gradient border. The assistant header replaces the app icon with an AI sparkle drawn using the same gradient. The configurable accent still controls tabs, selection, messages, and playback controls.

Verified in the browser: detached player, full-height transcript, stationary player during transcript scrolling, white gradient buttons, sparkle, three speaker colours, seek labels, accent independence, all four tabs, independent panel toggles, and no horizontal overflow at 1100 × 900. Screenshots: review-five-transcript.png, review-five-focus.png, review-five-narrow.png. Application source remains unchanged by the mock-up work.

## Previous round: annotated review, revision 4

Open [the revised prototype](http://127.0.0.1:8793/pen-review.html?revision=4&accent=%231268F5). All ten browser annotations are applied:

- Four document tabs: Summary, Transcript, Actions, and Meeting Insights. Recording metadata, speakers, tags, sentiment, and processing evidence appear in Insights, using existing app fields. Actions has its own owner-grouped checklist and live completion counts.
- Supplied dBrief logo in the assistant header; title and prominent tab-bar toggle read “Ask dBrief AI”. Sidebar waveform uses the logo’s orange, coral, pink, violet, blue, and cyan colours independently of the configurable accent.
- Duplicate title copy button removed. Re-process is between Edit and Spoken Summary in the command bar. Delete uses fixed red.
- Assistant answer has Share / Export: copy, Markdown download, and plain-text download of the example answer.
- Long summary contains 1,012 words. Independent panel closing and both-panels-closed focus mode remain available.

Screenshots: review-four-summary-app.png, review-four-actions.png, review-four-insights.png, review-four-export.png, and review-four-focus.png.

Browser verification passed for all four views, metadata relocation, logo loading, command order, completion counts, downloaded answer content, independent pane toggles, accent independence, long-summary scrolling, and no overflow at 1100 × 900. All content is illustrative. No application source was changed by this mock-up work.

Pen was unavailable during the final canvas update because no document was open in its editor. The existing browser frames still point at the live prototype, but separate Actions and Insights frames were not added in this round.

## Previous round: Pen palette, extended summary, and panel states

Open pen-review.html for the interactive prototype. index.html forwards to it. round-two.html preserves the previous three-direction comparison.

The source Pen design supplies the light palette: #F6F8FC canvas family, #FBFCFE workspace, white cards and chat, #E1E7F0 dividers, #0B1430 headings, #31405F body text, #1268F5 accent, and #EAF2FF selected surfaces. Secondary text is slightly darkened to #65718A for readability. Sidebar uses the reference’s #FAFBFD → #F1F5FA gradient. Icons follow the reference’s Lucide outline vocabulary, including list, panel-left-close/open, sparkles, list-checks, settings, copy, and ellipsis.

The illustrative summary contains 1,009 words. The document has its own scroll area; summary, actions, and tags flow vertically rather than being truncated into a fixed card. Header, commands, sidebar, and chat stay stationary. Closing both panels releases the document area while keeping the article centred with a maximum 920px outer measure. A collapsed sidebar can reopen from the breadcrumb; chat reopens from the Chat button.

Blue, violet, green, and a custom colour are selectable in the preview. Accent and derived soft tint update together across primary controls, selected navigation, active tab, chat message, send control, and accents. Readable foreground is derived from the selected colour. The preview remembers the selection locally. The requested app preference is proposed under Settings → Appearance; application settings have not been implemented in this mock-up stage.

Pen contains three new live browser frames pointing at the local prototype:

| State | Frame | Browser node |
| --- | --- | --- |
| Long summary, full workspace | w0vxZ | QZZ2C |
| Sidebar collapsed and chat closed | JyDEM | qLvaH |
| Configurable violet accent | p1nZE | Tuz8Y |

The integrated browser sidebar was unavailable; embedding browser nodes on the canvas worked instead. These frames require the local preview server. Existing reference and mock-up frames remain unchanged.

Screenshots: pen-long-summary-app.png, pen-summary-actions.png, pen-sidebar-collapsed.png, pen-focus-app.png, and pen-violet.png.

### Current verification

Browser checks passed for the full summary’s scrolling, actions below it, stationary chat during the action-item jump, independent pane closing/reopening, all three accent presets, Summary/Transcript switching, a 920px reading cap with both panels closed, and no horizontal panel overflow at a 1100px viewport. At 1600 × 1120 the document has 2908px of content in a 655px scroll viewport. The action jump was corrected to scroll only the document, rather than scrolling outer page ancestors.

The design detector’s font warnings are intentional: the user’s chosen reference uses Inter throughout, with hierarchy provided by size and weight. The shadow warning is a false positive: the offset 0 14px 38px shadow reproduces Pen’s #16335C24 window elevation on a light background; it is not a zero-offset glow or a dark surface. These findings were reviewed without disabling rules. Swatch selection rings use outlines. App source remains unchanged.

## Previous round: custom UI

Jesper explicitly approved departing from native-looking macOS UI to match Pen more closely. The gallery now shows custom sidebar navigation, underline document tabs, summary/action cards, and a dedicated Ask AI inspector. Existing smart views are exposed in the sidebar; no new navigation features are invented.

| Current direction | Summary frame / PNG | Transcript frame / PNG |
| --- | --- | --- |
| A · Pen workspace | pCmrc | RhZfN |
| B · Editorial workspace | s0TOo | U7CN5 |
| C · Studio workspace | kYFRe | H8YL6R |

All six current images are 3072 × 2120. The editable frames begin at (0, 9800), with summaries across the first row and transcripts across the second. All final frames report no clipped nodes. The original reference and first-round designs remain intact in Pen and on disk.

Custom controls, panels, navigation, fonts, and styling are allowed in implementation. Preserve window resizing, keyboard commands, text selection, accessibility, reduced motion, safe deletion, and existing data behavior. Native-looking components are not a design requirement. The selected visual direction is still pending; app source remains unchanged.

## First round: historical notes

Three directions, each with Summary and Transcript screens. The assistant is open in every screen, reflecting Jesper’s priorities: AI alongside the content, followed by summary and action review. A is the recommended balance; B favors reading; C favors simultaneous review.

Open index.html to compare the six exported images. They are 2800 × 1880 PNGs. The controls select static mock-ups; pictured app controls are not interactive.

Editable frames were added to the existing Pen document, preserving its original reference frames:

| Direction | Summary frame | Transcript frame |
| --- | --- | --- |
| A · Quiet native | sTLu1 | l25Hx5 |
| B · Reading room | t3l7ms | pJBrp |
| C · Dark workspace | vZUt3 | Vi6HS |

The new frames occupy a two-row comparison area beginning at canvas position (0, 6548). Summary screens are above their Transcript counterparts.

## Functionality boundary

Source inspected: TranscriptBrowserView.swift, TranscriptWindowView.swift, SummaryView.swift, TranscriptChatView.swift, TranscriptPlayerBar.swift, TranscriptLibraryFilters.swift, LibrarySmartView.swift, and TranscriptChat.swift. Current source, rather than the older graph report or the Pen example, determines feature availability.

All directions retain the existing Summary and Transcript modes, summary editing/copying/spoken summary, owner-grouped actions and completion, tags, assistant conversation and prompt templates, library search and filters, record, refresh/settings/library options, speaker names and menus, transcript search and match navigation, waveform playback/seek and speed, copying, reprocessing, display options, privacy receipt, and deletion. Sidebar and assistant can collapse and resize. Earlier rounds added no user-facing features. Revision 4 additionally proposes the explicitly requested Actions and Meeting Insights views, configurable accent, and assistant response export.

Starred/shared/archive navigation, folder management, chapter navigation, speaker filtering, timestamp display toggling, and speaker percentage analytics remain excluded. Separate Actions/Insights tabs and assistant answer export were explicitly requested in the annotated review and are included in revision 4. Header speaker names lead to the current speaker-assignment behavior. Action checkboxes preserve sidecar persistence. Secondary toolbar icons preserve their current menus and sheets.

## Implementation considerations after selection

- Preserve collapsible/resizable library and assistant panes; their visual treatment may be fully custom. C’s two summary columns stack at narrow widths; all variants restore room by closing either pane.
- Keep the recycling native transcript List, text selection, stable row measurements, seek/search-follow behavior, live and recovery states, and reduced-motion behavior.
- Typography and icons may be custom to match the selected Pen direction; no requirement to use system-looking controls or fonts. Pen uses Inter/Lora and Lucide.
- Readable secondary text, distinct selected state, labeled commands, native focus/keyboard behavior, and existing destructive confirmation remain required.
- The illustrative conversation and completed action are sample content, not new AI guarantees or task state. Only fields actually present in a recording should appear in its header.

## Verification

All six Pen frames were checked visually and through canvas bounds. Final bounds report no clipped nodes. No application source was changed; application tests and builds are not relevant to these static proposals.
