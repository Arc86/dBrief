# Prompt Editor and AI Assistance — Design

**Status:** Draft implementation specification, based on the prompt-editor designs reviewed in this conversation. No application implementation is included.

**Outcome:** Users can comfortably edit every existing settings prompt, ask their configured AI to revise it, and try the draft before saving.

## Design references

- [Editor prototype](/Users/jesper.mol/.codex/visualizations/2026/09/15/01a0a6a3-a9bd-71e0-a2a9-d5cda15c7835/prompt-editor.html)
- [AI assistance prototype](/Users/jesper.mol/.codex/visualizations/2026/09/15/01a0a6a3-a9bd-71e0-a2a9-d5cda15c7835/prompt-editor-ai.html)

These are interaction references. Their sample configuration and responses are illustrative. Native implementation uses the actual configured services and preserves the current Settings navigation.

## Global constraints

- Keep the macOS 14 deployment target and Swift 6.2 package tooling; gate FoundationModels at macOS 26.
- Use SwiftUI and AppKit with existing dependencies; add no AI SDK, credentials flow, or package dependency.
- Preserve existing prompt preference keys, profile precedence, and the version-1 profile export envelope.
- Opening or editing a profile must not activate that profile or change automatic recording routing.
- Prompt drafts, AI suggestions, and preview results must not mutate saved settings before Save.
- Preview runs must not modify recordings, transcripts, insights, exports, chat history, or their privacy receipts.
- Keep spoken-summary and voice-style prompts global; only Summary, Action Items, and Tags & Sentiment support profile overrides.
- Keep existing advanced-settings visibility and voice-model capability gates.

## 1. Entry points and editing scope

| Prompt | Existing key | App defaults | Profile override |
|---|---|---|---|
| Summary | `summaryPrompt` | Yes | Yes |
| Action Items | `actionItemsPrompt` | Yes | Yes |
| Tags & Sentiment | `tagsPrompt` | Yes | Yes |
| Spoken Summary | `spokenSummaryPrompt` | Yes | No |
| Voice Style | `ttsDeliveryInstruction` | Yes | No |

Replace small inline text views with a reusable row: name, Default/Customized/Inherited status, two-line preview, and **Edit Prompt…**. Leave rows in their existing Settings sections. Search still reveals those sections and the editor button.

Each editor has an immutable identity: prompt kind plus app-default scope or an explicit profile UUID. Header copy says **App defaults** or **[Profile name] only**. App-default explanatory text states that inheriting profiles are affected. Never derive the edited profile from `activeProfile` after opening.

Inherited profile prompts remain inherited when opened and cancelled. Editing creates a draft override. **Use app default** stages removal of the override; Save writes `nil`. Matching default text is not itself proof of inheritance.

## 2. Native editor

- Dedicated normal, resizable window. Initial content size 980 × 700 points; minimum 680 × 500. Remember frame and pane width. Reopening the same identity focuses its existing window.
- System font at 16 pt initially, adjustable from 14–22 pt. Persist this preference separately from prompt content. Native selection, spelling, Find, undo/redo, copy/paste, keyboard navigation, and VoiceOver labels.
- Editor dominates the window. One optional side panel shows either AI assistance or testing. At narrow widths, use an explicit Editor/Assistant/Preview section switch instead of shrinking text. Keep footer actions visible.
- **Start from…** offers curated, kind-specific concise/detailed templates where appropriate. Templates change the draft through undo. Preserve output contracts and original language; do not expose generic meeting templates for voice delivery.
- Footer: Restore default / Use app default, dirty state, Cancel, Save changes. Save is disabled for an unchanged or blank custom draft. Restoring a default is reversible until saved.

**Draft lifecycle:** Typing changes session memory immediately. Save compares the original persisted value with the current value and commits only the selected field. Concurrent edits show a conflict with Reload saved / Keep editing; never overwrite automatically. Profile deletion leaves the draft available to copy and blocks Save with an explanation. Native window close and Cmd-W use the same save/discard flow. App quit also resolves dirty editors before termination; follow the existing termination lifecycle rather than invoking an unconditional exit.

**Undo:** Native undo covers typing, templates, default restoration, and accepted AI replacements. One-step **Undo AI edit** returns to the pre-application draft if no later edit intervenes. Longer-lived version history is a subsequent enhancement, outside this first implementation.

## 3. Improve with AI

