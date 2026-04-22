# Audio Pipeline Rewrite — Design Spec

**Date:** 2026-04-22
**Status:** Approved
**Supersedes:** `2026-04-21-audio-quality-fix-design.md` (surgical fix did not hold — architecture was the root cause)

## Summary

The current recording pipeline uses `AVAudioPlayerNode`s to bridge two heterogeneous real-time streams (SCStream system audio and AEC-processed mic) into an `AVAudioMixerNode`. Player nodes are designed for replaying buffers of a known format, not for real-time stream bridging — format mismatches between a player node's connection format and the scheduled buffer's format silently resample or drop audio. This is why system audio plays back at low volume and wrong pitch, and why the mic track goes silent after `setVoiceProcessingEnabled(true)` reconfigures the input unit post-start.

The rewrite replaces the single-engine mixed pipeline with **two fully independent capture paths** — system audio straight to `system.caf`, mic straight to `mic.caf` — merged into a single M4A at finalize time via a one-shot `ffmpeg amix` invocation. This is the approach used by OBS, Audio Hijack, Loom, and other professional recording apps. It eliminates the entire class of real-time format-matching bugs, isolates each capture path for debuggability, and preserves the AEC that prevents laptop-speaker reverb.

Final output format changes from FLAC (48 kHz stereo, ~450 MB/hour) to M4A/AAC (96 kbps stereo, ~40 MB/hour). Old FLAC recordings on disk remain playable and transcribable.

---

## Section 1 — Capture Architecture

Two independent capture pipelines, owned by `AudioCaptureManager`, never touching at the audio level.

### System audio pipeline

`SystemAudioCapture` (SCStream, 48 kHz stereo) → SCStream delegate converts each `CMSampleBuffer` to `AVAudioPCMBuffer` → `AudioTrackWriter(role: .system)` → `{base}_system.caf` on disk.

No engine. No mixer. No player nodes. The SCStream delegate is the only component between the OS audio tap and the file.

### Mic pipeline

`AVAudioEngine` with `setVoiceProcessingEnabled(true)` (AEC/AGC/noise suppression) → `inputNode.installTap(...)` → tap handler hands buffer to `AudioTrackWriter(role: .mic)` → `{base}_mic.caf` on disk.

One engine, one tap, one file. The engine exists only to host the input node; no mixer is attached.

### Mic-only fallback

When `CGPreflightScreenCaptureAccess()` returns false, only the mic pipeline runs. The finalizer handles the single-track case by skipping `amix` and transcoding the mic CAF directly.

### Intermediate file format

Core Audio File (`.caf`) container with linear PCM Int16 payload.

- **Chunk-oriented format** — a mid-recording crash leaves a playable file without header fix-up. Contrast with M4A, where the `moov` atom is written on close; a half-written M4A is unrecoverable.
- **Int16 not float32** — halves on-disk size during capture without audible quality loss for speech (Int16 has ~96 dB dynamic range). Disk budget during a 90-min mixed recording: ~340 MB for stereo system + ~170 MB for mono mic ≈ 500 MB, deleted after merge.
- **Native to AVFoundation** — `AVAudioFile` writes CAF/LPCM reliably with no encoder involvement.
- **Native to ffmpeg** — reads CAF without special flags.

### Public API (`AudioCaptureManager`)

Existing callers depend on these; signatures preserved where possible:

```swift
func startRecording(to baseURL: URL, inputDeviceUID: String?) async throws
func stopRecording() async
func pauseRecording()
func resumeRecording() throws
var duration: TimeInterval { get }
var peakLevel: Float { get }
```

