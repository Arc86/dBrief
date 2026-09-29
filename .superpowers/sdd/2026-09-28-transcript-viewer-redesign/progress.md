# SDD ledger — plan: docs/superpowers/plans/2026-09-28-transcript-viewer-redesign.md

Authority: approved spec and revision-13 HTML. Starting HEAD 7f18364; existing edits captured in preexisting.patch/status.

- [x] Task 1: Shared appearance/reading preferences, palette, controls, fonts.
- [x] Task 2: Four-tab shell and preserved state branches (full-app interactive QA blocked; recorded below).
- [x] Task 3: Analysis presentation/editing/persistence (component/automated gates passed).
- [x] Task 4: Time-correct waveform, reading and stable List.
- [x] Task 5: Assistant/export implementation and automated/native component checks.
- [ ] Full-app interactive acceptance: blocked by repeated computer-use service timeouts; explicit pending matrix in review report.

Pre-flight shared interfaces: Task1 preferences/palette -> Tasks2–5; Task2 modes/shared insights ownership -> Task3; Task1 fonts/density + Task2 player ownership -> Task4; Task1 palette + Task2 chat ownership -> Task5. Contracts consistent with spec.
Ruling: User explicitly requests Luna Max delegation for bounded work; root retains complex integration and final review. Stage order remains sequential. No commits until stages verified; preserve unrelated changes at hunk level.
Baseline first attempt: sandbox blocked ~/.cache/clang/ModuleCache before any tests. Retrying with authorized compiler cache access; not a test failure.
Baseline: swift test --filter 'TranscriptSearchTests|ChatMessageActionsTests|RecordingInsightsTests|AppSettingsTests' -> exit0, 33 tests in5 suites passed. /tmp/dbrief-redesign-baseline.log.
Task 1 RED: new preference/palette contracts absent as expected, /tmp/dbrief-stage1-core-red.log. Integration compile caught Font(nsFont:) unsupported label; corrected to Font(nsFont). Full stage1 gate running /tmp/dbrief-stage1-verified.log with opt-in AppKit snapshots.
Task 1 Ruling: use system sans-serif fallback instead of bundling Inter; explicitly allowed by spec, fewer licensed assets. Native OpenDyslexic OTF assets plus exact upstream OFL/notice are bundled.

Task 1 complete: /tmp/dbrief-stage1-final.log exit0, 26tests/6suites. Eight native AppKit captures in /tmp/dbrief-stage1-native-final visually inspected. Fixed intrinsic-height density layout; plain button interiors/no glow observed in four themes with Non-neon off/on. Native OTF PostScript names/embedded versions/OFL verified. Integration Font initializer corrected.
Ruling: retain changes uncommitted during sequential integration; shared files overlap user edits. Review final delta against saved baseline before any selective commit; no unrelated staging.
Task 2 RED: /tmp/dbrief-stage2-red.log expected missing presentation policy/mode contracts. Shell now preserves live/recovery/load branches; shared 920pt column and transcript-only player; fixed search card with retained debounce/match IDs. Stage2 temporarily uses existing combined analysis body for all non-transcript modes; extraction is Task3 as planned.
Task 5 integration note: TranscriptChatView inputText is local @State; tab/theme switches preserve sibling view identity, but hiding/reopening assistant currently loses unsent draft. Preserve draft at existing recording-scoped owner (root binding or transient chat service property), without changing storage format or engine behavior.
Task 2 automated/component gate: 23 tests/7 suites passed (/tmp/dbrief-stage2-tests.log); 2 native snapshot tests passed (/tmp/dbrief-stage2-header.log), 12 actual-header variants plus 8 theme controls. Reviewed narrow/wide images; removed navigation-row fixedSize so divider/utilities use full width. Narrow snapshot fixture needs greater height (QA worker assigned). Local isolated release app built and signed successfully (/tmp/dbrief-stage2-app.log), unique domain com.dbrief.app.viewerqa.redesign20260928 with verified security-scoped /tmp bookmarks and startup activity disabled. CUA getApp timed out after ~974sec before returning state; full-app interaction acceptance remains explicitly pending. Continue sequential implementation with native component gates, retry full UI access later.
Task 3 in progress: separate presentation, one shell-owned editor; add atomic field-scoped analysis edit in existing InsightsStore, preserving latest completion/export/provenance data. No storage format changes.
Task 3 RED /tmp/dbrief-stage3-red.log: missing saveAnalysisEdit contract (plus concurrent MeetingInsightsView still being written). Implemented saveAnalysisEdit in existing actor; editor retains exact raw action strings, dismisses only verified success, surfaces sidecar and linked-Markdown errors distinctly. Added shared stale-analysis banner.
Native interaction blocker confirmed: reset CUA kernel and retry getApp by exact bundle path with15s timeout -> same Computer Use server -10005. QA process is running idle, no new crash log; component NSWindow tests render successfully. Do not mark manual interaction checks passed.

