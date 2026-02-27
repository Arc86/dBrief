# Persist Transcription Before AI Analysis — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Save transcription results to disk after transcription completes so failed AI analysis can be retried without re-transcribing.

**Architecture:** Add a `.transcript.json` file alongside each recording's audio and metadata files. `RecordingManager` saves/loads this file. Recording history gains a "Retry AI" button for recordings with a saved transcript. The existing `processRecording` pipeline is refactored to extract AI+markdown+integrations into a reusable method.

**Tech Stack:** Swift, Foundation (JSONEncoder/JSONDecoder), SwiftUI

---

### Task 1: Add `transcriptURL` to Recording model

**Files:**
- Modify: `Sources/dBrief/Models/Recording.swift:20-23`

**Step 1: Add the field**

Add `var transcriptURL: URL?` after `metadataURL` (line 22) and add it to the `init` parameter list:

```swift
// In the property declarations, after line 22:
var transcriptURL: URL?

// In init, add parameter after metadataURL:
transcriptURL: URL? = nil,

// In init body, after self.metadataURL:
self.transcriptURL = transcriptURL
```

**Step 2: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```bash
git add Sources/dBrief/Models/Recording.swift
git commit -m "feat: add transcriptURL field to Recording model"
```

---

### Task 2: Add transcript persistence helpers to RecordingManager

**Files:**
- Modify: `Sources/dBrief/Services/RecordingManager.swift`

**Step 1: Add helper methods**

Add these two private methods at the end of RecordingManager (before the closing `}`), near the other private helpers:

```swift
/// Derives the transcript JSON path from the finalized audio URL.
private static func transcriptURL(for recording: Recording) -> URL? {
    guard let audioURL = recording.finalizedAudioURL else { return nil }
    return audioURL.deletingPathExtension().appendingPathExtension("transcript.json")
}

/// Saves the transcription result as JSON alongside the audio file.
private func saveTranscript(_ result: TranscriptionResult, for recording: Recording) {
    guard let url = Self.transcriptURL(for: recording) else { return }
    do {
        let data = try JSONEncoder().encode(result)
        try data.write(to: url, options: .atomic)
        recording.transcriptURL = url
    } catch {
        // Non-critical: log but don't fail the pipeline
    }
}

/// Loads a previously saved transcription from disk.
private func loadSavedTranscript(for recording: Recording) -> TranscriptionResult? {
    let url = recording.transcriptURL ?? Self.transcriptURL(for: recording)
    guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let data = try? Data(contentsOf: url),
          let result = try? JSONDecoder().decode(TranscriptionResult.self, from: data) else {
        return nil
    }
    recording.transcriptURL = url
    return result
}
```

**Step 2: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```bash
git add Sources/dBrief/Services/RecordingManager.swift
git commit -m "feat: add transcript save/load helpers to RecordingManager"
```

---

### Task 3: Wire persistence into processRecording pipeline

**Files:**
- Modify: `Sources/dBrief/Services/RecordingManager.swift:138-148`

**Step 1: Replace the DEBUG dummy transcription block**

Replace the current Step 1 block (lines 138-148, the DEBUG dummy transcription) with:

```swift
// Step 1: Transcription
if transcribe {
    // Check for saved transcript on disk first
    if let saved = loadSavedTranscript(for: recording) {
        let stepIndex = appState.processingSteps.count
        appState.processingSteps.append(ProcessingStep(name: "Loaded saved transcript", status: .inProgress))
        recording.transcription = saved
        appState.processingSteps[stepIndex].status = .completed
    } else {
        let stepIndex = appState.processingSteps.count
        let stepName: String = {
            switch appSettings.effectiveTranscriptionEngine {
            case .appleSpeech: "Transcribing (Apple Speech)"
            case .localWhisper: "Transcribing (Local Whisper)"
            case .remoteEndpoint: "Transcribing audio"
            }
        }()
        appState.processingSteps.append(ProcessingStep(name: stepName, status: .inProgress))
        do {
            let result = try await transcribeRecordingAudio(recording: recording, stepIndex: stepIndex)
            recording.transcription = result
            appState.processingSteps[stepIndex].status = .completed
            if let warnings = result.warnings, !warnings.isEmpty {
                appState.processingSteps.append(
                    ProcessingStep(
                        name: "Transcription warnings",
                        status: .failed(warnings.joined(separator: "\n"))
                    )
                )
            }
            // Persist transcript to disk for retry resilience
            saveTranscript(result, for: recording)
        } catch {
            appState.processingSteps[stepIndex].status = .failed(error.localizedDescription)
        }
    }
}
```

