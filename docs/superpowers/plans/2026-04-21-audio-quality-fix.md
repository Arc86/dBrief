# Audio Quality Fix — Implementation Plan

**Date:** 2026-04-21  
**Spec:** `docs/superpowers/specs/2026-04-21-audio-quality-fix-design.md`  
**Status:** Ready

---

## Overview

Three independent changes, each targeting one root cause:

| Task | Root cause | Files touched |
|------|-----------|---------------|
| 1 | Pitch shift via real-time 48→16 kHz downsampling | `AudioFileWriter.swift`, `AudioCaptureManager.swift`, `RecordingManager.swift` |
| 2 | Muddled output from over-aggressive DSP chain | `RecordingFinalizer.swift` |
| 3 | Last-segment truncation from early player.stop() | `AudioMixer.swift`, `AudioCaptureManager.swift` |

---

## Task 1 — AudioFileWriter: Lazy Format Detection

### AudioFileWriter.swift

**Goal:** Remove `sampleRate`/`bitRate` from `init`. Create `AVAudioFile` lazily on first `write()` at the buffer's native format.

**Changes:**

1. Remove `processingFormat` stored property — no longer a fixed target format.
2. Change `init(fileURL:sampleRate:bitRate:)` to `init(fileURL:)` — only store `fileURL`. Do NOT create `AVAudioFile` in init.
3. Add a `pendingFileURL` helper that normalises the extension to `.flac` (the same logic currently in init).
4. In `write(_ buffer:)`:
   - If `audioFile == nil`, create it lazily using the incoming buffer's format (sample rate, channel count, channels are non-interleaved float32).
   - Settings: `AVFormatIDKey: kAudioFormatFLAC`, `AVSampleRateKey: buffer.format.sampleRate`, `AVNumberOfChannelsKey: buffer.format.channelCount`, `AVEncoderBitDepthHintKey: 16`.
   - Log the format on first creation.
5. Remove the `processingFormat` comparison / converter path from the write hot path. The `AVAudioConverter` path is only needed for mid-stream format changes — keep the converter as a fallback but only invoke it if the buffer's format doesn't match the open file's `processingFormat`.
6. `actualFileURL` stays as-is: `audioFile?.url ?? fileURL`.

**Exact new init signature:**
```swift
init(fileURL: URL) throws
```

(The `throws` is retained so callers don't need to change their `try` site, even though init no longer throws — keep the signature `throws` to be safe; alternatively make it non-throwing since no work is done.)

Actually — make `init` non-throwing (no file created, nothing can fail). Change call sites from `try AudioFileWriter(...)` to `AudioFileWriter(...)`. The lazy `AVAudioFile` creation in `write()` can throw; catch it there and log/skip.

### AudioCaptureManager.swift

1. Change `startRecording(to:sampleRate:bitRate:inputDeviceUID:)` → `startRecording(to:inputDeviceUID:)` (drop `sampleRate` and `bitRate` params).
2. Change `AudioFileWriter(fileURL: fileURL, sampleRate: sampleRate, bitRate: bitRate)` → `AudioFileWriter(fileURL: fileURL)`. Remove `try` if init becomes non-throwing.

### RecordingManager.swift

1. Remove `sampleRate: 16_000, bitRate: 128_000` from the `audioCaptureManager.startRecording(...)` call at lines 87-88.

---

## Task 2 — ffmpeg DSP Chain

### RecordingFinalizer.swift (`transcodeWithFFmpeg`)

Remove lines 104-105 (`"-ar", "16000"` and `"-ac", "1"`).  
Replace line 108 filter string.

**Before (lines 101-113):**
```swift
arguments: [
    "-y",
    "-i", inputURL.path,
    "-ar", "16000",
    "-ac", "1",
    "-c:a", "flac",
    "-compression_level", "8",
    "-af", "highpass=f=80,afftdn=nf=-25,loudnorm=I=-20:TP=-3:LRA=7",
    ...
]
```

**After:**
```swift
arguments: [
    "-y",
    "-i", inputURL.path,
    "-c:a", "flac",
    "-compression_level", "8",
    "-af", "highpass=f=80,loudnorm=I=-14:TP=-1:LRA=14",
    ...
]
```

No other changes in this file.

---

## Task 3 — Stop Sequence: Drain Before Close

### AudioMixer.swift (`stop()`)

Remove `systemAudioPlayer.stop()` and `micPlayer.stop()` calls. Call `engine.stop()` directly.

**Before:**
```swift
func stop() {
    if hasSystemAudio {
        systemAudioPlayer.stop()
    }
    micPlayer.stop()
    engine.stop()
    captureMixer.removeTap(onBus: 0)
    lock.withLock {
        isSetUp = false
        hasSystemAudio = false
    }
}
```

**After:**
```swift
func stop() {
    engine.stop()
    captureMixer.removeTap(onBus: 0)
    lock.withLock {
        isSetUp = false
        hasSystemAudio = false
    }
}
```

### AudioCaptureManager.swift (`stopRecording()`)

Insert `try? await Task.sleep(nanoseconds: 300_000_000)` after stopping input sources and before `mixer.stop()`.

**Current order (lines 96-121):**
```swift
if let systemCapture { try? await systemCapture.stop(); ... }
if let micEngine { micEngine.inputNode.removeTap...; micEngine.stop(); ... }
if let mixer { mixer.stop(); ... }
if let micOnlyEngine { micOnlyEngine.inputNode.removeTap...; micOnlyEngine.stop(); ... }
fileWriter?.close()
```

**New order:**
```swift
// 1. Stop all input sources
if let systemCapture { try? await systemCapture.stop(); self.systemCapture = nil }
if let micEngine { micEngine.inputNode.removeTap(onBus: 0); micEngine.stop(); self.micEngine = nil }
if let micOnlyEngine { micOnlyEngine.inputNode.removeTap(onBus: 0); micOnlyEngine.stop(); self.micOnlyEngine = nil }

// 2. Drain: let queued buffers play through to the file writer
if mixer != nil { try? await Task.sleep(nanoseconds: 300_000_000) }

// 3. Stop mixer and close file
if let mixer { mixer.stop(); self.mixer = nil }
fileWriter?.close()
fileWriter = nil
```

The 300 ms sleep only runs when in mixed mode (mixer != nil). Mic-only mode has no player nodes and needs no drain.

---

## Tests

Add `Tests/dBriefTests/AudioFileWriterTests.swift` using swift-testing:

```swift
import Testing
@testable import dBrief
import AVFoundation

@Suite("AudioFileWriter")
struct AudioFileWriterTests {
    @Test("init does not create file before first write")
    func initDoesNotCreateFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("flac")
        let writer = AudioFileWriter(fileURL: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        _ = writer  // silence unused warning
    }

    @Test("write creates file at buffer's sample rate")
    func writeLazily() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("flac")
        let writer = AudioFileWriter(fileURL: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        buffer.frameLength = 512
        try writer.write(buffer)
        #expect(FileManager.default.fileExists(atPath: writer.actualFileURL.path))
        try? FileManager.default.removeItem(at: writer.actualFileURL)
    }
}
```

---

## Execution Order

Tasks 1, 2, 3 are independent — execute in parallel via three subagents.

After all three complete: `swift build` to confirm no compile errors, then commit.