Task 3 gate: /tmp/dbrief-stage3-tests.log 41tests/7suites passed. Nativeactual Summary/Actions/MeetingInsights/editor snapshots checked; corrected Speakers card width, recaptured /tmp/dbrief-stage3-visual-final.log 3tests passed. Summary fullscroll and chosenfont; sharedowner actionsrenderonce; exactkeys and serializedcompletion; common retryableeditor; field-scoped actor merge preserveslatestcompletion/exportmetadata; copysharedmapping. Compileintegration textSelection generic and stale snapshotarguments corrected. No unrelated tests failed.
Task 4 RED: /tmp/dbrief-stage4-red.log missing new timeline/palette/player contracts as expected. Active List now renders ViewerReadingParagraph with chosen font/metrics, explicit density padding/header gap, unchanged segment/turn IDs and List recycling. Search uses theme-adapted current/noncurrent highlight colours. Finished/live speaker text uses shared ID palette; removed weight-based timeline; transcript seek clamps to valid loaded duration and checks file availability. Returning to Transcript synchronizes paused position; other recordings' playback ticks no longer highlight this recording. Actions owner avatars resolve unique matching speaker labels for consistent identity.

Task 4 gate: 54tests/7suites passed /tmp/dbrief-stage4-tests.log. Corrected capture truncation and real paragraph vertical sizing; 7tests/2suites /tmp/dbrief-stage4-visual-final.log. Real player430/920 capture revealed stale lifecycle color cache; removed redundant State cache, resolve colors from cached sampled IDs before Canvas. Verified actual native coloredplayer /tmp/dbrief-stage4-player-final.log 1test passed. A→B→A URL-cache reset fixed; 9tests/2suites /tmp/dbrief-stage4-cache-final.log. Full native interaction remains separately pending CUA blocker. Original unrelated hunks independently checked byte-for-byte preserved.

Task 5 final: export RED /tmp/dbrief-stage5-red.log; repeated-reasoning RED /tmp/dbrief-stage5-tests-first.log corrected in shared ChatMessage parser. GREEN33tests/8suites /tmp/dbrief-stage5-tests-final.log;42nativePNGcaptures /tmp/dbrief-stage5-native. Fullfirst1534/242 had3mockcapturetimeouts; isolated13/1 passed and full --skip-build recheck1534/242 passed (/tmp/dbrief-final-full-recheck.log). Productbuild and isolatedQA makeapp+signatureverifiedpassed. Font/licensebundlebytesverified. Fullappmanualacceptance pending, not claimedpassed. No commits/publishing/distribution/externalmessages.

Reopened 2026-09-28 after beta48 user screenshots: stages2/5 visual parity incomplete; long summary causes whole-workspace overflow. Earlier fixed-size component capture checks missed this production regression. Root tracing native sizing; Luna assigned sidebar composition, assistant composition, and whole-window regression fixture. No new baseline failures declared.

## Beta 48 correction verification

- Reproduced 1944 pt workspace inside 900 pt native window; replaced shell with viewport-bound HSplitView.
- Rebuilt reference sidebar/assistant composition and final row chrome; preserved List/services/preferences.
- Actual beta long-summary/transcript scrolling, tab/player state, search and draft/pane retention checked.
- 12 native whole-window captures + 42 component captures passed.
- Regression evidence partitioned: 1532 sequential tests pass + isolated HTTP4pass; monolithic timing failures and HTTP shutdown hang recorded separately.
- Final local make run-beta passed; 1.4.5 build50 signed and launched; final window check awaits opening Transcript viewer; no publishing/distribution/messages/commits. Broader manual acceptance limits remain explicit in review record.

Final beta50 row/menu check completed after user opened viewer. Found248→360pt sidebar jump on selection; native regression added. Native holding-priority attempts failed (recorded in review), removed. SwiftUI detail.layoutPriority(1) fixes selection width. Focused test1pass; all3workspace tests pass47.861s,12captures /tmp/dbrief-sidebar-final-native. make run-beta51 passed/signatureverified/launched /tmp/dbrief-correction-beta51.log. User asked reopenviewer afterrestart for finalnativewidthcheck. Originalpreservation auditpass; gitdiffcheckpass. No publishing/distribution/messages/commits.

Beta51 nativecheckcomplete:248pt before/afterselection; nativeAXdivider resized300pt andretained acrossanotherrecording; longsummaryscrolloffset1 withheader/sidebar/Record/composerpresent. Restored248pt andoriginalselectedrecording offset0. Finalbetareadytouse. Broaderinteractiveacceptancelimits remainexplicit inreviewrecord.

Headerbarremovalcomplete: nativewindowtoolbarremoved; genuinewindowcontrolsretained; integratedsidebarcontrol+CtrlCmdS; eachsplitpaneusesgeometrybounds topreventnativeinsetandcontentoverflow. Native3testspass15.643s /tmp/dbrief-headerless-bounded.log;12captures. Localmake run-beta/signature/launchpass /tmp/dbrief-headerless-beta.log. Actualnativewindow screenshotconfirmsnoheaderbar; hid/restoredsidebarviaUIretaining248pt. No dataedits orappearancechanges; nopublishing/distribution/messages.