**Step 2: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```bash
git add Sources/dBrief/Services/RecordingManager.swift
git commit -m "feat: persist transcript to disk after transcription, load on re-run"
```

---

### Task 4: Add retryAIAnalysis method

**Files:**
- Modify: `Sources/dBrief/Services/RecordingManager.swift`

**Step 1: Add retryAIAnalysis method**

Add this public method after `processRecording()` (after line 299):

```swift
/// Retries AI analysis for a recording that already has a saved transcript.
/// Loads the transcript from disk if needed, then runs AI → title → markdown → integrations.
func retryAIAnalysis(for recording: Recording) async {
    guard appState.recordingState != .processing else { return }

    // Load transcript if not already in memory
    if recording.transcription == nil {
        guard let saved = loadSavedTranscript(for: recording) else { return }
        recording.transcription = saved
    }

    // Clear previous AI results
    recording.summary = nil
    recording.actionItems = nil
    recording.tags = nil
    recording.sentiment = nil
    recording.generatedTitle = nil

    appState.currentRecording = recording
    appState.recordingState = .processing
    appState.processingSteps = []

    let localAIAvailable: Bool = {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return LocalAIService.isAvailable
        }
        return false
        #else
        return false
        #endif
    }()

    // Run AI analysis
    let transcription = recording.transcription!
    let aiEngine = appSettings.effectiveAIEngine
    let endpoint = appSettings.effectiveDefaultAIEndpoint

    let summaryStepIndex = appendAIStep(labelForSummary(engine: aiEngine))
    let actionStepIndex = appendAIStep(labelForActionItems(engine: aiEngine))
    let tagsStepIndex = appendAIStep(labelForTags(engine: aiEngine))

    switch aiEngine {
    case .appleIntelligence:
        await runAppleIntelligenceTasks(
            transcription: transcription.text,
            localAvailable: localAIAvailable,
            summaryStepIndex: summaryStepIndex,
            actionStepIndex: actionStepIndex,
            tagsStepIndex: tagsStepIndex,
            recording: recording
        )
    case .qwenLocal:
        await runLocalQwenTasks(
            transcription: transcription.text,
            summaryStepIndex: summaryStepIndex,
            actionStepIndex: actionStepIndex,
            tagsStepIndex: tagsStepIndex,
            recording: recording
        )
    case .remoteEndpoint:
        await runRemoteAITasks(
            transcription: transcription.text,
            endpoint: endpoint,
            summaryStepIndex: summaryStepIndex,
            actionStepIndex: actionStepIndex,
            tagsStepIndex: tagsStepIndex,
            recording: recording
        )
    }

    // Generate title & write markdown
    var generatedMarkdownURL: URL?

    if let transcriptionText = recording.transcription?.text, !transcriptionText.isEmpty {
        let language = recording.transcription?.language
        let titleStepIndex = appState.processingSteps.count
        appState.processingSteps.append(ProcessingStep(name: "Generating Title", status: .inProgress))
        do {
            #if canImport(FoundationModels)
            if appSettings.effectiveAIEngine == .appleIntelligence, #available(macOS 26, *), localAIAvailable {
                recording.generatedTitle = try await LocalAIService().generateTitle(
                    transcription: String(transcriptionText.prefix(500)),
                    language: language
                )
            } else if let endpoint = appSettings.effectiveDefaultAIEndpoint {
                recording.generatedTitle = try await aiService.generateTitle(
                    transcription: String(transcriptionText.prefix(500)),
                    language: language,
                    endpoint: endpoint
                )
            }
            #else
            if let endpoint = appSettings.effectiveDefaultAIEndpoint {
                recording.generatedTitle = try await aiService.generateTitle(
                    transcription: String(transcriptionText.prefix(500)),
                    language: language,
                    endpoint: endpoint
                )
            }
            #endif
            appState.processingSteps[titleStepIndex].status = .completed
        } catch {
            appState.processingSteps[titleStepIndex].status = .completed
        }
    }

    let stepIndex = appState.processingSteps.count
    appState.processingSteps.append(ProcessingStep(name: "Writing Markdown", status: .inProgress))
    do {
        let outputFolder = resolveMarkdownOutputFolder(for: recording)
        let transcriptionEndpoint: Endpoint? = switch appSettings.effectiveTranscriptionEngine {
        case .appleSpeech: Endpoint(name: "Apple Speech", baseURL: "", modelName: "Apple Speech")
        case .localWhisper: Endpoint(name: "WhisperKit", baseURL: "", modelName: "whisper-small (CoreML)")
        case .remoteEndpoint: appSettings.effectiveDefaultTranscriptionEndpoint
        }
        let aiEndpoint: Endpoint? = switch appSettings.effectiveAIEngine {
        case .appleIntelligence: Endpoint(name: "Apple Intelligence", baseURL: "", modelName: "Apple Intelligence")
        case .qwenLocal: Endpoint(name: "Qwen 2.5 Local", baseURL: "", modelName: "Qwen2.5-7B-Instruct-4bit (MLX)")
        case .remoteEndpoint: appSettings.effectiveDefaultAIEndpoint
        }
        generatedMarkdownURL = try markdownGenerator.generate(
            recording: recording,
            outputFolder: outputFolder,
            transcriptionEndpoint: transcriptionEndpoint,
            aiEndpoint: aiEndpoint,
            includeTranscript: appSettings.obsidianIncludeTranscript
        )
        appState.processingSteps[stepIndex].status = .completed
    } catch {
        appState.processingSteps[stepIndex].status = .failed(error.localizedDescription)
    }

    // Integration dispatch
    if hasEnabledIntegrations {
        let results = await integrationDispatchService.dispatch(
            recording: recording,
            settings: appSettings,
            generatedMarkdownURL: generatedMarkdownURL
        )
        for result in results {
            let idx = appState.processingSteps.count
            appState.processingSteps.append(
                ProcessingStep(name: "Send: \(result.destination.displayName)", status: .inProgress)
            )
            switch result.status {
            case .success, .skipped:
                appState.processingSteps[idx].status = .completed
            case .failed:
                appState.processingSteps[idx].status = .failed(result.message)
            }
        }
    }

    appState.recordingState = .idle

    let failedCount = appState.processingSteps.filter {
        if case .failed = $0.status { return true }
        return false
    }.count
    sendCompletionNotification(fileName: recording.fileName, failed: failedCount)
}
```

