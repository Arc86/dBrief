# Laptop Mode — Offline Task Queue Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow users to defer recording processing to a later time via a file-based queue, with a manual "Process Queue" trigger and smart power-state nudge.

**Architecture:** A `.queue.json` file alongside each finalized recording stores processing flags. Queue discovery scans the recording folder for these files. The menu bar shows queue count and a process button. IOKit power monitoring nudges the user when plugged in.

**Tech Stack:** Swift, Foundation (JSONEncoder/JSONDecoder), IOKit (IOPSCopyPowerSourcesInfo), SwiftUI

---

### Task 1: Create QueueItem model

**Files:**
- Create: `Sources/dBrief/Models/QueueItem.swift`

**Step 1: Create the model**

```swift
import Foundation

struct QueueItem: Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    var transcribe: Bool
    var summary: Bool
    var actionItems: Bool
    var tags: Bool

    /// The audio file URL is NOT stored in the JSON — it's derived from the `.queue.json` path.
    /// This keeps the JSON minimal and avoids stale paths.
}
```

**Step 2: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```bash
git add Sources/dBrief/Models/QueueItem.swift
git commit -m "feat: add QueueItem model for offline task queue"
```

---

### Task 2: Add queue helpers to RecordingManager

**Files:**
- Modify: `Sources/dBrief/Services/RecordingManager.swift`

**Step 1: Add queue file helpers**

Add these private/public methods to RecordingManager, near the existing transcript helpers:

```swift
// MARK: - Queue Persistence

/// Derives the queue JSON path from the finalized audio URL.
private static func queueURL(for recording: Recording) -> URL? {
    guard let audioURL = recording.finalizedAudioURL else { return nil }
    return audioURL.deletingPathExtension().appendingPathExtension("queue.json")
}

/// Writes a queue item to disk alongside the recording's audio file.
private func saveQueueItem(_ item: QueueItem, for recording: Recording) throws {
    guard let url = Self.queueURL(for: recording) else {
        throw NSError(domain: "RecordingManager", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Cannot determine queue file path — recording not finalized."
        ])
    }
    let data = try JSONEncoder().encode(item)
    try data.write(to: url, options: .atomic)
}

/// Removes the queue file for a recording (called after successful processing).
private static func removeQueueFile(for audioURL: URL) {
    let queueURL = audioURL.deletingPathExtension().appendingPathExtension("queue.json")
    try? FileManager.default.removeItem(at: queueURL)
}

/// Discovers all queued recordings in the recording folder.
/// Returns tuples of (audioURL, queueItem) sorted oldest-first.
func discoverQueuedItems() -> [(audioURL: URL, item: QueueItem)] {
    let folder = appSettings.effectiveRecordingFolderURL
    guard let enumerator = FileManager.default.enumerator(
        at: folder,
        includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    var results: [(url: URL, date: Date, item: QueueItem)] = []
    for case let fileURL as URL in enumerator {
        guard fileURL.pathExtension.lowercased() == "json",
              fileURL.lastPathComponent.hasSuffix(".queue.json") else { continue }
        guard let data = try? Data(contentsOf: fileURL),
              let item = try? JSONDecoder().decode(QueueItem.self, from: data) else { continue }

        // Derive audio URL: replace .queue.json with .flac
        let stem = fileURL.deletingPathExtension().deletingPathExtension()
        let audioURL = stem.appendingPathExtension("flac")
        guard FileManager.default.fileExists(atPath: audioURL.path) else { continue }

        let values = try? fileURL.resourceValues(forKeys: [.creationDateKey])
        let date = values?.creationDate ?? .distantPast
        results.append((url: audioURL, date: date, item: item))
    }

    return results
        .sorted { $0.date < $1.date }
        .map { ($0.url, $0.item) }
}
```

**Step 2: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```bash
git add Sources/dBrief/Services/RecordingManager.swift
git commit -m "feat: add queue file persistence helpers to RecordingManager"
```

---

### Task 3: Add queueForLater method

**Files:**
- Modify: `Sources/dBrief/Services/RecordingManager.swift`

**Step 1: Add the queueForLater method**

Add after `skipProcessing()` (around line 355):

