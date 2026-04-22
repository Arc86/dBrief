# Audio Pipeline Rewrite — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fragile single-engine dual-player-node mixer with two independent capture paths (system → `system.caf`, mic → `mic.caf`), merged to M4A at finalize time via ffmpeg `amix`.

**Architecture:** Two pipelines that never touch at the audio level. `AudioTrackWriter` writes each source to its own CAF/LPCM file. `RecordingFinalizer` runs one ffmpeg pass that highpass-filters, loudnorm's the mic, sums with `amix normalize=0`, encodes to AAC 96 kbps stereo, and deletes the scratch CAFs. Preserves `setVoiceProcessingEnabled(true)` AEC on the mic to eliminate laptop-speaker reverb.

**Tech Stack:** Swift 6.2, AVFoundation (AVAudioEngine, AVAudioFile, CAF/LPCM), ScreenCaptureKit, shelled-out ffmpeg, swift-testing.

**Spec:** `docs/superpowers/specs/2026-04-22-audio-pipeline-rewrite-design.md`

---

## File Structure

### Create

| File | Responsibility |
|------|----------------|
| `Sources/dBrief/Audio/AudioTrackWriter.swift` | Writer for a single track. Owns one `AVAudioFile`. Lazy-creates at the incoming buffer's format. Tracks peak level. Defines the shared `CapturedTracks` struct. |
| `Tests/dBriefTests/AudioTrackWriterTests.swift` | Unit tests for `AudioTrackWriter`. |

### Rewrite (same path, replaced contents)

| File | New responsibility |
|------|--------------------|
| `Sources/dBrief/Audio/AudioCaptureManager.swift` | Owns two independent pipelines (system + mic). Public API preserved except `actualFileURL` → `trackURLs: CapturedTracks?`. |
| `Sources/dBrief/Services/RecordingFinalizer.swift` | `finalize(tracks:recording:baseFolder:segmentationEnabled:)`. Merges CAFs via ffmpeg `amix` → M4A master. |

### Modify

| File | Changes |
|------|---------|
| `Sources/dBrief/App/AppSettings.swift` | Remove `audioSampleRate`, `audioBitRate` (property + Keys + init default). Add `acousticEchoCancellation: Bool` (default true). |
| `Sources/dBrief/UI/SettingsRecordingTab.swift` | Add AEC toggle. Update "Audio Quality" copy from FLAC → M4A. |
| `Sources/dBrief/Services/RecordingManager.swift` | New `generateRawCaptureBaseURL()` helper. Pass `CapturedTracks` to finalizer. Queue discovery handles both `.m4a` (new) and `.flac` (legacy). |
| `Sources/dBrief/UI/PostRecordingSheet.swift` | Update UI copy from `.flac` → `.m4a`. |
| `Tests/dBriefTests/WhisperPipelineTests.swift` | Update expectations from `.flac` → `.m4a`. |
| `Tests/dBriefTests/AppSettingsTests.swift` | Add `acousticEchoCancellation` default test. |

### Delete

| File | Reason |
|------|--------|
| `Sources/dBrief/Audio/AudioMixer.swift` | Real-time mixer removed entirely. |
| `Sources/dBrief/Audio/AudioFileWriter.swift` | Replaced by `AudioTrackWriter`. |
| `Sources/dBrief/Audio/MicrophoneCapture.swift` | Dead code — `AudioCaptureManager` already owns the mic engine directly. |
| `Tests/dBriefTests/AudioFileWriterTests.swift` | Obsolete — replaced by `AudioTrackWriterTests`. |

---

## Task 1 — `AudioTrackWriter` with tests

**Files:**
- Create: `Sources/dBrief/Audio/AudioTrackWriter.swift`
- Create: `Tests/dBriefTests/AudioTrackWriterTests.swift`

- [ ] **Step 1.1: Write the failing tests**

Create `Tests/dBriefTests/AudioTrackWriterTests.swift`:

```swift
import Testing
@testable import dBrief
import AVFoundation

@Suite("AudioTrackWriter")
struct AudioTrackWriterTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")
    }

    private func makeBuffer(sampleRate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        return buf
    }

    @Test("init does not create file before first write")
    func initDoesNotCreateFile() {
        let url = tempURL()
        let writer = AudioTrackWriter(url: url, role: .mic)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        _ = writer
    }

    @Test("first write creates file at the buffer's sample rate")
    func firstWriteCreatesFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AudioTrackWriter(url: url, role: .mic)
        try writer.write(makeBuffer(sampleRate: 48000, channels: 1, frames: 512))
        writer.close()
        #expect(FileManager.default.fileExists(atPath: url.path))
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 48000)
        #expect(file.fileFormat.channelCount == 1)
    }

    @Test("format mismatch on later buffer is dropped, file stays intact")
    func formatMismatchDropped() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AudioTrackWriter(url: url, role: .system)
        try writer.write(makeBuffer(sampleRate: 48000, channels: 2, frames: 512))
        // Second buffer at wrong sample rate should be dropped, not crash.
        try writer.write(makeBuffer(sampleRate: 44100, channels: 2, frames: 512))
        writer.close()
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 48000)
        // Only the first buffer's frames are in the file.
        #expect(file.length == 512)
    }

    @Test("close is idempotent")
    func closeIdempotent() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AudioTrackWriter(url: url, role: .mic)
        try writer.write(makeBuffer(sampleRate: 48000, channels: 1, frames: 256))
        writer.close()
        writer.close()  // must not crash
    }

    @Test("peakLevel reflects the last buffer")
    func peakLevelUpdates() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AudioTrackWriter(url: url, role: .mic)
        let buf = makeBuffer(sampleRate: 48000, channels: 1, frames: 256)
        buf.floatChannelData![0][100] = 0.5
        try writer.write(buf)
        #expect(writer.peakLevel == 0.5)
        writer.close()
    }
}
```