22:38 UI tweaks implemented: shared20ptcardradius; AskAI movedtolowercommandrowwithnarrowfallback; sidebarcontrolsplacedbelowtitlebarclipbesidelogo/visiblecollapsedrestore.10tests/3suitespass13.847s /tmp/dbrief-tweaks-tests.log. InspectedDarkPaperstandard,closed-sidebarLight,and430ptheadercaptures. Beta53built/signatureverified /tmp/dbrief-tweaks-beta.log; initialLaunchServices-600 causedmakeexit2afterpackaging; nativeappacquisitionstartednewbetaPID19768, confirmedidle/running. UseraskedopenTranscriptviewerforoptionalfinallivecheck; nativecapturesalreadyverifyalltweaks. No publishing/distribution/messages/commits.

### Reading-options button anchoring
- Removed the whole-header popover and attached it to the header AA button. Transcript-search AA has independent presentation state and its own anchor; all reading controls share the persisted preferences binding. Live toolbar behavior is retained.
- Eight focused preference/native-header tests passed (2.519 s); twelve captures in `/tmp/dbrief-popover-header`.
- Local beta 54 (1.4.5) built, signature verified, and launched successfully. After the user reopened Transcript viewer, the actual beta screenshot confirmed the popover arrow directly beneath AA. Escape dismissed it; saved reading preferences were left unchanged. The sidebar toggle, rounder cards, and lower AI command-row placement were confirmed in the native app. No publishing or messaging.

### Wider sidebar, response cards, transcript fragments, chat size
- Default sidebar300 pt; same220–360 resize range and width retention.
- Theme-adapted shaded assistant response cards include answer/actions. Assistant-header AA controls independent chatFontSize14 pt by default,12–24 range, persisted via existing AppSettings. Transcript reading reset does not change chat size.
- Short transcript fragments now align/compact; same-speaker short chunks coalesce into display paragraphs while exact Character offsets, IDs, timing, storage and List recycling stay intact.
- 45 focused tests/nine suites passed26.524 s, including four-theme native workspace matrix and eight appearance/Non-neon variants. Logs `/tmp/dbrief-chat-fragments-tests.log`; captures `/tmp/dbrief-chat-fragments-workspace` and `/tmp/dbrief-chat-fragments-native`. No focused-run failures.
- Beta55 built/signed/launched successfully. Final live check awaits reopened viewer after restart.


### Panel motion and manual transcript scrolling (2026-09-29)
- Beta55 actual native fragment/font checks passed: compact aligned fragments, joined known-speaker chunks, independent chat16→18→16, reading15/Default unchanged. Restored original Delft/Meeting Insights/filter/panel state.
- Removed async split correction; width-controlled sidebar starts300 and retains resized width. Panel260ms, modes200ms, popover contents220ms; Reduce Motion disables added motion. Retained assistant hide explicitly stops read-aloud.
- First motion gate:11tests/5suites passed18.230s `/tmp/dbrief-motion-tests.log`, native captures enabled. No failures. Local beta build intentionally cancelled (exit130) before launch for user-added manual-scroll work; interrupted assembly reserved56 but did not launch.
- Manual wheel/trackpad request: cached immutable turn display text/ranges and Equatable native selectable text subtree implemented; gesture-priority observer/tests in progress. Final combined tests/build/native interaction pending.

- Combined final gate:51tests/10suites passed16.129s `/tmp/dbrief-motion-scroll-tests-final.log`; real SwiftUI List attachment, gesture priority, cached Unicode/search ranges, native four-theme panes covered. Initial Equatable actor-isolation compile error corrected with nonisolated immutable comparison; recorded separately, not baselinefailure.
- Weak mounted observer cache avoids per-playback-tick hierarchy traversal; List content-update test and chat-scroll regression recheck16tests/3suites passed0.667s `/tmp/dbrief-motion-scroll-observer-final.log`. Standard DarkPaper native capture inspected. No custom wheel physics or frame-rate claim. Final local beta building.

Local beta 57 (1.4.5) built, passed code-signature verification, and launched successfully through `make run-beta` (`/tmp/dbrief-motion-scroll-beta.log`). Native acquisition timed out because restart closed the menu-bar app viewer; the user was asked to reopen Transcript viewer for final actual panel/manual-scroll checks. Native captures and automated tests above are passed; final actual interaction remains pending, not inferred. No publication, distribution, commits or external messages.

Final beta57 actual check complete after user reopened viewer: immediate300pt sidebar; resize320/hide/reopen retained320, restored300; Delft selection retainswidth. Assistant469pt/draft hide/reopen retention passed; temporarydraft cleared withoutsending. Allfourmodes checked, playeronlyTranscript. Actualmanualwheel reachedmiddle/end254rows scrollbar1 andreturnedtop0 withboundedresponsivepanes. ReadingDefault15/chat16 unchanged; popoveranchors/nativeCancel verified. AutomationEscape whilecomposerretainedfocus didnotdismiss readingpopover; keyboarddismissal notnewlyclaimedpassed. Noframerateclaim. RestoredDelft/MeetingInsights/Peoplefilter/300pt/open469ptassistant/emptycomposer. No realdataedits, publishing, distribution, commits ormessages. Finalgitdiffcheckpassed. Broaderinteractive limits remainrecorded inreview.
