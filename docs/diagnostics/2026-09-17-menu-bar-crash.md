# dBrief 1.4.2 menu-bar crash — 2026-09-17

## Finding and confidence

**Confirmed failure site:** the Swift concurrency runtime dereferences an invalid
executor object during SwiftUI view-task startup on the main thread. This is not
an ordinary wrong-thread assertion. No stop-recording or finalization function
is on the crashing stack.

**Strongly supported mechanism:** an earlier Objective-C exception escaped a
Swift concurrency job, was caught outside that job, and left executor tracking
pointing to expired stack storage. A standalone reproducer on this machine
demonstrates this sequence and the same runtime crash frames.

**Likely original trigger, not yet proven:** AVAudioEngine reconfiguration after
the Bluetooth route changed. The original exception's name, reason, and throwing
stack are not in the supplied report. An unrelated earlier exception or other
memory corruption cannot be excluded. Do not call this an end-to-end reproduced
Bluetooth bug or a verified fix.

## Evidence from the actual crashes

- Incident A3212481-1F35-4DA3-B3E6-BE919E1B1341: dBrief 1.4.2, macOS 26.6.2
  (25G83), 2026-09-17 14:57:24.443 +0200. The installed executable's UUID is
  B33F9E5A-97D4-392E-A08B-91C1532BCB5A, matching the report.
- Main thread: `objc_opt_class + 48` → `swift_getObjectType + 204` →
  `swift_task_isMainExecutorImpl + 36` → `SerialExecutorRef::isMainExecutor + 24`
  → `swift_task_isCurrentExecutorWithFlagsImpl + 72` → `Task.immediate` →
  `_TaskModifier2` → SwiftUI layout. Fault address: `0x1e`.
- The object argument in x0/x19/x20 is `0x16b63d760`; SP is `0x16b63cf00`.
  The putative object is only `0x860` bytes above the current stack pointer.
  x21 is symbolicated as the witness table for `DispatchMainExecutor`.
  This is consistent with a corrupted executor reference into stack storage.
- Another thread is named `HIE: M_ 67d0a9342ab28f97 2026-09-17 14:57:07.963`,
  blocked in `SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION`. Its timestamp
  precedes the final crash by 16.480 seconds. This records an earlier swallowed
  exception; it does not identify the throwing operation or prove causality.
- The earlier 1.4.1 report, `dBrief-2026-09-11-120739.ips`, has the same executor
  checking frames and the same HIE marker fingerprint. Its crash site is instead
  a `RecordingControlsView`/`ForEach` closure. Its object argument is again near
  SP (`0x16fa85c40` versus `0x16fa844e0`). Two different UI entry points exposing the same runtime
  failure argue against a queue-refresh-specific bug.
- The user recalls disconnecting Bluetooth earbuds, clicking the recording
  menu-bar icon, and the application disappearing before Stop was pressed.
  Recovery subsequently preserved the recording. The user confirmed the earbuds
  were also the microphone, making input-device reconfiguration a stronger lead
  than an output-only route change.

## Relevant application paths

- `Sources/dBrief/App/DBriefApp.swift`: `MenuBarView.body` starts a `.task` that
  calls `refreshQueuedCount()` when it appears.
- `Sources/dBrief/UI/ProcessingQueueView.swift`: another appearance `.task`
  calls `refreshWorkQueue()`, including when its disclosure is collapsed.
- `refreshQueuedCount()` delegates to `refreshWorkQueue()`. There is redundant
  refresh work, but nothing in the report proves that redundancy causes this
  crash. The fatal check occurs while SwiftUI is starting a task; its identity
  cannot be recovered from this stack.
- `Sources/dBrief/Audio/AudioCaptureManager.swift:439`: `applyReconfigure`
  pauses or stops the existing engine, removes its tap, changes the input
  device, possibly toggles voice processing, reads a format, installs a new tap,
  and restarts. `scheduleReconfigure` calls this inside a `Task { @MainActor ... }`.
- The surrounding Swift `do/catch` handles Swift/NSError failures, not an
  Objective-C `NSException` escaping an AVAudioEngine call.
- Potential fault sites to observe are input-device rebinding (line 459),
  voice-processing changes (463), tap installation (477), and restart (478).
  A positive sample rate/channel count check alone does not prove that a
  hardware format remains compatible throughout a changing route.