- [ ] **Step 1.2: Run tests to verify they fail**

```bash
swift test --filter AudioTrackWriterTests
```

Expected: compile error (`AudioTrackWriter` not defined) or "no tests passed."

- [ ] **Step 1.3: Write `AudioTrackWriter.swift`**

Create `Sources/dBrief/Audio/AudioTrackWriter.swift`:

```swift
@preconcurrency import AVFoundation
import os

private let log = Logger.audio

/// A single captured track on disk. Both URLs may be nil if the corresponding
/// source was not captured (no screen-recording permission → system=nil; no
/// mic permission → mic=nil). At least one is guaranteed non-nil by
/// `AudioCaptureManager` before `startRecording` returns.
struct CapturedTracks: Sendable {
    var systemURL: URL?
    var micURL: URL?
}

/// Writes `AVAudioPCMBuffer`s to a CAF/LPCM Int16 file. One instance per track.
///
/// - No real-time resampling: the file format is inherited from the first
///   buffer and later format-mismatched buffers are dropped rather than
///   converted.
/// - No mixing, no player nodes: this class is a passive sink.
/// - `close()` is idempotent — CAF has no trailing header to finalize.
final class AudioTrackWriter: @unchecked Sendable {
    enum Role: String, Sendable { case system, mic }

    let url: URL
    let role: Role

    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var _peakLevel: Float = 0
    private var droppedCount = 0

    init(url: URL, role: Role) {
        self.url = url
        self.role = role
    }

    var peakLevel: Float {
        lock.withLock { _peakLevel }
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        lock.lock()
        defer { lock.unlock() }

        if audioFile == nil {
            let format = buffer.format
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: Int(format.channelCount),
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: !format.isInterleaved,
            ]
            do {
                audioFile = try AVAudioFile(
                    forWriting: url,
                    settings: settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
                log.info("[AudioTrackWriter:\(self.role.rawValue, privacy: .public)] opened \(self.url.lastPathComponent, privacy: .public) @ \(format.sampleRate, privacy: .public)Hz \(format.channelCount, privacy: .public)ch")
            } catch {
                log.error("[AudioTrackWriter:\(self.role.rawValue, privacy: .public)] failed to open: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }

        guard let audioFile else { return }

        if buffer.format.sampleRate != audioFile.processingFormat.sampleRate
            || buffer.format.channelCount != audioFile.processingFormat.channelCount
        {
            droppedCount += 1
            if droppedCount == 1 {
                log.error("[AudioTrackWriter:\(self.role.rawValue, privacy: .public)] format mismatch — dropping buffer. Got \(buffer.format.sampleRate, privacy: .public)Hz \(buffer.format.channelCount, privacy: .public)ch, file is \(audioFile.processingFormat.sampleRate, privacy: .public)Hz \(audioFile.processingFormat.channelCount, privacy: .public)ch")
            }
            return
        }

        _peakLevel = Self.peakLevel(of: buffer)
        try audioFile.write(from: buffer)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        audioFile = nil
    }

    private static func peakLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        var peak: Float = 0
        for i in 0..<frames {
            let sample = abs(channelData[0][i])
            if sample > peak { peak = sample }
        }
        return peak
    }
}
```

- [ ] **Step 1.4: Run tests to verify they pass**

```bash
swift test --filter AudioTrackWriterTests
```

Expected: all five tests PASS.

- [ ] **Step 1.5: Commit**

```bash
git add Sources/dBrief/Audio/AudioTrackWriter.swift Tests/dBriefTests/AudioTrackWriterTests.swift
git commit -m "feat(audio): add AudioTrackWriter for isolated per-track CAF capture"
```

---

## Task 2 — AppSettings: remove unused audio rate fields, add AEC toggle

**Files:**
- Modify: `Sources/dBrief/App/AppSettings.swift`
- Modify: `Tests/dBriefTests/AppSettingsTests.swift`

- [ ] **Step 2.1: Write the failing test**

Add to `Tests/dBriefTests/AppSettingsTests.swift` inside the existing `struct AppSettingsTests`:

```swift
    @Test func acousticEchoCancellationDefaultsToTrue() {
        UserDefaults.standard.removeObject(forKey: "acousticEchoCancellation")
        let settings = AppSettings()
        #expect(settings.acousticEchoCancellation == true)
    }

    @Test func acousticEchoCancellationPersists() {
        UserDefaults.standard.removeObject(forKey: "acousticEchoCancellation")
        let settings = AppSettings()
        settings.acousticEchoCancellation = false
        #expect(UserDefaults.standard.bool(forKey: "acousticEchoCancellation") == false)
        let reloaded = AppSettings()
        #expect(reloaded.acousticEchoCancellation == false)
        // Reset so other tests are deterministic.
        UserDefaults.standard.removeObject(forKey: "acousticEchoCancellation")
    }
```

- [ ] **Step 2.2: Run tests to verify they fail**

```bash
swift test --filter AppSettingsTests
```

Expected: compile error — `acousticEchoCancellation` does not exist on `AppSettings`.

- [ ] **Step 2.3: Remove `audioSampleRate` / `audioBitRate` from `AppSettings.swift`**

Edit `Sources/dBrief/App/AppSettings.swift`:

1. Delete the two `Keys` constants (currently lines 29–30):
```swift
        static let audioSampleRate = "audioSampleRate"
        static let audioBitRate = "audioBitRate"
```

2. Delete the two properties (currently lines 226–233):
```swift
    var audioSampleRate: Int {
        didSet { UserDefaults.standard.set(audioSampleRate, forKey: Keys.audioSampleRate) }
    }

    var audioBitRate: Int {
        didSet { UserDefaults.standard.set(audioBitRate, forKey: Keys.audioBitRate) }
    }
```

