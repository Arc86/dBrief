# Prompt editor development progress

Plan: [2026-09-15-prompt-editor.md](2026-09-15-prompt-editor.md)
Worktree: `.worktrees/prompt-editor`; branch `codex/prompt-editor`.

- [x] 1. Scoped drafts and persistence
- [x] 2. Native editor and Settings integration
- [x] 3. Configured AI completion
- [x] 4. Review/apply AI suggestions
- [x] 5. Read-only previews
- [x] 6. Release build, independent review, and automated native acceptance
- [ ] Manual click-through / VoiceOver / live providers — computer-use limitation recorded below

## Implementation decisions

- The native editor owns an in-memory draft and UndoManager. Settings change only on Save. Profile targets use immutable UUIDs, including inactive profiles; inherited values remain nil until explicitly overridden.
- A dedicated window is reused per prompt/scope. Font size, window frame, and native divider positions use local preferences. Close and quit resolve dirty drafts.
- AI completion snapshots the configured engine and destination. Results require matching request identity, draft, and configuration; configuration changes permanently invalidate suggestions. Applying a suggestion edits the draft and supports Undo.
- Preview reuses the pure `ProcessingPipeline.analyze` transformation for exact production prompt construction and parsing. It never enqueues recording jobs or invokes recording persistence/export/integration APIs. The spoken input builder is shared with production.
- Non-recording operations run with a nil `PrivacyTrace` context, following existing non-recording behavior. No existing recording receipt is modified, and no temporary receipt file is created. This replaces the proposed temporary privacy context.
- Run test snapshots the already loaded sample and owns both scheduled and active tasks. Closing or changing the preview cancels dispatch and rejects late output. Reading transcript/insight sidecars does not write them.
- Local CLI uses bounded concurrent pipe handling and process-group cancellation; arbitrary command output and provider bodies never appear in prompt error copy.

## Review

Independent code review identified and fixes cover:

1. Delayed sample loading could dispatch after closing: removed the asynchronous load from Run test and made launch cancellation session-owned.
2. Configuration observation was limited to the visible AI panel: moved it to the editor root and permanently invalidated suggestions.
3. Native Undo lost inheritance or history on layout changes: session-owned UndoManager restores complete PromptValue snapshots.
4. Actionable errors were over-sanitized: fixed typed errors display directly, flattened analysis failures are sanitized once, and spoken truncation notices measure actual insight input.

## Verification so far

- Baseline: 25 SettingsProfileScope / UnifiedInsightsPrompt tests passed.
- Initial red build established missing new interfaces before implementation.
- Focused integration: `/tmp/prompt-green4.log`: 74 tests / 19 suites passed, including CLI child-process cancellation, concurrent stderr, timeout, provider shapes, routing, and privacy isolation.
- Full first run: `/tmp/prompt-full.log`: 1239 tests / 208 suites, 21 helperUnavailable issues because existing tests resolve `.build/debug/dBriefMLHostStub` relative to the worktree. Corrected by symlinking worktree `.build` to the shared cache; rerun pending.
- Builds use the existing repository `.build` scratch directory, serially; application source edits remain isolated in the feature worktree.
- Native acceptance and release results are recorded below when complete. Live provider calls and VoiceOver must not be claimed unless actually exercised.

## Final verification

- `swift test --scratch-path /Users/jesper.mol/code/VoiceRecorder/.build`: **1239 tests / 208 suites passed** (`/tmp/prompt-full2.log`). The helper-path failures above are resolved; no skipped workaround tests were needed.
- `swift build --scratch-path /Users/jesper.mol/code/VoiceRecorder/.build -c release --arch arm64`: **passed** (`/tmp/prompt-release.log`). Existing FolderPathControl Swift-concurrency warnings remain unchanged.
- Packaged `dBrief-Prompt-Dev.app` from the release binary. Bundle identifier `com.dbrief.app.promptdev`, Sparkle update feed stripped, ad-hoc code signature verified with the Makefile's `codesign --verify --deep --strict` step. The Makefile copied the verified release executable before signing; code signing subsequently modifies the Mach-O signature.
- Packaging used a temporary copy of Makefile with `find -H .build` to follow the shared build-cache symlink. No production Makefile change is needed for ordinary non-symlink builds.
- Final independent review closed every reported blocker and P2 finding.
- Native app process launch was confirmed. Computer-use attachment timed out for this menu bar app; a process sample showed the main thread normally waiting in the AppKit event loop, not blocked in application code. The isolated debug process was terminated before replacing it with the release bundle.
- Manual click-through checks, VoiceOver, and live Apple/remote/local-model improvement and voice synthesis remain **unverified**. No real recording was sent to a provider. Remote provider formats, CLI processes, generation/cancellation, and scoped persistence were exercised by automated tests.

## Try the build

Open `.worktrees/prompt-editor/dBrief-Prompt-Dev.app`, then its menu bar waveform → Settings → AI → Edit Prompt. This development identity has separate preferences, credentials, and Application Support data. Configure an AI engine there before testing live suggestions. No release was published or installed over the production application.

- Added `PromptNativeEditorTests.typingUndoSurvivesPanelAndSizeChanges`: creates a real SwiftUI/AppKit editor window, enters text through NSTextView, switches the AI pane, resizes to 700×530, returns to the editor, and verifies Undo history, unchanged saved preferences, restored native text, and bounded window height. **Passed** (`/tmp/prompt-native-tests.log`).

- Final complete suite including the native regression: **1240 tests / 209 suites passed** (`/tmp/prompt-full-final.log`). `git diff --check` passed. Production sources are unchanged since the successful release build; the final addition was test-only.

## 2026-09-16 — Modern macOS appearance

User feedback: the editor works, but its header, dividers, and button rows look too classic.

- Adopt a real AppKit unified window toolbar for Improve, Preview, and secondary prompt actions. Standard toolbar items use the current OS material and accessibility behavior; the window retains its native title, subtitle, and traffic lights.
- Reduce the scope banner and save bar, create an inset opaque writing surface and rounded inspector, and group inspector mode navigation at the top. Restoring defaults and undoing AI edits remain available in the toolbar options menu.
- Use the native macOS 26 glass-prominent style for primary actions, with a bordered fallback on older systems. Keep document and result content opaque. System appearances handle light/dark mode and accessibility material preferences.
- Use SF Symbols, standard ControlGroup text-size buttons, readable paragraph spacing, compact engine labels, and a clearer preview empty state.
- Existing draft, persistence, generation, cancellation, and profile routing code is unchanged.
- Apple reference: https://developer.apple.com/videos/play/wwdc2025/310/
- First focused regression: 69 tests / 17 suites passed, including the real native typing/Undo/resize test with the new toolbar installed. Appearance rendering and beta packaging results follow.

- Complete regression: **1240 tests / 209 suites passed** (`/tmp/prompt-modern-full.log`). Native typing, toolbar installation, resizing, and Undo passed. Removed the optional screenshot-export diagnostic afterward; no application source changed after verification.
- The native screenshot exporter produced unusable images; those files were removed. CUA attachment to the beta also timed out. Manual visual confirmation remains open; macOS 27 was not exercised.
- `make beta` (using the documented shared-cache Makefile adjustment): **passed**. Produced **dBrief Beta 1.4.2, build 36**, signed with `dBrief Beta Self-Signed`; strict signature verification passed. Update feed is absent. Build log: `/tmp/prompt-modern-beta.log`.
