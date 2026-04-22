# Audio Quality Fix — Design Spec

**Date:** 2026-04-21  
**Status:** Approved

## Summary

Fix three audio quality issues in mixed-mode recording: pitch shift (deeper voices), muddled/over-compressed output, and last-segment truncation. Root causes are (1) real-time 48→16 kHz downsampling in `AudioFileWriter`, (2) an over-aggressive ffmpeg DSP chain, and (3) player node buffers being cancelled before they drain at stop time.

AEC (`setVoiceProcessingEnabled`) is **kept as-is** — removing it would cause system audio to echo through the mic on open speakers.

---

## Section 1 — AudioFileWriter: Lazy Format Detection

**Files:** `Sources/dBrief/Audio/AudioFileWriter.swift`, `Sources/dBrief/Audio/AudioCaptureManager.swift`

**Problem:** `AudioFileWriter.init` currently accepts a `sampleRate` parameter and creates the `AVAudioFile` immediately at 16 kHz. Incoming buffers from the 48 kHz VoIP mic engine and 48 kHz SCStream are then downsampled 3:1 in real-time via `AVAudioConverter`. This conversion is the root cause of the pitch shift.

**Fix:** Remove `sampleRate` and `bitRate` from `AudioFileWriter.init`. Create the `AVAudioFile` lazily on the first `write()` call, using the incoming buffer's own format (sample rate, channel count). The FLAC file is declared at exactly the rate the mixer delivers. No real-time resampling occurs in normal operation. The existing `AVAudioConverter` path remains as a fallback for mid-stream format changes only.

`AudioCaptureManager` passes only `fileURL` to `AudioFileWriter` — `sampleRate` and `bitRate` arguments are dropped from `startRecording(to:sampleRate:bitRate:inputDeviceUID:)` as well (the `bitRate` parameter was already unused).

`actualFileURL` continues to work: returns `audioFile?.url ?? fileURL`, which handles the pre-first-write case correctly.

---

## Section 2 — AEC: No Change

AEC (`setVoiceProcessingEnabled(true)`) is left in place in both `startMixedMode` and `startMicOnlyMode`. The pitch fix is entirely in Section 1 — AEC's VoIP I/O unit runs at 48 kHz, and once `AudioFileWriter` captures at that native rate, no mismatch occurs. Removing AEC would risk system audio echoing through the mic on open speakers.

The AGC-induced volume reduction from AEC is compensated by the loudnorm target change in Section 3.

---

## Section 3 — ffmpeg DSP Chain

**File:** `Sources/dBrief/Services/RecordingFinalizer.swift`

**Current filter chain:**

```text
highpass=f=80,afftdn=nf=-25,loudnorm=I=-20:TP=-3:LRA=7
```

**Replacement filter chain:**

```text
highpass=f=80,loudnorm=I=-14:TP=-1:LRA=14
```

**Changes:**

- **Remove `afftdn=nf=-25`** — FFT denoiser strips high-frequency speech content (sibilance, consonants), causing muddled output. Whisper is robust to noise and does not require pre-denoised input.
- **`loudnorm=I=-14:TP=-1:LRA=14`** — `-14 LUFS` is standard broadcast speech level (was `-20`, which is unusually quiet). `-1 dBFS` true peak gives adequate headroom. `LRA=14` allows natural conversational dynamics (was `7`, which over-compressed speech).
- **Remove `-ar 16000`** — stop resampling to 16 kHz. Output stays at the capture rate (48 kHz from SCStream). WhisperKit resamples internally, remote Whisper endpoints accept any rate, Apple Speech receives a WAV conversion via ffmpeg regardless.
- **Remove `-ac 1`** — stop forcing mono. Output channel count matches the capture (typically stereo from the mixer).
- **Keep `highpass=f=80`** — harmless subsonic rolloff, no speech content below 80 Hz.

---

## Section 4 — Stop Sequence: Drain Before Close

**Files:** `Sources/dBrief/Audio/AudioMixer.swift`, `Sources/dBrief/Audio/AudioCaptureManager.swift`

**Problem:** `AudioMixer.stop()` calls `systemAudioPlayer.stop()` and `micPlayer.stop()` before `engine.stop()`. `AVAudioPlayerNode.stop()` immediately cancels all scheduled-but-not-yet-played buffers, discarding the last audio in the pipeline.

**Fix — AudioMixer.swift:** Remove the explicit `systemAudioPlayer.stop()` and `micPlayer.stop()` calls from `AudioMixer.stop()`. Call `engine.stop()` directly — the engine stops all attached nodes implicitly without cancelling their pending buffers mid-drain.

**Fix — AudioCaptureManager.swift:** In `stopRecording()`, after removing the mic tap and stopping the mic engine (which stops new audio arriving), insert a 300 ms `Task.sleep` before calling `mixer.stop()`. This allows queued buffers already in the engine's pipeline to drain to the file writer before shutdown. 300 ms comfortably covers AVAudioEngine's typical pipeline depth of 85–170 ms at 48 kHz.

```swift
// Stop all input sources (no new buffers after this point)
try? await systemCapture.stop()
micEngine.inputNode.removeTap(onBus: 0)
micEngine.stop()

// Drain: engine still running — let queued buffers play through to the file
try? await Task.sleep(nanoseconds: 300_000_000)

// Now safe to stop mixer and close file
mixer.stop()
fileWriter?.close()
```

Note: SCStream's final in-flight frame at `stopCapture()` may still be clipped — this is inherent to the SCKit API and not fixable without buffering the stream client-side.

---

## Out of Scope

- Making AEC optional via a Settings toggle (can be added later)
- Fixing SCStream's final-frame drop at stopCapture
- Adding configurable output sample rate or channel count
- Changing the `audioSampleRate` / `audioBitRate` AppSettings properties (now unused for capture; can be cleaned up separately)