3. Delete the two `init` loads (currently lines 556–557):
```swift
        self.audioSampleRate = defaults.object(forKey: Keys.audioSampleRate) as? Int ?? 16000
        self.audioBitRate = defaults.object(forKey: Keys.audioBitRate) as? Int ?? 128000
```

- [ ] **Step 2.4: Add `acousticEchoCancellation` to `AppSettings.swift`**

Add a new Key inside the `Keys` enum, near `diarizationEnabled`:
```swift
        static let acousticEchoCancellation = "acousticEchoCancellation"
```

Add the property near `diarizationEnabled` (around line 280):
```swift
    var acousticEchoCancellation: Bool {
        didSet { UserDefaults.standard.set(acousticEchoCancellation, forKey: Keys.acousticEchoCancellation) }
    }
```

Add the `init` load near the existing `diarizationEnabled` load:
```swift
        self.acousticEchoCancellation = defaults.object(forKey: Keys.acousticEchoCancellation) as? Bool ?? true
```

- [ ] **Step 2.5: Confirm nothing else references the removed fields**

```bash
grep -rn "audioSampleRate\|audioBitRate" Sources/ Tests/
```

Expected: no results.

- [ ] **Step 2.6: Run tests**

```bash
swift test --filter AppSettingsTests
```

Expected: all three tests PASS (existing + two new).

- [ ] **Step 2.7: Commit**

```bash
git add Sources/dBrief/App/AppSettings.swift Tests/dBriefTests/AppSettingsTests.swift
git commit -m "feat(settings): add acousticEchoCancellation toggle, remove unused audio rate fields"
```

---

## Task 3 — Rewrite `AudioCaptureManager`

**Files:**
- Modify: `Sources/dBrief/Audio/AudioCaptureManager.swift`

This task does not delete `AudioMixer.swift` / `AudioFileWriter.swift` / `MicrophoneCapture.swift` yet — those stay to satisfy the compiler between tasks. Task 4 deletes them.

- [ ] **Step 3.1: Replace `AudioCaptureManager.swift` contents wholesale**

Overwrite `Sources/dBrief/Audio/AudioCaptureManager.swift` with:

```swift
@preconcurrency import AVFoundation
import CoreGraphics
@preconcurrency import ScreenCaptureKit
import os

private let log = Logger.audio

@MainActor
@Observable
final class AudioCaptureManager {
    private(set) var isCapturing = false
    private(set) var duration: TimeInterval = 0
    private(set) var peakLevel: Float = 0

    private var systemCapture: SystemAudioCapture?
    private var micEngine: AVAudioEngine?
    private var systemWriter: AudioTrackWriter?
    private var micWriter: AudioTrackWriter?
    private var baseURL: URL?

    private var timer: Timer?
    private var startTime: Date?
    private var pauseAccumulator: TimeInterval = 0
    private var pauseStartTime: Date?
    private var acousticEchoCancellationEnabled = true

    private(set) var hasSystemAudioPermission = false
    private(set) var hasMicrophonePermission = false

    /// URLs of the two track files written during the last recording.
    /// Stable across `stopRecording` — cleared only by the next `startRecording`.
    private(set) var trackURLs: CapturedTracks?

    func checkPermissions() async {
        hasMicrophonePermission = await Self.requestMicAccess()
        hasSystemAudioPermission = CGPreflightScreenCaptureAccess()
        if !hasSystemAudioPermission {
            log.warning("Screen recording permission not granted")
        }
    }

    /// Starts recording. `baseURL` is the file path stem WITHOUT extension —
    /// the manager appends `_system.caf` and `_mic.caf` internally.
    func startRecording(
        to baseURL: URL,
        inputDeviceUID: String? = nil,
        acousticEchoCancellationEnabled: Bool = true
    ) async throws {
        guard !isCapturing else { return }

        if !hasMicrophonePermission {
            hasMicrophonePermission = await Self.requestMicAccess()
        }
        hasSystemAudioPermission = CGPreflightScreenCaptureAccess()

        guard hasMicrophonePermission || hasSystemAudioPermission else {
            throw AudioCaptureError.noMicrophoneAccess
        }

        let stem = baseURL.deletingPathExtension()
        let systemURL = stem.appendingPathExtension("system.caf")
        let micURL = stem.appendingPathExtension("mic.caf")

        self.baseURL = stem
        self.acousticEchoCancellationEnabled = acousticEchoCancellationEnabled
        self.trackURLs = CapturedTracks(
            systemURL: hasSystemAudioPermission ? systemURL : nil,
            micURL: hasMicrophonePermission ? micURL : nil
        )

        log.info("Starting recording — system=\(self.hasSystemAudioPermission, privacy: .public) mic=\(self.hasMicrophonePermission, privacy: .public)")

        if hasSystemAudioPermission {
            try await startSystemPipeline(writer: AudioTrackWriter(url: systemURL, role: .system))
        }
        if hasMicrophonePermission {
            try startMicPipeline(
                writer: AudioTrackWriter(url: micURL, role: .mic),
                inputDeviceUID: inputDeviceUID
            )
        }

        isCapturing = true
        startTime = Date()
        pauseAccumulator = 0
        startTimer()
        log.info("Recording started")
    }

    func stopRecording() async {
        guard isCapturing else { return }
        stopTimer()

        if let systemCapture {
            try? await systemCapture.stop()
            self.systemCapture = nil
        }
        if let micEngine {
            micEngine.inputNode.removeTap(onBus: 0)
            micEngine.stop()
            self.micEngine = nil
        }

        systemWriter?.close(); systemWriter = nil
        micWriter?.close(); micWriter = nil

        isCapturing = false
        peakLevel = 0
        log.info("Recording stopped")
    }

    func pauseRecording() {
        guard isCapturing else { return }
        micEngine?.pause()
        Task { [systemCapture] in try? await systemCapture?.stop() }
        self.systemCapture = nil
        pauseStartTime = Date()
        stopTimer()
    }

    func resumeRecording() throws {
        guard isCapturing else { return }
        if let pauseStart = pauseStartTime {
            pauseAccumulator += Date().timeIntervalSince(pauseStart)
            pauseStartTime = nil
        }
        if let micEngine {
            try micEngine.start()
        }
        if hasSystemAudioPermission, let systemWriter {
            Task {
                do {
                    try await restartSystemCapture(writer: systemWriter)
                } catch {
                    log.error("Failed to resume system capture: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        startTimer()
    }

    // MARK: - System pipeline

    private func startSystemPipeline(writer: AudioTrackWriter) async throws {
        self.systemWriter = writer
        try await restartSystemCapture(writer: writer)
    }

    private func restartSystemCapture(writer: AudioTrackWriter) async throws {
        let filter = try await SystemAudioCapture.createContentFilter()
        let capture = try SystemAudioCapture(filter: filter)
        capture.audioBufferHandler = Self.makeSystemHandler(writer: writer)
        self.systemCapture = capture
        try await capture.start()
        log.info("System capture started")
    }

    private nonisolated static func makeSystemHandler(
        writer: AudioTrackWriter
    ) -> @Sendable (CMSampleBuffer) -> Void {
        return { sampleBuffer in
            guard let pcm = sampleBuffer.toPCMBuffer() else { return }
            do {
                try writer.write(pcm)
            } catch {
                log.error("System write error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Mic pipeline

    private func startMicPipeline(writer: AudioTrackWriter, inputDeviceUID: String?) throws {
        let engine = AVAudioEngine()
        self.micEngine = engine
        self.micWriter = writer

        do {
            try AudioInputDeviceManager.applyInputDevice(uid: inputDeviceUID, to: engine)
        } catch {
            log.warning("Failed to set mic input device: \(error.localizedDescription, privacy: .public)")
        }

        let inputNode = engine.inputNode
        if acousticEchoCancellationEnabled {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                log.info("AEC enabled on mic input")
            } catch {
                log.warning("AEC unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw AudioCaptureError.noMicrophoneAccess
        }
        log.info("Mic format: \(inputFormat.sampleRate, privacy: .public)Hz \(inputFormat.channelCount, privacy: .public)ch")

        let handler = Self.makeMicHandler(writer: writer)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: handler)

        try engine.start()
        log.info("Mic capture started")
    }

    private nonisolated static func makeMicHandler(
        writer: AudioTrackWriter
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        return { buffer, _ in
            do {
                try writer.write(buffer)
            } catch {
                log.error("Mic write error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Helpers

    private static func requestMicAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startTime = self.startTime else { return }
                self.duration = Date().timeIntervalSince(startTime) - self.pauseAccumulator
                // Prefer mic peak for the level meter, fall back to system.
                self.peakLevel = self.micWriter?.peakLevel ?? self.systemWriter?.peakLevel ?? 0
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
```