Changes:
- `startRecording(to:)` now takes a **base URL without extension**. The manager derives `{base}_system.caf` and `{base}_mic.caf` internally. `RecordingManager` constructs the base URL from the dated folder + title stem, as today.
- `actualFileURL` is removed. Replaced by `trackURLs: CapturedTracks?` where `CapturedTracks` is a struct with `systemURL: URL?` and `micURL: URL?`. The finalizer consumes this struct.
- `peakLevel` continues to report mic peak (for `FloatingMiniPlayer`). The mic writer is the source.
- `pause` / `resume` use each pipeline's native mechanism: `AVAudioEngine.pause()` / `.start()` for the mic, `SCStream.stopCapture()` / `startCapture()` for system audio (SCStream has no pause). Writers stay open across pause/resume. No drain sleep is needed at stop — there is no real-time mixer whose scheduled buffers might be cancelled.

---

## Section 2 — `AudioTrackWriter`

New class at `Sources/dBrief/Audio/AudioTrackWriter.swift`. Replaces `AudioFileWriter`.

### Responsibilities

Accept `AVAudioPCMBuffer`s. Write them to a CAF/LPCM Int16 file. Track peak level. That is the entire job.

### Shape

```swift
final class AudioTrackWriter: @unchecked Sendable {
    enum Role: String { case system, mic }

    init(url: URL, role: Role)
    func write(_ buffer: AVAudioPCMBuffer) throws
    func close()
    var peakLevel: Float { get }   // thread-safe, updated on each write
    var fileURL: URL { get }       // the path being written to
}
```

### Behavior

- **Lazy file creation on first write.** First-write inspects the incoming buffer's format and creates the `AVAudioFile` at exactly that sample rate, channel count, and interleaved flag, with output format `kAudioFormatLinearPCM` / Int16. No real-time resampling ever runs — the format is inherited from the stream.
- **Format-mismatch drop, not convert.** If a later buffer's format differs from the file's format, log once and drop it. No `AVAudioConverter` path. (The converter path in the old `AudioFileWriter` is what caused the original pitch shift — we do not restore it in any form.) In practice the format never changes within a single recording because each source is stable.
- **Peak level** computed per-buffer from the floatChannelData (convert Int16 via the read-side API if needed; in practice the buffer still arrives as float32 from AVAudioEngine and SCStream — the conversion to Int16 happens inside `AVAudioFile.write`). Exposed via `lock.withLock`.
- **`close()` is idempotent and synchronous.** CAF has no trailing header to finalize — close is just releasing the file handle. Safe to call from any context including error paths.

### What it is NOT

- Not a mixer. Does not accept inputs from multiple sources.
- Not a format converter. Does not resample.
- Not FLAC-aware. Writes linear PCM only.
- Not a shared singleton. One instance per track per recording.

---

## Section 3 — Finalization

`Sources/dBrief/Services/RecordingFinalizer.swift`. The `finalize(...)` entry point gains a new inputs shape; `transcodeWithFFmpeg` is rewritten.

### Input

```swift
struct CapturedTracks: Sendable {
    var systemURL: URL?   // nil if system capture was unavailable (no screen recording permission)
    var micURL: URL?      // nil if mic capture was unavailable (no mic permission)
}

func finalize(tracks: CapturedTracks, snapshot: Snapshot) throws -> RecordingFinalizationResult
```

At least one URL must be non-nil. Both-nil is rejected before the recording starts (no permissions path already covered by `AudioCaptureError.noMicrophoneAccess`).

### Output

`masterAudioURL` becomes a `.m4a` path. Other fields unchanged. Segment URLs (for recordings > 30 min) are also `.m4a`.

### ffmpeg command — mixed mode (both tracks present)

```
ffmpeg -y \
  -i {system}.caf \
  -i {mic}.caf \
  -filter_complex "
    [0:a]highpass=f=40,lowpass=f=12000[sys];
    [1:a]highpass=f=80,loudnorm=I=-16:TP=-1.5:LRA=11[mic];
    [sys][mic]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0[out]
  " \
  -map "[out]" \
  -c:a aac -b:a 96k \
  -ar 48000 -ac 2 \
  -movflags +faststart \
  -metadata date={ISO8601} \
  -metadata title={normalized-meeting-title} \
  -metadata duration_seconds={int-seconds} \
  {output}.m4a
```

Rationale per filter:

| Piece | Purpose |
|-------|---------|
| `highpass=40` on system | Remove subsonic rumble without touching speech. |
| `lowpass=12000` on system | AAC at 96 kbps has no content above ~12 kHz for music/UI sounds; pre-lowpassing avoids encoder artifacts. |
| `highpass=80` on mic | Remove handling noise / HVAC rumble. |
| `loudnorm=I=-16:TP=-1.5:LRA=11` on mic | Compensate for the AGC dynamics flattening from voice processing. `-16 LUFS` is slightly quieter than broadcast-standard `-14` to leave headroom when summed with system audio. `TP=-1.5` keeps the peak below clipping. `LRA=11` preserves natural conversational dynamics. |
| `amix ... normalize=0` | **Critical.** Default `normalize=1` halves each input's volume to prevent clipping; `=0` keeps intended levels and relies on the loudnorm headroom. Without this, everything sounds thin. |
| `aac 96k stereo 48 kHz` | ~40 MB/hour; matches SCStream's native rate so no resampling; standard container for mobile/web playback. |
| `+faststart` | Move the `moov` atom to the front so the file is seekable without full download — nice for Obsidian embeds and chunked remote endpoint uploads. |
| **No `afftdn`** | Yesterday's spec removed it because it strips consonants and muddles speech; the rewrite does not bring it back. |

### ffmpeg command — mic-only mode (system track missing)

```
ffmpeg -y \
  -i {mic}.caf \
  -af "highpass=f=80,loudnorm=I=-16:TP=-1.5:LRA=11" \
  -c:a aac -b:a 64k \
  -ar 48000 -ac 1 \
  -movflags +faststart \
  -metadata ... \
  {output}.m4a
```

Mono at 64 kbps — half the bitrate, same perceived quality for a single voice.

### ffmpeg command — system-only mode (mic missing)