1. Click **Improve with AI…** and enter an optional improvement request. Blank means “Improve clarity while preserving intent.” Offer Shorter, Clearer, More specific shortcuts.
2. Show the resolved engine/model and processing destination before **Suggest improvements**. Resolve AI from the scope being edited, including an inactive profile’s own overrides. For a global spoken prompt, use the global AI settings.
3. Send the current prompt, its purpose and output constraints, and the user’s improvement request. Do not include recordings, calendar data, or chat history. Treat the prompt to be edited as data rather than instructions for the editor model.
4. Display a revised prompt and a short model-provided explanation beside the unchanged draft. Collapse the request controls to leave room for comparison. A generated suggestion is not a quality guarantee.
5. **Use suggestion** replaces only the draft. **Discard** dismisses it. The user may edit, test, undo, or save afterward.

### Engine routing

| Configured engine | Revision transport |
|---|---|
| Apple Intelligence | Fresh FoundationModels session, availability checked |
| Gemma 4 E4B Local (`qwenLocal`) | Existing helper `chatStream`, collected to a bounded result |
| Remote Endpoint | Existing AIService transport for OpenAI-compatible or Anthropic endpoints |
| Local CLI | New task-specific completion entry point through the configured command and existing stdin/environment contract |

Do not silently substitute the chat fallback engine for prompt revisions. Local CLI is externally managed; do not label it as guaranteed on-device processing. A fixed command that only supports meeting-insight output may reject revision requests: surface that incompatibility without rewriting the command or switching engines.

### Request behavior

Snapshot route configuration per request and show it with the result. If configuration changes, cancel/invalidate pending work and require a new request. Only a completed, validated suggestion for the current prompt, scope, request, and configuration can be applied.

Expose Generating / Cancel / Ready / Failed states. Cancelling, closing the window, or starting a new request invalidates older results. A late response cannot update another draft. Empty, malformed, oversized, partial, or cancelled results cannot replace a draft.

Use an explicit JSON response envelope: `{"prompt":"…","changes":["…"]}`. Validate nonempty prompt and at most five short change explanations. Strip surrounding fences/reasoning with existing cleaning helpers before parsing; do not guess a prompt out of arbitrary prose. Retrying is user initiated.

Revision inputs are never silently truncated. Initial application limits: 8,000 combined prompt/request characters for Apple Intelligence; 32,000 for other engines; 65,536 response characters. These are conservative UI bounds, not guaranteed token capacities. Provider context failures keep the draft and show a shorten-input/retry action.

## 4. Try a draft

A bundled example works without existing recordings. The recording picker lists recordings with available transcripts. Capture an immutable text/insight snapshot at Run test; never run the recording pipeline or save/reprocess a recording to obtain a preview.

- Summary, actions, tags: use the same task prompts, vocabulary, output-language rules, output parsing, and engine configuration as production analysis. For unified engines, replace only the selected guidance field and display the selected result.
- Spoken Summary: use existing saved insights, or the bundled example insights, to generate a script. Do not implicitly analyze a recording that has no insights; offer the example instead. Match the existing spoken-summary execution route, including a clearly disclosed configured chat fallback for Local CLI.
- Voice Style: use the existing `VoicePreviewPlayer` with a short sample and a temporary override of the instruction parameter. Audition is available only for a voice/model that honors delivery instructions. No prompt save is required.

Show actual processing destination before Run test. Remote testing sends the selected text; AI improvement sends only the prompt and improvement request. Reuse production transcript truncation rules and state when a sample is shortened. Token/context failure must be explicit.

Result state is bound to draft revision, sample identity/content, and execution configuration. Any relevant change marks it outdated. Preview does not claim that an AI-edited prompt is automatically better.

Use a temporary session privacy context and temporary audio files, cleaned on cancel/close. Model preparation may use existing model caches; it must not reconfigure the app or begin merely because the editor opens. Live generation and model preparation begin only from the relevant user action.

## 5. Delivery and acceptance

Deliver in order: shared editor → configured-AI revisions → safe previews. Each is independently usable; incomplete actions stay absent until implemented.

Acceptance requires native keyboard and accessibility checks, persistence/profile isolation tests, cancellation and stale-response tests, both remote API shapes, CLI subprocess behavior, read-only preview tests, and `make app` packaging. Hardware/service-dependent checks must be marked as actually run or unavailable; deterministic stubs do not count as a live provider test.

### Deliberate limits

This work does not add a central prompt library, cloud sync, multiple saved variants, persistent revision history, automatic AI scoring, automatic model fallback for revisions, or new profile fields. The prototype’s combined list of all prompts is illustrative; existing Settings locations remain the entry points.