```swift
/// Finalizes the current recording and saves a queue item for deferred processing.
func queueForLater(
    transcribe: Bool,
    summary: Bool,
    actionItems: Bool,
    tags: Bool
) async {
    guard let recording = appState.currentRecording else { return }

    do {
        try await ensureRecordingFinalized(recording: recording)
    } catch {
        appState.lastError = error.localizedDescription
        return
    }

    let item = QueueItem(
        transcribe: transcribe,
        summary: summary && transcribe,
        actionItems: actionItems && transcribe,
        tags: tags && transcribe
    )

    do {
        try saveQueueItem(item, for: recording)
    } catch {
        appState.lastError = error.localizedDescription
        return
    }

    appState.showPostRecordingSheet = false
    appState.recordingState = .idle
    appState.queuedCount = discoverQueuedItems().count
}
```

**Step 2: Build** (will fail until Task 4 adds `queuedCount` to AppState — that's fine, commit together or do Task 4 first)

---

### Task 4: Add queuedCount to AppState

**Files:**
- Modify: `Sources/dBrief/App/AppState.swift`

**Step 1: Add the property**

Add after `lastError` (line 28):

```swift
var queuedCount: Int = 0
```

**Step 2: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit Tasks 3+4 together**

```bash
git add Sources/dBrief/Services/RecordingManager.swift Sources/dBrief/App/AppState.swift
git commit -m "feat: add queueForLater method and queuedCount state"
```

---

### Task 5: Add processQueue method

**Files:**
- Modify: `Sources/dBrief/Services/RecordingManager.swift`

**Step 1: Add processQueue method**

Add after `queueForLater()`:

```swift
/// Processes all queued recordings sequentially.
func processQueue() async {
    guard appState.recordingState != .processing else { return }

    let queued = discoverQueuedItems()
    guard !queued.isEmpty else { return }

    for (audioURL, item) in queued {
        let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let name = audioURL.deletingPathExtension().lastPathComponent

        let recording = Recording(
            fileURL: audioURL,
            fileSize: size,
            meetingTitleDraft: name,
            finalizedAudioURL: audioURL
        )

        appState.currentRecording = recording
        await processRecording(
            transcribe: item.transcribe,
            summary: item.summary,
            actionItems: item.actionItems,
            tags: item.tags
        )

        // Remove queue file after successful processing
        Self.removeQueueFile(for: audioURL)
    }

    appState.queuedCount = discoverQueuedItems().count
}
```

**Step 2: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```bash
git add Sources/dBrief/Services/RecordingManager.swift
git commit -m "feat: add processQueue method for batch deferred processing"
```

---

### Task 6: Add "Queue for Later" button to PostRecordingSheet

**Files:**
- Modify: `Sources/dBrief/UI/PostRecordingSheet.swift`

**Step 1: Add the button**

In the `HStack` containing Skip and Process buttons (line 104), add a "Queue" button between Skip and Spacer:

```swift
HStack {
    Button("Skip") {
        if let recording = appState.currentRecording {
            recording.meetingTitleDraft = sanitizedMeetingTitle
        }
        Task { await recordingManager.skipProcessing() }
    }
    .buttonStyle(.bordered)
    .disabled(sanitizedMeetingTitle.isEmpty)

    Button("Queue") {
        if let recording = appState.currentRecording {
            recording.meetingTitleDraft = sanitizedMeetingTitle
        }
        Task {
            await recordingManager.queueForLater(
                transcribe: transcribe,
                summary: summary && transcribe,
                actionItems: actionItems && transcribe,
                tags: tags && transcribe
            )
        }
    }
    .buttonStyle(.bordered)
    .disabled(sanitizedMeetingTitle.isEmpty)
    .help("Finalize audio and queue processing for later")

    Spacer()

    Button("Process") {
        // ... existing code unchanged
    }
    // ... existing modifiers unchanged
}
```

**Step 2: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```bash
git add Sources/dBrief/UI/PostRecordingSheet.swift
git commit -m "feat: add Queue for Later button to post-recording sheet"
```

---

### Task 7: Add queue badge and Process Queue button to menu bar

**Files:**
- Modify: `Sources/dBrief/App/DBriefApp.swift`

**Step 1: Add queue badge to menu bar icon**

In the `label:` section of `MenuBarExtra` (line 107-110), update the idle state to show a badge when queue is non-empty:

```swift
} else if context.appState.queuedCount > 0 {
    HStack(spacing: 2) {
        Image(systemName: "waveform")
            .symbolRenderingMode(.hierarchical)
        Text("\(context.appState.queuedCount)")
            .font(.caption2)
            .foregroundStyle(.orange)
    }
} else {
    Image(systemName: "waveform")
        .symbolRenderingMode(.hierarchical)
}
```

**Step 2: Add Process Queue button to MenuBarView**

In `MenuBarView`, add a queue section before the History/Transcribe File row (before line 168). Add it between the processing/history section and the bottom toolbar:

```swift
if appState.queuedCount > 0, appState.isIdle {
    Divider()
    HStack {
        Label("\(appState.queuedCount) queued", systemImage: "tray.full")
            .font(.callout)
            .foregroundStyle(.orange)
        Spacer()
        Button("Process Queue") {
            Task { await recordingManager.processQueue() }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(.orange)
    }
}
```

**Step 3: Initialize queuedCount on app launch**

In `MenuBarView`'s `.task` modifier (or add one if it doesn't exist), refresh the queue count:

Find the existing `.task` on MenuBarView (or add after `.onAppear`):

```swift
.task {
    appState.queuedCount = recordingManager.discoverQueuedItems().count
}
```

**Step 4: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 5: Commit**

```bash
git add Sources/dBrief/App/DBriefApp.swift
git commit -m "feat: add queue badge and Process Queue button to menu bar"
```

---

### Task 8: Add power state monitoring for smart nudge

**Files:**
- Create: `Sources/dBrief/Services/PowerStateMonitor.swift`

**Step 1: Create the monitor**

```swift
import Foundation
import IOKit.ps
import UserNotifications

@MainActor
@Observable
final class PowerStateMonitor {
    private var source: CFRunLoopSource?
    private var lastNotifiedCount: Int = 0
    private weak var appState: AppState?
    private weak var recordingManager: RecordingManager?

    init(appState: AppState, recordingManager: RecordingManager) {
        self.appState = appState
        self.recordingManager = recordingManager
    }

    func startMonitoring() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerStateMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                monitor.handlePowerChange()
            }
        }, context).takeRetainedValue()

        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    func stopMonitoring() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        source = nil
    }

    private func handlePowerChange() {
        guard isOnACPower() else {
            lastNotifiedCount = 0
            return
        }
        guard let appState, let recordingManager else { return }

        let count = recordingManager.discoverQueuedItems().count
        appState.queuedCount = count

        guard count > 0, count != lastNotifiedCount else { return }
        lastNotifiedCount = count

        let content = UNMutableNotificationContent()
        content.title = "Recordings Queued"
        content.body = "You have \(count) recording\(count == 1 ? "" : "s") queued for processing. You're now on AC power."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "queue-power-nudge",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated private func isOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              !sources.isEmpty else {
            return true // Desktop Mac, always on AC
        }
        // Check if any source is on AC power
        for source in sources {
            if let info = IOPSGetPowerSourceDescription(snapshot, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any],
               let powerSource = info[kIOPSPowerSourceStateKey] as? String,
               powerSource == kIOPSACPowerValue {
                return true
            }
        }
        return false
    }
}
```

**Step 2: Wire into AppContext**

Modify `Sources/dBrief/App/AppContext.swift` (or `DBriefApp.swift` if AppContext is there):
- Add `let powerStateMonitor: PowerStateMonitor` property
- Initialize it after RecordingManager: `self.powerStateMonitor = PowerStateMonitor(appState: appState, recordingManager: recordingManager)`
- Call `powerStateMonitor.startMonitoring()` at the end of init

**Step 3: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 4: Commit**

```bash
git add Sources/dBrief/Services/PowerStateMonitor.swift Sources/dBrief/App/AppContext.swift
git commit -m "feat: add power state monitoring for queue processing nudge"
```

---

### Task 9: Add test for QueueItem round-trip

**Files:**
- Modify: `Tests/dBriefTests/WhisperPipelineTests.swift`

**Step 1: Add test**

```swift
@Test
func queueItemRoundTripsToJSON() throws {
    let original = QueueItem(
        transcribe: true,
        summary: true,
        actionItems: false,
        tags: true
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(QueueItem.self, from: data)

    #expect(decoded.transcribe == true)
    #expect(decoded.summary == true)
    #expect(decoded.actionItems == false)
    #expect(decoded.tags == true)
}
```

**Step 2: Run tests**

Run: `swift test 2>&1 | tail -10`
Expected: All tests pass

**Step 3: Commit**

```bash
git add Tests/dBriefTests/WhisperPipelineTests.swift
git commit -m "test: add QueueItem JSON round-trip test"
```