- [ ] **Step 3.2: Verify the code compiles (linker will still see AudioMixer/AudioFileWriter; that's fine)**

```bash
swift build 2>&1 | tail -40
```

Expected: **compile errors** in `RecordingManager.swift` referencing `audioCaptureManager.actualFileURL` and the old `startRecording(to:inputDeviceUID:)` signature mismatch. That's fine — the next task addresses it. If there are errors *inside* `AudioCaptureManager.swift` itself, stop and fix them first.

Verification command — check that errors are only in RecordingManager:

```bash
swift build 2>&1 | grep -E "error:" | grep -v "RecordingManager.swift" | head
```

Expected: empty (no errors outside `RecordingManager.swift`).

- [ ] **Step 3.3: Commit (deferred)** — do NOT commit yet; the build is red. Commit at the end of Task 5 once it's green.

---

## Task 4 — Delete obsolete audio files

**Files:**
- Delete: `Sources/dBrief/Audio/AudioMixer.swift`
- Delete: `Sources/dBrief/Audio/AudioFileWriter.swift`
- Delete: `Sources/dBrief/Audio/MicrophoneCapture.swift`
- Delete: `Tests/dBriefTests/AudioFileWriterTests.swift`

- [ ] **Step 4.1: Remove the four files**

```bash
git rm Sources/dBrief/Audio/AudioMixer.swift \
       Sources/dBrief/Audio/AudioFileWriter.swift \
       Sources/dBrief/Audio/MicrophoneCapture.swift \
       Tests/dBriefTests/AudioFileWriterTests.swift
```

- [ ] **Step 4.2: Confirm no remaining references**

```bash
grep -rn "AudioMixer\|AudioFileWriter\|MicrophoneCapture" Sources/ Tests/
```

Expected: empty. If `MicrophoneCapture.requestAccess` is referenced somewhere — the rewritten `AudioCaptureManager` uses its own `Self.requestMicAccess()` now, so no external references should remain. If any do, stop and investigate.

- [ ] **Step 4.3: Confirm compile errors are still only in `RecordingManager.swift`**

```bash
swift build 2>&1 | grep -E "error:" | grep -v "RecordingManager.swift" | head
```

Expected: empty.

---

## Task 5 — Rewrite `RecordingFinalizer`

**Files:**
- Modify: `Sources/dBrief/Services/RecordingFinalizer.swift`

- [ ] **Step 5.1: Replace the `finalize` signature and body**

In `Sources/dBrief/Services/RecordingFinalizer.swift`, replace the existing `finalize(...)` method (currently lines 13–91) with:

```swift
    func finalize(
        tracks: CapturedTracks,
        recording: Recording,
        baseFolder: URL,
        segmentationEnabled: Bool = true
    ) async throws -> RecordingFinalizationResult {
        let snapshot = await MainActor.run { Snapshot(recording: recording) }
        let normalizedTitle = Self.normalizeMeetingTitle(snapshot.meetingTitle, fallback: snapshot.associatedApp)
        let targetFolder = try Self.datedFolder(baseFolder: baseFolder, date: snapshot.date, fileManager: fileManager)
        let baseName = Self.baseFileName(date: snapshot.date, title: normalizedTitle)
        let masterURL = try Self.uniqueFileURL(
            folder: targetFolder,
            baseName: baseName,
            fileExtension: "m4a",
            fileManager: fileManager
        )

        var warnings: [String] = []
        let ffmpegPath = resolveFFmpegPath()

        if let ffmpegPath {
            do {
                try transcodeWithFFmpeg(
                    ffmpegPath: ffmpegPath,
                    tracks: tracks,
                    outputURL: masterURL,
                    snapshot: snapshot
                )
                // Cleanup raw tracks after successful merge.
                if let url = tracks.systemURL, fileManager.fileExists(atPath: url.path) {
                    try? fileManager.removeItem(at: url)
                }
                if let url = tracks.micURL, fileManager.fileExists(atPath: url.path) {
                    try? fileManager.removeItem(at: url)
                }
            } catch {
                warnings.append("ffmpeg merge failed; keeping raw CAF(s). \(error.localizedDescription)")
                try fallbackPromoteTrack(tracks: tracks, targetURL: masterURL)
            }
        } else {
            warnings.append("ffmpeg not found. Skipped merge and AAC encode; master is raw CAF.")
            try fallbackPromoteTrack(tracks: tracks, targetURL: masterURL)
        }

        var segmentURLs: [URL] = []
        if segmentationEnabled && snapshot.duration > 1800 {
            if let ffmpegPath, fileManager.fileExists(atPath: masterURL.path) {
                do {
                    segmentURLs = try createSegments(ffmpegPath: ffmpegPath, masterURL: masterURL)
                    if segmentURLs.isEmpty {
                        warnings.append("Segmentation produced no output files.")
                    }
                } catch {
                    warnings.append("Segmentation failed. \(error.localizedDescription)")
                }
            } else {
                warnings.append("Segmentation skipped because ffmpeg is unavailable.")
            }
        }

        let metadataPayload = RecordingMetadataPayload(
            dateISO8601: ISO8601DateFormatter().string(from: snapshot.date),
            durationSeconds: snapshot.duration,
            meetingTitle: normalizedTitle,
            masterFileName: masterURL.lastPathComponent,
            segmentFileNames: segmentURLs.map(\.lastPathComponent),
            warnings: warnings
        )
        let metadataURL = masterURL.deletingPathExtension().appendingPathExtension("json")
        try writeMetadata(metadataPayload, to: metadataURL)

        return RecordingFinalizationResult(
            masterAudioURL: masterURL,
            segmentAudioURLs: segmentURLs,
            metadataURL: metadataURL,
            warnings: warnings
        )
    }
```

- [ ] **Step 5.2: Rewrite `transcodeWithFFmpeg`**

Replace the existing `transcodeWithFFmpeg(...)` (currently lines 93–117) with:

```swift
    private func transcodeWithFFmpeg(
        ffmpegPath: String,
        tracks: CapturedTracks,
        outputURL: URL,
        snapshot: Snapshot
    ) throws {
        let isoDate = ISO8601DateFormatter().string(from: snapshot.date)
        let title = Self.normalizeMeetingTitle(snapshot.meetingTitle, fallback: snapshot.associatedApp)
        let durationArg = "duration_seconds=\(Int(snapshot.duration))"

        let args: [String]
        switch (tracks.systemURL, tracks.micURL) {
        case (let system?, let mic?):
            args = [
                "-y",
                "-i", system.path,
                "-i", mic.path,
                "-filter_complex",
                "[0:a]highpass=f=40,lowpass=f=12000[sys];"
                + "[1:a]highpass=f=80,loudnorm=I=-16:TP=-1.5:LRA=11[mic];"
                + "[sys][mic]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0[out]",
                "-map", "[out]",
                "-c:a", "aac",
                "-b:a", "96k",
                "-ar", "48000",
                "-ac", "2",
                "-movflags", "+faststart",
                "-metadata", "date=\(isoDate)",
                "-metadata", "title=\(title)",
                "-metadata", durationArg,
                outputURL.path,
            ]
        case (nil, let mic?):
            args = [
                "-y",
                "-i", mic.path,
                "-af", "highpass=f=80,loudnorm=I=-16:TP=-1.5:LRA=11",
                "-c:a", "aac",
                "-b:a", "64k",
                "-ar", "48000",
                "-ac", "1",
                "-movflags", "+faststart",
                "-metadata", "date=\(isoDate)",
                "-metadata", "title=\(title)",
                "-metadata", durationArg,
                outputURL.path,
            ]
        case (let system?, nil):
            args = [
                "-y",
                "-i", system.path,
                "-af", "highpass=f=40,lowpass=f=12000",
                "-c:a", "aac",
                "-b:a", "96k",
                "-ar", "48000",
                "-ac", "2",
                "-movflags", "+faststart",
                "-metadata", "date=\(isoDate)",
                "-metadata", "title=\(title)",
                "-metadata", durationArg,
                outputURL.path,
            ]
        case (nil, nil):
            throw RecordingFinalizerError.ffmpegFailed("No input tracks to finalize.")
        }

        let processResult = runFFmpeg(ffmpegPath: ffmpegPath, arguments: args)
        guard processResult.status == 0 else {
            throw RecordingFinalizerError.ffmpegFailed(processResult.stderr)
        }
    }
```

- [ ] **Step 5.3: Update segment pattern extension to `.m4a`**

In `createSegments(...)` (currently around line 119), change:
```swift
        let pattern = folder.appendingPathComponent("\(stem)_part%02d.flac")
```
to:
```swift
        let pattern = folder.appendingPathComponent("\(stem)_part%02d.m4a")
```

And in the file-filter block below, change:
```swift
                $0.pathExtension.lowercased() == "flac"
```
to:
```swift
                $0.pathExtension.lowercased() == "m4a"
```

- [ ] **Step 5.4: Replace `fallbackMoveRawFile` with `fallbackPromoteTrack`**

Replace the existing `fallbackMoveRawFile(...)` (currently around line 156) with:

```swift
    private func fallbackPromoteTrack(tracks: CapturedTracks, targetURL: URL) throws {
        let source: URL
        if let mic = tracks.micURL, fileManager.fileExists(atPath: mic.path) {
            source = mic
        } else if let system = tracks.systemURL, fileManager.fileExists(atPath: system.path) {
            source = system
        } else {
            throw RecordingFinalizerError.ffmpegFailed("No usable track for fallback.")
        }

        // Target keeps the planned `.m4a` extension name but carries CAF contents.
        // Downstream consumers open via AVFoundation which sniffs contents.
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        do {
            try fileManager.moveItem(at: source, to: targetURL)
        } catch {
            try fileManager.copyItem(at: source, to: targetURL)
        }
    }
```

- [ ] **Step 5.5: Verify compile**

```bash
swift build 2>&1 | grep -E "error:" | grep -v "RecordingManager.swift" | head
```

Expected: empty.

---

## Task 6 — Update `RecordingManager`

**Files:**
- Modify: `Sources/dBrief/Services/RecordingManager.swift`

- [ ] **Step 6.1: Replace `generateRawCaptureURL` with a base-URL helper**

In `RecordingManager.swift`, replace the existing helper (currently around line 1359):

```swift
    private static func generateRawCaptureURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dbrief-raw-\(UUID().uuidString).flac")
    }
```

with:

```swift
    private static func generateRawCaptureBaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dbrief-raw-\(UUID().uuidString)")
    }
```

- [ ] **Step 6.2: Update `startRecording` to use the base URL and pass AEC setting**

Replace the existing body (currently lines 75–93):

```swift
    func startRecording(associatedApp: String? = nil) async throws {
        let rawURL = Self.generateRawCaptureURL()

        let recording = Recording(
            fileURL: rawURL,
            associatedApp: associatedApp,
            meetingTitleDraft: defaultMeetingTitle(from: associatedApp)
        )
        appState.currentRecording = recording

        try await audioCaptureManager.startRecording(
            to: rawURL,
            inputDeviceUID: appSettings.audioInputDeviceUID
        )
        appState.recordingState = .recording
        miniPlayer?.show()

        observeAudioState()
    }
```

with:

```swift
    func startRecording(associatedApp: String? = nil) async throws {
        let baseURL = Self.generateRawCaptureBaseURL()

        let recording = Recording(
            fileURL: baseURL,  // placeholder — replaced with master URL in ensureRecordingFinalized
            associatedApp: associatedApp,
            meetingTitleDraft: defaultMeetingTitle(from: associatedApp)
        )
        appState.currentRecording = recording

        try await audioCaptureManager.startRecording(
            to: baseURL,
            inputDeviceUID: appSettings.audioInputDeviceUID,
            acousticEchoCancellationEnabled: appSettings.acousticEchoCancellation
        )
        appState.recordingState = .recording
        miniPlayer?.show()

        observeAudioState()
    }
```

- [ ] **Step 6.3: Update `stopRecording` to capture `trackURLs` (not `actualFileURL`)**

Replace the existing body (currently lines 95–123) with:

```swift
    func stopRecording() async {
        await audioCaptureManager.stopRecording()

        if let recording = appState.currentRecording {
            recording.capturedTracks = audioCaptureManager.trackURLs
            recording.duration = audioCaptureManager.duration
            recording.finalizedAudioURL = nil
            recording.segmentAudioURLs = []
            recording.metadataURL = nil
            recording.finalizationWarnings = []
            if recording.meetingTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recording.meetingTitleDraft = defaultMeetingTitle(from: recording.associatedApp)
            }
        }

        appState.recordingState = .idle
        appState.showPostRecordingSheet = true
        miniPlayer?.dismiss()
    }
```

The `Recording` model needs a new field — added in Step 6.4.

- [ ] **Step 6.4: Add `capturedTracks` to the `Recording` model**

Find `Sources/dBrief/Models/Recording.swift` (confirm the path with `grep -rn "final class Recording\|class Recording" Sources/dBrief/Models/` if unsure) and add:

```swift
    var capturedTracks: CapturedTracks?
```

near the other track/file properties (after `fileURL`, `finalizedAudioURL`). If the `Recording` init needs updating, leave the new field defaulting to `nil`.

Verify:
```bash
grep -n "var capturedTracks\|var finalizedAudioURL" Sources/dBrief/Models/Recording.swift
```
Expected: both lines present.

- [ ] **Step 6.5: Rewrite `ensureRecordingFinalized` to pass tracks**

Replace the body (currently lines 1276–1307):

```swift
    private func ensureRecordingFinalized(recording: Recording) async throws {
        if recording.finalizedAudioURL != nil {
            return
        }

        let meetingTitle = recording.meetingTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if meetingTitle.isEmpty {
            recording.meetingTitleDraft = defaultMeetingTitle(from: recording.associatedApp)
        }

        let tracks = recording.capturedTracks ?? CapturedTracks(systemURL: nil, micURL: recording.fileURL)
        let segmentationEnabled = appSettings.effectiveTranscriptionEngine != .localWhisper
            && appSettings.effectiveTranscriptionEngine != .parakeetLocal

        let result = try await recordingFinalizer.finalize(
            tracks: tracks,
            recording: recording,
            baseFolder: appSettings.effectiveRecordingFolderURL,
            segmentationEnabled: segmentationEnabled
        )

        recording.fileURL = result.masterAudioURL
        recording.finalizedAudioURL = result.masterAudioURL
        recording.segmentAudioURLs = result.segmentAudioURLs
        recording.metadataURL = result.metadataURL
        recording.finalizationWarnings = result.warnings
        recording.capturedTracks = nil  // scratch files have been consumed

        if let attrs = try? FileManager.default.attributesOfItem(atPath: result.masterAudioURL.path),
           let size = attrs[.size] as? Int64
        {
            recording.fileSize = size
        }
    }
```

The `?? CapturedTracks(systemURL: nil, micURL: recording.fileURL)` branch handles the `pickFileForTranscription` / `loadYouTubeAudio` / `processQueue` paths where there's no fresh capture — the incoming `fileURL` is treated as a pre-finalized mic track (works for any AVFoundation-readable format).

- [ ] **Step 6.6: Update queue discovery to find both `.m4a` and `.flac`**

In `discoverQueuedItems()` (around line 1402), replace:

```swift
            let stem = fileURL.deletingPathExtension().deletingPathExtension()
            let audioURL = stem.appendingPathExtension("flac")
            guard FileManager.default.fileExists(atPath: audioURL.path) else { continue }
```

with:

```swift
            let stem = fileURL.deletingPathExtension().deletingPathExtension()
            let audioURL: URL
            if FileManager.default.fileExists(atPath: stem.appendingPathExtension("m4a").path) {
                audioURL = stem.appendingPathExtension("m4a")
            } else if FileManager.default.fileExists(atPath: stem.appendingPathExtension("flac").path) {
                audioURL = stem.appendingPathExtension("flac")
            } else {
                continue
            }
```

- [ ] **Step 6.7: Verify the build is green**

```bash
swift build 2>&1 | grep -E "error:"
```

Expected: empty.

- [ ] **Step 6.8: Run all tests**

```bash
swift test 2>&1 | tail -40
```

Expected: `AudioTrackWriterTests` and `AppSettingsTests` PASS. `WhisperPipelineTests` may fail — those extensions get updated in Task 9.

- [ ] **Step 6.9: Commit the rewrite**

```bash
git add Sources/dBrief/Audio/ \
        Sources/dBrief/Services/RecordingFinalizer.swift \
        Sources/dBrief/Services/RecordingManager.swift \
        Sources/dBrief/Models/Recording.swift \
        Tests/dBriefTests/AudioFileWriterTests.swift \
        Tests/dBriefTests/AudioTrackWriterTests.swift
git commit -m "feat(audio): rewrite recording pipeline as dual-track capture with ffmpeg amix merge

Replaces the single-engine dual-player-node mixer (which silently dropped mic
buffers and produced pitch-shifted system audio) with two fully independent
capture paths written to separate CAFs, merged to M4A at finalize time.

Fixes pitch shift, silent mic, and low-volume system audio."
```

---

## Task 7 — UI: AEC toggle + copy updates

**Files:**
- Modify: `Sources/dBrief/UI/SettingsRecordingTab.swift`
- Modify: `Sources/dBrief/UI/PostRecordingSheet.swift`

- [ ] **Step 7.1: Update `SettingsRecordingTab.swift`**

Replace the existing `Audio Input` section block (lines 10–35) so the AEC toggle lives above the power-user section (always visible), and update the power-user `Audio Quality` copy.

Replace:
```swift
            Section("Audio Input") {
                ...existing content...
            }
            .listRowBackground(Color.clear)

            if appSettings.powerUserMode {
                Section("Audio Quality") {
                    LabeledContent("Recording profile:") {
                        Text("Native rate FLAC (48 kHz stereo)")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    LabeledContent("Post-process:") {
                        Text("80Hz high-pass, -14 LUFS to -1dBTP, AEC/echo cancel")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .listRowBackground(Color.clear)
            }
```

with (keep your existing Audio Input block above unchanged, only the Echo Cancellation section and the replaced power-user section change):

```swift
            Section("Audio Input") {
                // ...existing content unchanged...
            }
            .listRowBackground(Color.clear)

            Section("Echo Cancellation") {
                Toggle("Remove meeting audio from microphone", isOn: $settings.acousticEchoCancellation)
                Text("Recommended when using laptop speakers. Prevents the meeting audio playing from your speakers from being picked up by your microphone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)

            if appSettings.powerUserMode {
                Section("Audio Quality") {
                    LabeledContent("Capture:") {
                        Text("CAF/LPCM per track (system + mic separate)")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    LabeledContent("Master output:") {
                        Text("M4A/AAC 96 kbps · 48 kHz stereo")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    LabeledContent("Post-process:") {
                        Text("Mic: 80Hz HPF, -16 LUFS loudnorm\nSystem: 40Hz HPF, 12kHz LPF\nMix: amix normalize=0")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .listRowBackground(Color.clear)
            }
```

- [ ] **Step 7.2: Update `PostRecordingSheet.swift` file-naming copy**

Open `Sources/dBrief/UI/PostRecordingSheet.swift`. Find the line (around line 39):

```swift
            Text("Used for FLAC file naming (`YYYY-MM-DD_HHMM_[meeting-title].flac`).")
```

Replace with:

```swift
            Text("Used for file naming (`YYYY-MM-DD_HHMM_[meeting-title].m4a`).")
```

- [ ] **Step 7.3: Build**

```bash
swift build 2>&1 | grep -E "error:"
```

Expected: empty.

- [ ] **Step 7.4: Commit**

```bash
git add Sources/dBrief/UI/SettingsRecordingTab.swift Sources/dBrief/UI/PostRecordingSheet.swift
git commit -m "feat(ui): add AEC toggle, update Audio Quality copy for M4A"
```

---

## Task 8 — Update `WhisperPipelineTests`

**Files:**
- Modify: `Tests/dBriefTests/WhisperPipelineTests.swift`

- [ ] **Step 8.1: Change file-extension expectations in the four failing tests**

In `Tests/dBriefTests/WhisperPipelineTests.swift`, make these substitutions (exact strings — do each individually):

1. Line 31: `"2026-02-13_1445_meeting.flac"` → `"2026-02-13_1445_meeting.m4a"`
2. Line 37: `fileExtension: "flac"` → `fileExtension: "m4a"`
3. Line 40: `"2026-02-13_1445_meeting_2.flac"` → `"2026-02-13_1445_meeting_2.m4a"`
4. Line 49: `masterFileName: "2026-02-13_1445_team-sync.flac"` → `masterFileName: "2026-02-13_1445_team-sync.m4a"`
5. Line 51: `"2026-02-13_1445_team-sync_part01.flac"` → `"2026-02-13_1445_team-sync_part01.m4a"`
6. Line 52: `"2026-02-13_1445_team-sync_part02.flac"` → `"2026-02-13_1445_team-sync_part02.m4a"`
7. Line 148: `nested.appendingPathComponent("2026-02-13_1445_sync.flac")` → `nested.appendingPathComponent("2026-02-13_1445_sync.m4a")`
8. Line 157: `names.contains("2026-02-13_1445_sync.flac")` → `names.contains("2026-02-13_1445_sync.m4a")`

**Leave line 93 alone:**
```swift
#expect(WebhookPayloadBuilder.contentType(for: URL(fileURLWithPath: "/tmp/a.flac")) == "audio/flac")
```
This asserts that the existing FLAC MIME mapping still works for legacy recordings. `WebhookPayloadBuilder.contentType(for:)` already supports `.m4a` → `audio/m4a`, which is what new recordings will use without further code changes.

- [ ] **Step 8.2: Run the tests**

```bash
swift test 2>&1 | tail -20
```

Expected: all tests PASS.

- [ ] **Step 8.3: Commit**

```bash
git add Tests/dBriefTests/WhisperPipelineTests.swift
git commit -m "test: update pipeline expectations for M4A master output"
```

---

## Task 9 — Build, full test suite, manual smoke verification

**Files:** none (verification only)

- [ ] **Step 9.1: Clean build**

```bash
swift package clean && swift build 2>&1 | tail -20
```

Expected: `Build complete!` with no errors.

- [ ] **Step 9.2: Full test suite**

```bash
swift test 2>&1 | tail -30
```

Expected: all tests PASS.

- [ ] **Step 9.3: Verify ffmpeg command shape manually**

Sanity-check the command that will be run against a real meeting audio. Build the app bundle and start a short test recording:

```bash
make app
open dBrief.app
```

In the app:
1. Start a recording while playing system audio (any YouTube or Spotify sample) and speaking into the mic.
2. Stop after ~30 seconds.
3. Check Console.app for "System capture started" and "Mic capture started" log lines.
4. Let finalization complete.
5. Open the resulting M4A — confirm:
   - **System audio is at normal volume** (not low).
   - **Mic is clearly audible** (not silent).
   - **No pitch shift** on the system audio.
   - **No reverb** from laptop speakers bleeding into the mic track.

- [ ] **Step 9.4: Verify scratch CAFs are cleaned up**

```bash
ls ~/Library/Containers/com.dbrief.app/Data/tmp/ 2>/dev/null || true
ls /var/folders/*/T/dbrief-raw-* 2>/dev/null
```

Expected: no `dbrief-raw-*_system.caf` / `dbrief-raw-*_mic.caf` leftovers after a successful merge.

- [ ] **Step 9.5: Verify downstream transcription with Parakeet**

The spec flagged this as a verification point. Confirm:

1. In Settings → Recording → Transcription engine, pick "Parakeet TDT (Local)."
2. Run a short recording.
3. In `processRecording` the transcription step should complete without error.

If Parakeet errors on M4A input (FluidAudio's `AsrManager` is expected to accept it via AVFoundation, but this is the one thing the spec could not verify statically):

- Quick fix: in `ParakeetTranscriptionService.transcribe`, before handing the URL to `mgr.transcribe`, add a WAV pre-transcode using the existing ffmpeg helper (mirror `LocalTranscriptionService`'s pattern).
- If no error: no action needed.

- [ ] **Step 9.6: Update `tasks/todo.md`**

Mark the audio rewrite as done in `tasks/todo.md`:

```markdown
## Done
...
- [x] Rewrite audio pipeline — dual-track capture (system.caf + mic.caf), ffmpeg amix to M4A master, adds AEC toggle
```

And remove the stale entry from yesterday's attempt ("Fix audio quality — eliminate pitch shift…") since it's superseded.

- [ ] **Step 9.7: Final commit**

```bash
git add tasks/todo.md
git commit -m "docs: mark audio pipeline rewrite complete"
```

---

## Self-review

- **Spec coverage:** ✅
  - Section 1 (Capture architecture) → Task 3
  - Section 2 (`AudioTrackWriter`) → Task 1
  - Section 3 (Finalization + ffmpeg) → Task 5
  - Section 4 (Impact surface, all files) → Tasks 2, 4, 6, 7, 8
  - AEC toggle per spec → Task 2 (settings) + Task 7 (UI)
  - MIME type handling → no code change needed (WebhookPayloadBuilder already supports `.m4a`); test at line 93 left for legacy; validated in Task 8
  - Parakeet M4A support verification → Task 9 Step 9.5

- **Placeholder scan:** No TBDs, no "implement later," all code steps show exact code.

- **Type consistency:** `CapturedTracks` defined once in `AudioTrackWriter.swift`, referenced by `AudioCaptureManager.trackURLs`, `Recording.capturedTracks`, `RecordingFinalizer.finalize(tracks:)`. `AudioTrackWriter.Role` used only internally. All method signatures match across tasks.