**Step 2: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```bash
git add Sources/dBrief/Services/RecordingManager.swift
git commit -m "feat: add retryAIAnalysis method for re-running AI on saved transcripts"
```

---

### Task 5: Add "Retry AI" button to RecordingHistoryView

**Files:**
- Modify: `Sources/dBrief/UI/RecordingHistoryView.swift`

**Step 1: Add RecordingManager environment dependency**

Add to the top of `RecordingHistoryView` struct, after the existing `@Environment` properties (line 4-5):

```swift
@Environment(RecordingManager.self) private var recordingManager
```

Note: RecordingManager must already be in the environment. Check how it's passed — if it's not, we'll need to add it. (It's created in AppContext and should be available.)

**Step 2: Update HistoryItem to track transcript availability**

Add a `hasTranscript` field to `HistoryItem`:

```swift
struct HistoryItem: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let date: Date
    let size: Int64
    let hasTranscript: Bool
    // ... rest unchanged
}
```

**Step 3: Add retry button to historyRow**

In `historyRow`, add a retry button between the Finder button and the Spacer. After the existing Spacer() (line 91) and before the Finder button (line 93):

```swift
if item.hasTranscript {
    Button {
        Task {
            let recording = Recording(
                fileURL: item.url,
                fileSize: item.size,
                meetingTitleDraft: item.name,
                finalizedAudioURL: item.url
            )
            await recordingManager.retryAIAnalysis(for: recording)
        }
    } label: {
        Image(systemName: "arrow.trianglehead.2.clockwise")
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .help("Retry AI Analysis")
}
```