- Device-only changes currently use `engine.pause()` (451). Apple's SDK
  documentation distinguishes pause (retains prepared resources) from stop
  (releases them), and notes that route changes can require connections to be
  reestablished with the new hardware format. This deserves investigation;
  replacing pause with stop alone is not a verified solution.

These audio paths and the two menu tasks are unchanged between tag `v1.4.2`
and the inspected current branch. Commit `b03fd7a` replaced the earlier SwiftUI
microphone menu with AppKit, but was already included in 1.4.2. It may have
removed one place the invalid runtime state was detected without eliminating
the original exception. The later ML-model lifetime fix is a different path.

## Isolated experiment

Source and runner: `executor-exception-probe/` next to this document.

The probe does not access audio devices, recordings, settings, or dBrief.
It deliberately raises a synthetic Objective-C exception from a main-actor
task, catches it outside the run loop, then reuses stack space. It uses the
runtime's executor-query symbol only for diagnostic observation, never as an
application workaround. The injected case intentionally crashes a child process.

Observed with Apple Swift 6.3.3 on the affected machine:

| Case | Executor after run loop / stack reuse | Result |
| --- | --- | --- |
| Normal return | `(0, 0)` / `(0, 0)` | Main-actor check passes; exit 0 |
| Exception contained entirely within Objective-C | `(0, 0)` / `(0, 0)` | Main-actor check passes; exit 0 |
| Exception escapes task | Invalid reference / `(0x12345678, 0x12345678)` | SIGSEGV; subprocess return -11 |

All three cases were verified by running:

```sh
python3 docs/diagnostics/executor-exception-probe/run.py
```

The final run returned exit 0 after checking both successful controls, the
injected child's SIGSEGV, and its stale executor values. Output was saved under
`/var/folders/dt/2wwhnjbs7gqb9tcwmyq55st00000gn/T/dbrief-executor-probe-9kpnotha/`.

Generated report `probe-2026-09-17-153559.ips` contains:

```text
swift_getObjectType + 40
swift_task_isMainExecutorImpl + 36
swift::SerialExecutorRef::isMainExecutor() const + 24
swift_task_isCurrentExecutorWithFlagsImpl(...) + 72
Actor.preconditionIsolated(...)
checkProbe()
```

The initial injected test without deliberate stack reuse happened to pass its
later check. Adding ordinary stack allocation/overwrite exposed the stale
reference. This supports a delayed crash rather than requiring an immediate
failure when the earlier exception is swallowed. It does not recreate the
actual Bluetooth event or establish the source of that original exception.

## What would confirm the original trigger

Reproduce with an isolated beta/debug build and a breakpoint on
`objc_exception_throw` **before** disconnecting the earbuds. Capture the first
exception's name, reason, and backtrace, then stop the test rather than continuing
after the exception. The breakpoint must target the original exception, not the
later SwiftUI segfault. A disposable recording is sufficient.

Do not remove `.task`, disable actor checks, or reset private runtime TLS as a
claimed fix. The fix should prevent the identified native exception at its
source and leave capture in a coherent, recoverable state on route failure.
If an Objective-C boundary is required, native exceptions must be contained
before they unwind through Swift frames; adding another Swift catch cannot do it.

Historical unified logs could not be read: `log show` failed with
`Could not open local log store: Operation not permitted`, including outside the
sandbox. The supplied crash report remains the direct evidence for this event.
LLDB could not attach to the synthetic child due to macOS debug permissions;
the OS-generated crash report supplied its backtrace instead. This investigation
did not change application code or the installed app.

## Primary references

- [Swift 6.3.3 Actor.cpp](https://github.com/swiftlang/swift/blob/swift-6.3.3-RELEASE/stdlib/public/Concurrency/Actor.cpp):
  executor tracking is stack-backed, published in thread-local state with
  `enterAndShadow`, and restored by an explicit `leave()` after job execution.
- [Apple: Handling Cocoa Errors in Swift](https://developer.apple.com/documentation/swift/handling-cocoa-errors-in-swift):
  Objective-C exceptions are distinct from Swift errors and must be caught before
  reaching Swift code.
- Local SDK: `AVAudioEngine.h`, documentation for `pause`, `stop`, and
  `AVAudioEngineConfigurationChangeNotification`; `AVAudioNode.h`, documentation
  for tap format/connection constraints.
