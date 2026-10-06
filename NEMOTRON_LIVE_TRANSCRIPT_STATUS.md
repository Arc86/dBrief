# Nemotron live transcript development status

Status recorded 6 October 2026 for `codex/nemotron-native-runner` in `/Users/jesper/.codex/worktrees/1ef7/dBrief`. The last fully verified committed checkpoint is `20b6ed4a09bfc578062e950a54249e6fb70dd3f5`. This snapshot also covers the independently reviewed RAM transcript manager batch following that checkpoint.

The feature remains unfinished. Most backend software foundations are implemented; substantial user-facing integration and native/device qualification remain. Production artifact persistence is default-off, the production Nemotron selector is nil, and measured resource profiles are empty.

## Implemented software

| Area | Current state |
| --- | --- |
| Capture and transcript | Recording-owned live ASR integration, bounded input/VAD ownership, pause/resume/Stop, capture timing, immutable transcript revisions and visible coverage gaps are implemented. Actual hardware/clock qualification remains open. |
| Transcript chat | Answers use a frozen transcript/annotation basis and configured AI route. Historical chats, accepted rows and original request ownership survive later source changes. Resources remain held through actual producer return. |
| History and lifecycle | Capture/chat/final publication, deletion/restart/reprocessing, retention/export ownership and hardware-first bounded no-window normal Quit have software verification. Full lifecycle acceptance remains open, so artifact persistence remains disabled. |
| Task 8 attribution | Source-scoped serial diarizer ownership, exact assets/configuration, helper/app transport, bounded probabilities, conservative unknown/overlap handling, frozen annotation legends and pressure retirement are implemented and reviewed with model-free regressions. Native accuracy, acoustic/emission alignment, speaker-count and combined-load qualification remain open. |
| Task 9 foundations | Separate live/final settings, default Apple live selection, frozen effective preferences, explicit label eligibility and truthful unsupported catalogue behavior are implemented. Transient chat ownership and immutable RAM-only owner policy are verified. |
| RAM history | Capture metadata/age, bounded original cleanup inventories, sticky source retirement, exact retry receipts and resource retention through actual cleanup are implemented and verified. RAM history provides no cold-restart durability promise. |

## Reviewed RAM manager batch

The current batch changes four files:

- `Sources/dBrief/Services/CaptureCoordinator.swift`
- `Sources/dBrief/Services/LiveRecordingSessionRegistry.swift`
- `Sources/dBrief/Services/RecordingManager.swift`
- `Tests/dBriefTests/LiveRecordingManagerIntegrationTests.swift`

It routes RAM transcript retention before missing-artifact-reference deferral, freezes the RAM census and private-backup protection, rejects pending RAM replacements before inspection/effects and after awaited work, and returns exact resident RAM history without inventing disk or Bind authority. Capture freezes the intended recording folder before asynchronous session creation.

A reviewed correction makes retry use the original physical folder witness. The manager verifies safe parents before qualifying the existing `/tmp` and `/var` system aliases. Wrong siblings and arbitrary symlinks cannot inherit the original ticket, cutoff, inventory or per-step stamps. The actual eight-variant manager regression produced 44 issues on the initial product, then passed with the entire test file unchanged after correction.

Independent source and HIGH system reviews found zero unresolved BLOCKER, IMPORTANT or MINOR findings in this four-file package. Its complete patch SHA256 is `f05e0d5af531714eedd01f206f96817cb650156cd477a065cceb8bbb4ba43b85`; the local review manifest SHA256 is `01b46536f178fdbd35646e1b47efde021abf2312f15c0aa2d5d0d47792d1992e`.

## Verification and limits