**Step 4: Update loadRecordings to detect transcript files**

Update the `loadRecordings()` method to check for `.transcript.json` files:

```swift
private func loadRecordings() {
    let folder = appSettings.effectiveRecordingFolderURL
    recordings = RecordingDiscovery.discover(in: folder).map { entry in
        let transcriptURL = entry.url.deletingPathExtension().appendingPathExtension("transcript.json")
        let hasTranscript = FileManager.default.fileExists(atPath: transcriptURL.path)
        return HistoryItem(
            url: entry.url,
            name: entry.url.deletingPathExtension().lastPathComponent,
            date: entry.createdAt,
            size: entry.size,
            hasTranscript: hasTranscript
        )
    }
}
```

**Step 5: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 6: Commit**

```bash
git add Sources/dBrief/UI/RecordingHistoryView.swift
git commit -m "feat: add Retry AI Analysis button to recording history"
```

---

### Task 6: Add test for transcript round-trip persistence

**Files:**
- Modify: `Tests/dBriefTests/WhisperPipelineTests.swift`

**Step 1: Add round-trip test**

Add a new test to `WhisperPipelineTests`:

```swift
@Test
func transcriptionResultRoundTripsToJSON() throws {
    let original = TranscriptionResult(
        text: "Hello world. This is a test.",
        segments: [
            .init(start: 0.0, end: 1.5, text: "Hello world."),
            .init(start: 1.5, end: 3.0, text: "This is a test."),
        ],
        language: "en",
        warnings: ["Low confidence on segment 2"]
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(TranscriptionResult.self, from: data)

    #expect(decoded.text == original.text)
    #expect(decoded.segments.count == 2)
    #expect(decoded.segments[0].start == 0.0)
    #expect(decoded.segments[0].end == 1.5)
    #expect(decoded.segments[0].text == "Hello world.")
    #expect(decoded.segments[1].start == 1.5)
    #expect(decoded.segments[1].text == "This is a test.")
    #expect(decoded.language == "en")
    #expect(decoded.warnings == ["Low confidence on segment 2"])
}
```

**Step 2: Run tests**

Run: `swift test 2>&1 | tail -10`
Expected: All tests pass

**Step 3: Commit**

```bash
git add Tests/dBriefTests/WhisperPipelineTests.swift
git commit -m "test: add TranscriptionResult JSON round-trip test"
```

---

### Task 7: Verify RecordingManager is in the SwiftUI environment

**Files:**
- Check: `Sources/dBrief/App/DBriefApp.swift`

**Step 1: Verify environment injection**

Read `DBriefApp.swift` and confirm `RecordingManager` is passed via `.environment()` to the view hierarchy. If not, it needs to be added.

If RecordingManager is not directly in the environment (it may be accessed through AppContext), the RecordingHistoryView approach in Task 5 may need adjustment — either pass it through the environment or access it via AppContext.

**Step 2: Build and run**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

If there's a compile error about RecordingManager not being in the environment, adjust the approach: either inject it or access it via the existing AppContext environment object.