Symmetric: stereo at 96 kbps, `highpass=f=40,lowpass=f=12000` on system, no loudnorm (loudnorm is tuned for voice, not meeting apps' mixed audio).

### Post-merge cleanup

1. On ffmpeg success: delete both `.caf` files.
2. If `snapshot.duration > 1800` seconds: run `-c copy -f segment -segment_time 1800` against the M4A. AAC copy-segmenting is lossless and sample-accurate.
3. Write JSON metadata (unchanged logic, updated extensions).

### Fallback — ffmpeg missing

Today's "raw FLAC move" fallback becomes "keep both CAFs, mic takes the master slot":

1. If mic track exists: rename `{base}_mic.caf` to `{base}.caf`, set it as master, add warning to metadata.
2. Else: use `{base}_system.caf`.
3. Either way, metadata warning surfaces ffmpeg-missing to the user.

This is a strict regression vs today (today's fallback produces a single FLAC) — but ffmpeg has been a hard dependency since the 2026-03-30 memory-hardening work, and onboarding already checks for it. Acceptable.

---

## Section 4 — Impact Surface

Exhaustive list of files touched, kept for the plan.

### Deleted

- `Sources/dBrief/Audio/AudioMixer.swift` — the dual-player-node mixer is gone.
- `Sources/dBrief/Audio/AudioFileWriter.swift` — replaced by `AudioTrackWriter`.
- `Sources/dBrief/Audio/MicrophoneCapture.swift` — dead code; `AudioCaptureManager` owns the mic engine directly (already does, today).
- `Tests/dBriefTests/AudioFileWriterTests.swift` — replaced.

### Rewritten

- `Sources/dBrief/Audio/AudioCaptureManager.swift` — public API preserved except `actualFileURL` → `trackURLs`. Internals rewritten around two writers. Dual-engine mic+mixer topology removed; a single `AVAudioEngine` for mic, plus the SCStream, plus the two writers.
- `Sources/dBrief/Audio/AudioTrackWriter.swift` — new.

### Changed (small)

- `Sources/dBrief/Services/RecordingFinalizer.swift` — `finalize()` signature takes `CapturedTracks`. `transcodeWithFFmpeg` rewritten for the three modes (mixed / mic-only / system-only). Segmenting extension changes to `.m4a`. Fallback rewritten for the two-CAF case.
- `Sources/dBrief/Services/RecordingManager.swift` — constructs a base URL (no extension) for `startRecording`; receives `CapturedTracks` from the manager; passes to finalizer.
- `Sources/dBrief/App/AppSettings.swift` — remove `audioSampleRate` and `audioBitRate` properties (already unused post yesterday's change). Add `acousticEchoCancellation: Bool` (default `true`). Orphaned `UserDefaults` keys left in place — harmless.
- `Sources/dBrief/UI/SettingsRecordingTab.swift` — remove any surviving sample rate / bit rate UI (likely already removed). Add **Acoustic Echo Cancellation** toggle, tooltip: "Removes meeting audio from your microphone track when using laptop speakers. Recommended."
- `Sources/dBrief/Utilities/WebhookPayloadBuilder.swift` / `Sources/dBrief/Services/IntegrationDispatchService.swift` — flip MIME type from `audio/flac` to `audio/mp4` for the master file. One-line edit in each.

### Unaffected — verified

- `Sources/dBrief/UI/RecordingHistoryView.swift`, `PostRecordingSheet.swift`, `TranscriptWindowView.swift` — consume `masterAudioURL` opaquely; AVFoundation handles `.m4a` without changes.
- `Sources/dBrief/Services/AudioPlayer.swift` — `AVAudioPlayer` handles M4A natively.
- `Sources/dBrief/Services/MarkdownGenerator.swift` — frontmatter uses URL as given; extension carries through.
- `Sources/dBrief/Services/LocalTranscriptionService.swift` (Apple Speech) — already transcodes input to WAV via ffmpeg; accepts M4A.
- `Sources/dBrief/Services/WhisperKitTranscriptionService.swift` — loads via AVFoundation; handles M4A natively.
- `Sources/dBrief/Services/ParakeetTranscriptionService.swift` (FluidAudio) — to be verified in plan: if it only accepts WAV/FLAC, wrap with an ffmpeg WAV-transcode pre-step (Apple Speech pattern).
- `Sources/dBrief/Services/AudioChunker.swift` — operates on file paths, format-agnostic.
- `Sources/dBrief/Services/CallDetectionService.swift`, `GlobalHotkeyService.swift` — do not touch audio bytes.
- `Sources/dBrief/Audio/AudioInputDevice.swift` / `AudioInputDeviceManager` — still used for picking the mic device on the mic engine; unchanged.
- Old FLAC recordings on disk — still play, still transcribable, still exportable. Format change affects new recordings only.

### Tests

- `Tests/dBriefTests/AudioTrackWriterTests.swift` — new. Coverage: lazy-create, format-mismatch drop, peak level, `close()` idempotency.
- `Tests/dBriefTests/WhisperPipelineTests.swift` — update file-discovery expectations from `.flac` to `.m4a`.
- `Tests/dBriefTests/AppSettingsTests.swift` — add `acousticEchoCancellation` default / persistence tests; remove any remaining `audioSampleRate` / `audioBitRate` tests.

### Dependencies / tooling

- `Package.swift` — no changes.
- `ffmpeg` — role becomes more central; fallback path is less graceful (two CAFs vs one FLAC). Onboarding's ffmpeg check stays the same.

### Migration / rollback

- No data migration.
- Rollback: `git revert`. New code is isolated additions; deleted files restorable from history.

---

## Out of Scope

- Preserving raw mic and system tracks as user-accessible files after merge (simple future enhancement: add `AppSettings.keepRawTracks: Bool`, skip the delete step).
- Per-track transcription (mic = "You", system = "Others" for built-in speaker labels without diarization) — obvious follow-on once raw tracks are preserved.
- Making the ffmpeg filter chain user-configurable.
- Migrating old FLAC recordings to M4A.
- Changing SCStream's `stopCapture` final-frame drop behavior (still inherent to the SCKit API).