- Corrected focused confirmation: 54 app tests across four suites passed.
- Corrected affected confirmation: 1,285 app tests and 240 helper tests passed.
- Both independent reviews cleared the exact four source/test blobs. All other 810 source/test files match the committed baseline; original manager test methods, helpers, assertions and deadlines are preserved.
- Corrected full-suite confirmation remains open. Broader runs exposed capacity/Bind, prompt-editor, redirect-helper and warm-helper fixture failures or stalls. Exact isolations passed; those results do not prove stability or the causes of past full-run failures.
- Corrected Release confirmation remains open. Earlier pre-correction Release results cannot qualify the corrected product.
- The last accepted `20b6ed4` checkpoint passed 2,193 app tests, 240 helper tests and Release. Its actual app/helper minimum OS and linked SDK were 14.0.
- All 22 current manager Swift attempts and two AST updates are preserved locally with raw output, receipts and frozen source/test hashes. AST partial-parser warnings do not replace Swift verification.

The warm-helper investigation found an important test boundary flaw: `MLHostConnection.call` returns on a value reply, while that request remains pending until its terminal frame. Capture preparation correctly returns while pending work is busy. A four-suite control run reproduced the old permit assertion without executing new manager tests.

A test-only correction has independent architecture approval but has not been applied: preserve the original value-bearing call and permit assertions, add a terminal-consumed `startStream(.isLLMCached)` query with ordinary default arguments, join `waitForReturn()`, and verify the warm permit remains held until actual helper exit. A controlled fixture must hold one exact query UUID after its value reply and release it explicitly, proving both busy and terminal-complete behavior. Production transport, pending-request rules and lease refunds must remain unchanged. No assertion or deadline has been relaxed.

## Remaining work, in order

1. Apply and verify the approved test-only boundary correction; obtain complete final source/HIGH reviews and required full-suite/Release confirmation for the resulting package.
2. Complete actual RAM recording expiry and manual deletion using exact original `FileDeletionTicket`/`DeletionState` authority, maintenance admission before inventory, sticky recording intent, per-step result stamps and bounded recovery/privacy cleanup through actual asynchronous completion.
3. Activate Apple/off RAM capture only after those prerequisites pass. Verify late Start/Stop, Pause, engine/source changes and single-consumer capture behavior.
4. Implement shared registry/store-backed captions and transcript windows, visibility-independent transcription/chat, multiple recordings, follow/selection/search/copy behavior and accessibility.
5. Retain the portable export snapshot wrapper and its lease through actual UI output. Copying its `Data` alone does not retain ownership.
6. Run authorized native acoustic/alignment, two/four/eight/nine-speaker, overlap/echo, combined local-chat, physical capture-clock and release/UI evaluations before admitting supported configurations.

## Invariants and continuation

Keep macOS 14 compatibility and FluidAudio `0.17.4`, revision `21493f8dac5a97e65742e6ff26f42f164c2fda0f`. Native gate N is waived, not passed; capture gate C and release gate R remain open. No source test establishes model/device, RSS or syscall qualification. Do not download or load models without authorization.

The shared 128 MiB payload accounting includes owners, catalogue and inspection. Four full 32 MiB owners plus overhead do not fit. Preserve exact generation/physical authority, explicit inventories, retention/recovery tickets, recorded per-step output stamps, sticky retirement, historical chats/frozen answer basis, unknown/foreign/opaque files, offline storage and privacy guarantees. Never refund resources merely because a caller cancelled or timed out.

Feature source belongs only in the isolated worktree. Preserve the original checkout at `66797f1e1f3168a817760eb4b73f826c47353062`, branch `fix/parakeet-long-aac-and-hf-token`. Mirror only documents/canonical handoff using fresh preconditions, verified backups and independent saved-byte/tracked-file/Git checks. Detailed workflow records in `.ai/` and `.remember/` are intentionally untracked and are not included in this checkpoint.

Follow dev-workflow HIGH and applicable repository instructions; required independent reviewers are read-only. CodeGraph is absent: do not index it. Use the existing graph for code navigation and update it after source edits. Never edit source/tests during a live Swift command.

After rebuilding, full confirmation is:

```sh
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4 swift test --disable-automatic-resolution --skip-build
swift build -c release --disable-automatic-resolution
```

Avoid `--build-system xcode`. A checkpoint commit or branch push does not close Tasks 8–9 or authorize production exposure.
