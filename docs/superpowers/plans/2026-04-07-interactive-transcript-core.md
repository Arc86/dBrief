# Interactive Transcript Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a rich interactive transcript window with word-level audio sync, inline editing, and starred segments, backed by a `RichTranscript` data model persisted in a `.richtranscript.json` sidecar file.

**Architecture:** `TranscriptionResult` gains an optional `words: [Word]?` field per segment that backends populate when available. `RichTranscriptBuilder` converts `TranscriptionResult → RichTranscript` after transcription. `TranscriptStore` persists it to `<recording>.richtranscript.json`. A dedicated `WindowGroup(for: UUID.self)` window renders the transcript as tappable token rows with an embedded `AudioPlayer`.

**Tech Stack:** Swift 6.2, SwiftUI, `@Observable`, `actor`, swift-testing, WhisperKit 0.9.4+, existing `AudioPlayer` (already has `currentTime` + `seek(to:)`)

---

## File Map

**Create:**
- `Sources/dBrief/Models/RichTranscript.swift` — `RichTranscript`, `RichSegment`, `RichToken`, `SpeakerLabel` models
- `Sources/dBrief/Services/TranscriptStore.swift` — actor: load/save `.richtranscript.json` sidecar
- `Sources/dBrief/Services/RichTranscriptBuilder.swift` — converts `TranscriptionResult → RichTranscript`
- `Sources/dBrief/UI/TranscriptWindowView.swift` — main transcript window: scroll, audio sync, filter
- `Sources/dBrief/UI/TranscriptSegmentRow.swift` — segment card: token flow, inline edit, star
- `Sources/dBrief/UI/TranscriptPlayerBar.swift` — audio player bar embedded in transcript window
- `Tests/dBriefTests/RichTranscriptBuilderTests.swift` — builder unit tests
- `Tests/dBriefTests/TranscriptStoreTests.swift` — store round-trip tests

**Modify:**
- `Sources/dBrief/Models/TranscriptionResult.swift` — add `Segment.words: [Word]?`
- `Sources/dBrief/Models/Recording.swift` — add `richTranscript: RichTranscript?`, `transcriptSidecarURL`
- `Sources/dBrief/Services/TranscriptionService.swift` — parse `words` array in `parseResponse`
- `Sources/dBrief/Services/WhisperKitTranscriptionService.swift` — enable `wordTimestamps`, map word data
- `Sources/dBrief/Services/RecordingManager.swift` — accept `TranscriptStore`, build+save after transcription
- `Sources/dBrief/App/DBriefApp.swift` — add `TranscriptStore` to `AppContext`, register `WindowGroup`
- `Sources/dBrief/UI/ResultsView.swift` — add "View Transcript" button
- `Sources/dBrief/UI/RecordingHistoryView.swift` — add `hasRichTranscript` to `HistoryItem`, "Transcript" chip

---

## Task 1: RichTranscript data model + TranscriptionResult extension

**Files:**
- Create: `Sources/dBrief/Models/RichTranscript.swift`
- Modify: `Sources/dBrief/Models/TranscriptionResult.swift`
- Modify: `Sources/dBrief/Models/Recording.swift`

- [ ] **Step 1: Create `RichTranscript.swift`**

```swift
// Sources/dBrief/Models/RichTranscript.swift
import Foundation

struct RichTranscript: Codable, Sendable {
    var version: Int
    var segments: [RichSegment]
    var speakerLabels: [SpeakerLabel]

    init(segments: [RichSegment] = [], speakerLabels: [SpeakerLabel] = []) {
        self.version = 1
        self.segments = segments
        self.speakerLabels = speakerLabels
    }
}

struct RichSegment: Codable, Sendable, Identifiable {
    var id: UUID
    var start: Double
    var end: Double
    var text: String
    var originalText: String
    var tokens: [RichToken]
    var speakerId: String?
    var isStarred: Bool
    var isEdited: Bool

    init(id: UUID = UUID(), start: Double, end: Double, text: String,
         tokens: [RichToken] = [], speakerId: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.originalText = text
        self.tokens = tokens
        self.speakerId = speakerId
        self.isStarred = false
        self.isEdited = false
    }
}

struct RichToken: Codable, Sendable {
    var text: String
    var start: Double?
    var end: Double?
    var isFillerWord: Bool

    init(text: String, start: Double? = nil, end: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.isFillerWord = false
    }
}

struct SpeakerLabel: Codable, Sendable {
    var id: String
    var displayName: String
}
```

- [ ] **Step 2: Extend `TranscriptionResult.Segment` with optional word-level data**

In `Sources/dBrief/Models/TranscriptionResult.swift`, replace:

```swift
    struct Segment: Codable, Sendable {
        let start: Double
        let end: Double
        let text: String
    }
```

With:

```swift
    struct Segment: Codable, Sendable {
        let start: Double
        let end: Double
        let text: String
        let words: [Word]?

        init(start: Double, end: Double, text: String, words: [Word]? = nil) {
            self.start = start
            self.end = end
            self.text = text
            self.words = words
        }

        struct Word: Codable, Sendable {
            let word: String
            let start: Double
            let end: Double
        }
    }
```

- [ ] **Step 3: Add `richTranscript` and `transcriptSidecarURL` to `Recording`**

In `Sources/dBrief/Models/Recording.swift`, add after `var transcriptURL: URL?`:

```swift
    var richTranscript: RichTranscript?
```

Add this computed property after `var fileName`:

```swift
    var transcriptSidecarURL: URL? {
        guard let base = finalizedAudioURL else { return nil }
        return base.deletingPathExtension().appendingPathExtension("richtranscript.json")
    }
```

- [ ] **Step 4: Build and verify it compiles**

```bash
swift build 2>&1 | grep -E "error:|warning:" | head -20
```

Expected: no errors. Warnings about unused properties are fine.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Models/RichTranscript.swift \
        Sources/dBrief/Models/TranscriptionResult.swift \
        Sources/dBrief/Models/Recording.swift
git commit -m "feat: add RichTranscript model and extend TranscriptionResult with word timestamps"
```

---

## Task 2: TranscriptStore actor

**Files:**
- Create: `Sources/dBrief/Services/TranscriptStore.swift`
- Create: `Tests/dBriefTests/TranscriptStoreTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/dBriefTests/TranscriptStoreTests.swift
import Testing
import Foundation
@testable import dBrief

@Suite("TranscriptStore")
struct TranscriptStoreTests {
    @Test("round-trips RichTranscript to a temp file")
    func roundTrip() async throws {
        let store = TranscriptStore()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let audioURL = dir.appendingPathComponent("test.flac")
        let sidecarURL = dir.appendingPathComponent("test.richtranscript.json")

        let original = RichTranscript(segments: [
            RichSegment(start: 0, end: 1.5, text: "Hello world",
                        tokens: [RichToken(text: "Hello", start: 0, end: 0.5),
                                 RichToken(text: "world", start: 0.6, end: 1.5)])
        ])

        try await store.save(original, to: sidecarURL)
        let loaded = try await store.load(from: sidecarURL)

        #expect(loaded.version == 1)
        #expect(loaded.segments.count == 1)
        #expect(loaded.segments[0].text == "Hello world")
        #expect(loaded.segments[0].tokens.count == 2)
        #expect(loaded.segments[0].tokens[0].start == 0)
    }

    @Test("load throws when file is missing")
    func loadMissing() async {
        let store = TranscriptStore()
        let missing = URL(fileURLWithPath: "/nonexistent/path.richtranscript.json")
        await #expect(throws: (any Error).self) {
            _ = try await store.load(from: missing)
        }
    }

    @Test("schema version field is preserved")
    func versionPreserved() async throws {
        let store = TranscriptStore()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptStoreVersionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sidecarURL = dir.appendingPathComponent("test.richtranscript.json")
        let transcript = RichTranscript()
        try await store.save(transcript, to: sidecarURL)
        let loaded = try await store.load(from: sidecarURL)
        #expect(loaded.version == 1)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift test --filter TranscriptStoreTests 2>&1 | tail -10
```

Expected: compile error — `TranscriptStore` not defined yet.

- [ ] **Step 3: Implement `TranscriptStore`**

```swift
// Sources/dBrief/Services/TranscriptStore.swift
import Foundation
import os

actor TranscriptStore {
    private let log = Logger.recording

    func load(from url: URL) async throws -> RichTranscript {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RichTranscript.self, from: data)
    }

    func save(_ transcript: RichTranscript, to url: URL) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(transcript)
        try data.write(to: url, options: .atomic)
        log.debug("Saved rich transcript to \(url.lastPathComponent, privacy: .public)")
    }

    /// Convenience: load using Recording's computed sidecar URL.
    func load(for recording: Recording) async throws -> RichTranscript {
        guard let url = await MainActor.run(body: { recording.transcriptSidecarURL }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try await load(from: url)
    }

    /// Convenience: save using Recording's computed sidecar URL.
    func save(_ transcript: RichTranscript, for recording: Recording) async throws {
        guard let url = await MainActor.run(body: { recording.transcriptSidecarURL }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try await save(transcript, to: url)
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter TranscriptStoreTests 2>&1 | tail -10
```

Expected: `Test run with 3 tests passed.`

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Services/TranscriptStore.swift \
        Tests/dBriefTests/TranscriptStoreTests.swift
git commit -m "feat: add TranscriptStore actor for richtranscript.json sidecar persistence"
```

---

## Task 3: RichTranscriptBuilder

**Files:**
- Create: `Sources/dBrief/Services/RichTranscriptBuilder.swift`
- Create: `Tests/dBriefTests/RichTranscriptBuilderTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/dBriefTests/RichTranscriptBuilderTests.swift
import Testing
@testable import dBrief

@Suite("RichTranscriptBuilder")
struct RichTranscriptBuilderTests {
    let builder = RichTranscriptBuilder()

    @Test("segments without word timestamps produce empty tokens")
    func noWordTimestamps() {
        let result = TranscriptionResult(
            text: "Hello world",
            segments: [
                .init(start: 0, end: 2, text: "Hello world")
            ]
        )
        let rich = builder.build(from: result)
        #expect(rich.segments.count == 1)
        #expect(rich.segments[0].tokens.isEmpty)
        #expect(rich.segments[0].text == "Hello world")
        #expect(rich.segments[0].originalText == "Hello world")
        #expect(rich.segments[0].isStarred == false)
        #expect(rich.segments[0].isEdited == false)
    }

    @Test("segments with word timestamps populate tokens")
    func withWordTimestamps() {
        let result = TranscriptionResult(
            text: "Hello world",
            segments: [
                .init(start: 0, end: 2, text: "Hello world", words: [
                    .init(word: "Hello", start: 0.0, end: 0.5),
                    .init(word: "world", start: 0.6, end: 1.8)
                ])
            ]
        )
        let rich = builder.build(from: result)
        #expect(rich.segments[0].tokens.count == 2)
        #expect(rich.segments[0].tokens[0].text == "Hello")
        #expect(rich.segments[0].tokens[0].start == 0.0)
        #expect(rich.segments[0].tokens[0].end == 0.5)
        #expect(rich.segments[0].tokens[1].text == "world")
    }

    @Test("originalText matches input text and is never overwritten")
    func originalTextPreserved() {
        let result = TranscriptionResult(
            text: "Some text",
            segments: [.init(start: 0, end: 1, text: "Some text")]
        )
        let rich = builder.build(from: result)
        #expect(rich.segments[0].originalText == "Some text")
        #expect(rich.segments[0].text == "Some text")
    }

    @Test("isFillerWord defaults to false for all tokens")
    func fillerWordDefault() {
        let result = TranscriptionResult(
            text: "Um okay",
            segments: [
                .init(start: 0, end: 1, text: "Um okay", words: [
                    .init(word: "Um", start: 0, end: 0.3),
                    .init(word: "okay", start: 0.4, end: 0.9)
                ])
            ]
        )
        let rich = builder.build(from: result)
        #expect(rich.segments[0].tokens.allSatisfy { !$0.isFillerWord })
    }

    @Test("empty segments input produces empty rich transcript")
    func emptyInput() {
        let result = TranscriptionResult(text: "", segments: [])
        let rich = builder.build(from: result)
        #expect(rich.segments.isEmpty)
        #expect(rich.speakerLabels.isEmpty)
        #expect(rich.version == 1)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift test --filter RichTranscriptBuilderTests 2>&1 | tail -10
```

Expected: compile error — `RichTranscriptBuilder` not defined yet.

- [ ] **Step 3: Implement `RichTranscriptBuilder`**

```swift
// Sources/dBrief/Services/RichTranscriptBuilder.swift
import Foundation

struct RichTranscriptBuilder {
    func build(from result: TranscriptionResult) -> RichTranscript {
        let segments = result.segments.map { seg -> RichSegment in
            let tokens: [RichToken] = seg.words.map { words in
                words.map { RichToken(text: $0.word, start: $0.start, end: $0.end) }
            } ?? []
            return RichSegment(
                start: seg.start,
                end: seg.end,
                text: seg.text,
                tokens: tokens
            )
        }
        return RichTranscript(segments: segments)
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter RichTranscriptBuilderTests 2>&1 | tail -10
```

Expected: `Test run with 5 tests passed.`

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Services/RichTranscriptBuilder.swift \
        Tests/dBriefTests/RichTranscriptBuilderTests.swift
git commit -m "feat: add RichTranscriptBuilder — converts TranscriptionResult to RichTranscript"
```

---

## Task 4: Word timestamps from remote TranscriptionService

**Files:**
- Modify: `Sources/dBrief/Services/TranscriptionService.swift` (`parseResponse` function at line ~537)

- [ ] **Step 1: Update `parseResponse` to map `words` from verbose JSON response**

Find the `parseResponse` function (around line 537). Replace the segment-parsing block:

```swift
        var segments: [TranscriptionResult.Segment] = []
        if let rawSegments = json["segments"] as? [[String: Any]] {
            for seg in rawSegments {
                let start = normalizeTimestamp(seg["start"])
                let end = normalizeTimestamp(seg["end"])
                let segText = seg["text"] as? String ?? ""
                segments.append(.init(start: start, end: end, text: segText))
            }
        }
```

Replace with:

```swift
        var segments: [TranscriptionResult.Segment] = []
        if let rawSegments = json["segments"] as? [[String: Any]] {
            for seg in rawSegments {
                let start = normalizeTimestamp(seg["start"])
                let end = normalizeTimestamp(seg["end"])
                let segText = seg["text"] as? String ?? ""
                let words: [TranscriptionResult.Segment.Word]? = {
                    guard let rawWords = seg["words"] as? [[String: Any]], !rawWords.isEmpty else {
                        return nil
                    }
                    return rawWords.compactMap { w -> TranscriptionResult.Segment.Word? in
                        guard let wordText = w["word"] as? String else { return nil }
                        let wStart = normalizeTimestamp(w["start"])
                        let wEnd = normalizeTimestamp(w["end"])
                        return .init(word: wordText, start: wStart, end: wEnd)
                    }
                }()
                segments.append(.init(start: start, end: end, text: segText, words: words))
            }
        }
```

- [ ] **Step 2: Build to verify no errors**

```bash
swift build 2>&1 | grep "error:" | head -10
```

Expected: no errors.

- [ ] **Step 3: Run all tests**

```bash
swift test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/dBrief/Services/TranscriptionService.swift
git commit -m "feat: parse word-level timestamps from verbose JSON transcription response"
```

---

## Task 5: Word timestamps from WhisperKit

**Files:**
- Modify: `Sources/dBrief/Services/WhisperKitTranscriptionService.swift`

- [ ] **Step 1: Enable word timestamps in `DecodingOptions` and map word data**

In `WhisperKitTranscriptionService.transcribe`, find the options block:

```swift
        var options = DecodingOptions()
        options.language = nil
        options.detectLanguage = true
        options.task = .transcribe
        options.promptTokens = promptTokens.isEmpty ? nil : promptTokens
        options.concurrentWorkerCount = 1
        options.temperature = 0
        options.skipSpecialTokens = true
        options.withoutTimestamps = false
```

Add `options.wordTimestamps = true` after `options.withoutTimestamps = false`:

```swift
        options.withoutTimestamps = false
        options.wordTimestamps = true
```

- [ ] **Step 2: Map WhisperKit word timings to `TranscriptionResult.Segment.Word`**

Find the segment mapping block (around line 56):

```swift
            let mappedSegments = wkResults.flatMap { result in
                result.segments.map {
                    TranscriptionResult.Segment(
                        start: Double($0.start),
                        end: Double($0.end),
                        text: cleanTranscriptArtifacts($0.text)
                    )
                }
            }
```

Replace with:

```swift
            let mappedSegments = wkResults.flatMap { result in
                result.segments.map { seg -> TranscriptionResult.Segment in
                    let words: [TranscriptionResult.Segment.Word]? = seg.words.flatMap { wt -> [TranscriptionResult.Segment.Word]? in
                        let mapped = wt.map {
                            TranscriptionResult.Segment.Word(
                                word: $0.word,
                                start: Double($0.start),
                                end: Double($0.end)
                            )
                        }
                        return mapped.isEmpty ? nil : mapped
                    }
                    return TranscriptionResult.Segment(
                        start: Double(seg.start),
                        end: Double(seg.end),
                        text: cleanTranscriptArtifacts(seg.text),
                        words: words
                    )
                }
            }
```

Note: `WhisperKit.TranscriptionSegment.words` is `[WordTiming]?` where `WordTiming` has `.word: String`, `.start: Float`, `.end: Float`. If the compiler reports that `words` or `WordTiming` doesn't exist, check the installed WhisperKit version's public API and adjust the property name accordingly (it may be `wordTimings`).

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | grep "error:" | head -10
```

Expected: no errors. If WhisperKit doesn't expose `words` on `TranscriptionSegment`, remove the `wordTimestamps` option and the word mapping — the builder will leave tokens empty for WhisperKit transcriptions, which is acceptable (segment-level sync still works).

- [ ] **Step 4: Commit**

```bash
git add Sources/dBrief/Services/WhisperKitTranscriptionService.swift
git commit -m "feat: map WhisperKit word-level timestamps to TranscriptionResult.Segment.words"
```

---

## Task 6: Wire builder into RecordingManager + AppContext

**Files:**
- Modify: `Sources/dBrief/Services/RecordingManager.swift`
- Modify: `Sources/dBrief/App/DBriefApp.swift`

- [ ] **Step 1: Add `TranscriptStore` to `AppContext` in `DBriefApp.swift`**

In `AppContext`, add after `let audioPlayer = AudioPlayer()`:

```swift
    let transcriptStore = TranscriptStore()
```

- [ ] **Step 2: Add `TranscriptStore` parameter to `RecordingManager.init`**

In `RecordingManager`, add the stored property after `private let recordingFinalizer = RecordingFinalizer()`:

```swift
    private let transcriptStore: TranscriptStore
```

Replace the existing `init`:

```swift
    init(appState: AppState, appSettings: AppSettings) {
        self.appState = appState
        self.appSettings = appSettings
    }
```

With:

```swift
    init(appState: AppState, appSettings: AppSettings, transcriptStore: TranscriptStore) {
        self.appState = appState
        self.appSettings = appSettings
        self.transcriptStore = transcriptStore
    }
```

- [ ] **Step 3: Update `AppContext` to pass `transcriptStore` to `RecordingManager`**

In `AppContext.init()`, replace:

```swift
        self.recordingManager = RecordingManager(appState: appState, appSettings: appSettings)
```

With:

```swift
        self.recordingManager = RecordingManager(appState: appState, appSettings: appSettings, transcriptStore: transcriptStore)
```

- [ ] **Step 4: Build the `transcriptStore` property before `recordingManager` is used**

Since `transcriptStore` is a `let` on `AppContext` and `RecordingManager` is initialized in `init()`, the order matters. Ensure `transcriptStore` is declared before `recordingManager` in `AppContext`:

```swift
@MainActor
@Observable
final class AppContext {
    let appState = AppState()
    let appSettings = AppSettings()
    let transcriptStore = TranscriptStore()   // ← must be before recordingManager
    let recordingManager: RecordingManager
    // ... rest unchanged
```

- [ ] **Step 5: Build and find the spot in `RecordingManager` to insert the builder call**

```bash
swift build 2>&1 | grep "error:" | head -10
```

Expected: no errors.

- [ ] **Step 6: Call builder after transcription in `RecordingManager`**

In `RecordingManager`, find the block just after Step 1 (Transcription) completes, before Step 2 (AI tasks). This is after line `appState.processingSteps[stepIndex].status = .completed` inside the transcription else-branch, around line 212. Add this block after the closing brace of the `if transcribe { ... }` block and before `// Step 2: AI tasks`:

```swift
        // Build and persist rich transcript sidecar
        if let transcription = recording.transcription,
           let sidecarURL = recording.transcriptSidecarURL {
            let rich = RichTranscriptBuilder().build(from: transcription)
            recording.richTranscript = rich
            Task.detached { [transcriptStore, rich] in
                try? await transcriptStore.save(rich, to: sidecarURL)
            }
        }
```

Note: `Task.detached` avoids blocking the main pipeline on disk I/O. The `try?` suppresses errors silently — `Logger.recording` catches them inside `TranscriptStore.save`.

- [ ] **Step 7: Build and run all tests**

```bash
swift build 2>&1 | grep "error:" | head -10
swift test 2>&1 | tail -5
```

Expected: no errors, all tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/dBrief/Services/RecordingManager.swift \
        Sources/dBrief/App/DBriefApp.swift
git commit -m "feat: build and persist RichTranscript after transcription completes"
```

---

## Task 7: Register transcript window in DBriefApp

**Files:**
- Modify: `Sources/dBrief/App/DBriefApp.swift`
- Create: `Sources/dBrief/UI/TranscriptWindowView.swift` (scaffold only — full implementation in Task 10)

- [ ] **Step 1: Add `recording(for:)` helper and `recentRecordings` to `AppState`**

In `Sources/dBrief/App/AppState.swift`, add a stored property and helper method:

```swift
    var recentRecordings: [Recording] = []   // populated by history chip before opening window

    func recording(for id: UUID) -> Recording? {
        if currentRecording?.id == id { return currentRecording }
        return recentRecordings.first { $0.id == id }
    }
```

- [ ] **Step 2: Create scaffold `TranscriptWindowView`**

```swift
// Sources/dBrief/UI/TranscriptWindowView.swift
import SwiftUI

struct TranscriptWindowView: View {
    let recordingId: UUID
    @Environment(AppState.self) private var appState
    @Environment(AppContext.self) private var context

    var body: some View {
        if let recording = appState.recording(for: recordingId) {
            Text("Transcript for \(recording.meetingTitleDraft)")
                .padding()
        } else {
            Text("Recording not found")
                .foregroundStyle(.secondary)
                .padding()
        }
    }
}
```

- [ ] **Step 3: Register the `WindowGroup` in `DBriefApp`**

`AppContext` is `@MainActor @Observable` and is already available as `@State private var context` in `DBriefApp`. In `DBriefApp.body`, after the existing `WindowGroup(id: "settings") { ... }` block, add:

```swift
        WindowGroup(for: UUID.self) { $id in
            if let id {
                TranscriptWindowView(recordingId: id)
                    .environment(context.appState)
                    .environment(context.audioPlayer)
                    .environment(context)       // AppContext carries transcriptStore
                    .frame(minWidth: 700, minHeight: 500)
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 880, height: 620)
```

Note: `AppContext` is passed as a whole so `TranscriptWindowView` can reach `context.transcriptStore` (an `actor`) without needing a separate environment key.

- [ ] **Step 4: Build**

```bash
swift build 2>&1 | grep "error:" | head -15
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/UI/TranscriptWindowView.swift \
        Sources/dBrief/App/DBriefApp.swift \
        Sources/dBrief/App/AppState.swift
git commit -m "feat: scaffold transcript window and register WindowGroup(for: UUID.self)"
```

---

## Task 8: TranscriptPlayerBar

**Files:**
- Create: `Sources/dBrief/UI/TranscriptPlayerBar.swift`

- [ ] **Step 1: Create `TranscriptPlayerBar`**

```swift
// Sources/dBrief/UI/TranscriptPlayerBar.swift
import SwiftUI

struct TranscriptPlayerBar: View {
    let audioURL: URL?
    @Environment(AudioPlayer.self) private var audioPlayer

    var body: some View {
        HStack(spacing: 12) {
            // Play / Pause button
            Button {
                if let url = audioURL {
                    audioPlayer.togglePlayPause(url: url)
                }
            } label: {
                Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(audioURL == nil ? .tertiary : .blue)
            }
            .buttonStyle(.plain)
            .disabled(audioURL == nil)

            // Scrubber
            VStack(alignment: .leading, spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.quaternary).clipShape(Capsule())
                        Rectangle()
                            .fill(.blue)
                            .frame(width: scrubberFill(width: geo.size.width))
                            .clipShape(Capsule())
                    }
                    .frame(height: 4)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard audioPlayer.duration > 0 else { return }
                                let fraction = max(0, min(1, value.location.x / geo.size.width))
                                audioPlayer.seek(to: audioPlayer.duration * fraction)
                            }
                    )
                }
                .frame(height: 4)

                HStack {
                    Text(audioPlayer.formattedCurrentTime)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(audioPlayer.formattedDuration)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private func scrubberFill(width: CGFloat) -> CGFloat {
        guard audioPlayer.duration > 0 else { return 0 }
        return width * (audioPlayer.currentTime / audioPlayer.duration)
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | grep "error:" | head -10
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/UI/TranscriptPlayerBar.swift
git commit -m "feat: add TranscriptPlayerBar with scrubber and seek support"
```

---

## Task 9: TranscriptSegmentRow

**Files:**
- Create: `Sources/dBrief/UI/TranscriptSegmentRow.swift`

- [ ] **Step 1: Create `TranscriptSegmentRow`**

```swift
// Sources/dBrief/UI/TranscriptSegmentRow.swift
import SwiftUI

struct TranscriptSegmentRow: View {
    @Binding var segment: RichSegment
    let activeSegmentId: UUID?
    let activeTokenIndex: Int?
    let onSeek: (Double) -> Void
    let onSave: () -> Void

    @State private var isEditing = false
    @State private var editBuffer = ""
    @State private var isHovered = false
    @State private var saveDebounceTask: Task<Void, Never>?

    private var isPlaying: Bool { activeSegmentId == segment.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                // Speaker badge (placeholder until Sub-project 2)
                Text("Speaker")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.fill)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.secondary)

                // Timestamp seek button
                Button {
                    onSeek(segment.start)
                } label: {
                    Text(formatTimestamp(segment.start))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                if isHovered || isEditing {
                    // Star toggle
                    Button {
                        segment.isStarred.toggle()
                        scheduleSave()
                    } label: {
                        Image(systemName: segment.isStarred ? "star.fill" : "star")
                            .font(.caption)
                            .foregroundStyle(segment.isStarred ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)

                    // Edit toggle
                    Button {
                        if isEditing {
                            commitEdit()
                        } else {
                            startEdit()
                        }
                    } label: {
                        Image(systemName: isEditing ? "checkmark" : "pencil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Body
            if isEditing {
                editingBody
            } else {
                displayBody
            }
        }
        .padding(.bottom, 8)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { isHovered = $0 }
        .onKeyPress(.escape) {
            if isEditing { cancelEdit(); return .handled }
            return .ignored
        }
    }

    // MARK: - Display mode

    private var displayBody: some View {
        Group {
            if segment.tokens.isEmpty {
                // Segment-level display (no word timestamps)
                Button {
                    onSeek(segment.start)
                } label: {
                    Text(segment.text)
                        .font(.callout)
                        .foregroundStyle(isPlaying ? .primary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
            } else {
                // Token-level display
                tokenFlow
                    .padding(.horizontal, 10)
            }
        }
    }

    private var tokenFlow: some View {
        // Wrap tokens using a simple flowing layout via Text concatenation
        // Tokens are rendered as an AttributedString with tappable regions via overlay
        ZStack(alignment: .topLeading) {
            // Visible text with highlights
            tokenText
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
    }

    private var tokenText: Text {
        segment.tokens.indices.reduce(Text("")) { result, i in
            let token = segment.tokens[i]
            let isActive = isPlaying && activeTokenIndex == i
            let base = Text(token.text + (i < segment.tokens.count - 1 ? " " : ""))
            if isActive {
                return result + base.bold().foregroundStyle(Color.accentColor)
            }
            return result + base
        }
    }

    // MARK: - Edit mode

    private var editingBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $editBuffer)
                .font(.callout)
                .frame(minHeight: 48)
                .padding(6)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1))
                .onChange(of: editBuffer) { _, _ in scheduleSave() }

            Text("Press Esc to cancel · Changes auto-saved")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
    }

    // MARK: - Background

    private var rowBackground: some ShapeStyle {
        if isPlaying && segment.isStarred {
            return AnyShapeStyle(Color.accentColor.opacity(0.1))
        } else if isPlaying {
            return AnyShapeStyle(Color.accentColor.opacity(0.08))
        } else if segment.isStarred {
            return AnyShapeStyle(Color.yellow.opacity(0.07))
        } else {
            return AnyShapeStyle(Color.primary.opacity(0.04))
        }
    }

    // MARK: - Edit helpers

    private func startEdit() {
        editBuffer = segment.text
        isEditing = true
    }

    private func commitEdit() {
        let trimmed = editBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { cancelEdit(); return }
        segment.text = trimmed
        segment.isEdited = true
        segment.tokens = []  // word timestamps no longer match edited text
        isEditing = false
        saveDebounceTask?.cancel()
        onSave()
    }

    private func cancelEdit() {
        isEditing = false
        saveDebounceTask?.cancel()
    }

    private func scheduleSave() {
        guard !isEditing else { return }   // editing commits on checkmark/Esc only
        saveDebounceTask?.cancel()
        saveDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            onSave()
        }
    }

    // MARK: - Helpers

    private func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | grep "error:" | head -10
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/UI/TranscriptSegmentRow.swift
git commit -m "feat: add TranscriptSegmentRow with token display, inline editing, and star toggle"
```

---

## Task 10: TranscriptWindowView — full implementation

**Files:**
- Modify: `Sources/dBrief/UI/TranscriptWindowView.swift`

Note: `AppState.recentRecordings` and `AppState.recording(for:)` were already added in Task 7.

- [ ] **Step 1: Replace the scaffold with the full `TranscriptWindowView`**

```swift
// Sources/dBrief/UI/TranscriptWindowView.swift
import SwiftUI

struct TranscriptWindowView: View {
    let recordingId: UUID
    @Environment(AppState.self) private var appState
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(AppContext.self) private var context

    @State private var richTranscript: RichTranscript?
    @State private var showStarredOnly = false
    @State private var isLoadingFromDisk = false
    @State private var loadError = false

    private var recording: Recording? { appState.recording(for: recordingId) }

    private var visibleSegments: [RichSegment] {
        guard let rich = richTranscript else { return [] }
        return showStarredOnly ? rich.segments.filter(\.isStarred) : rich.segments
    }

    // Audio sync: segment whose time range contains currentTime
    private var activeSegmentId: UUID? {
        guard let rich = richTranscript else { return nil }
        return rich.segments.first { $0.start <= audioPlayer.currentTime && audioPlayer.currentTime < $0.end }?.id
    }

    // Audio sync: active token index within the active segment
    private var activeTokenIndex: Int? {
        guard let segId = activeSegmentId,
              let seg = richTranscript?.segments.first(where: { $0.id == segId }),
              !seg.tokens.isEmpty
        else { return nil }
        return seg.tokens.indices.first { i in
            let t = seg.tokens[i]
            guard let start = t.start, let end = t.end else { return false }
            return start <= audioPlayer.currentTime && audioPlayer.currentTime < end
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Button {
                    showStarredOnly = false
                } label: {
                    Text("All")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(showStarredOnly ? Color.clear : Color.accentColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Button {
                    showStarredOnly = true
                } label: {
                    Label("Starred", systemImage: "star.fill")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(showStarredOnly ? Color.yellow.opacity(0.15) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // Transcript body
            Group {
                if isLoadingFromDisk {
                    ProgressView("Loading transcript…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if loadError {
                    emptyState
                } else if richTranscript == nil {
                    Text("No transcript available.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    transcriptScroll
                }
            }

            Divider()

            // Audio player
            TranscriptPlayerBar(audioURL: recording?.finalizedAudioURL)
        }
        .navigationTitle(recording?.generatedTitle ?? recording?.meetingTitleDraft ?? "Transcript")
        .task {
            await loadTranscript()
        }
    }

    // MARK: - Transcript scroll

    @ViewBuilder
    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(visibleSegments.indices, id: \.self) { i in
                        if let idx = richTranscript?.segments.firstIndex(where: { $0.id == visibleSegments[i].id }) {
                            TranscriptSegmentRow(
                                segment: Binding(
                                    get: { richTranscript!.segments[idx] },
                                    set: { richTranscript!.segments[idx] = $0 }
                                ),
                                activeSegmentId: activeSegmentId,
                                activeTokenIndex: activeTokenIndex,
                                onSeek: { audioPlayer.seek(to: $0) },
                                onSave: { saveTranscript() }
                            )
                            .id(visibleSegments[i].id)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: activeSegmentId) { _, newId in
                if let id = newId {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Transcript unavailable")
                .font(.headline)
            Text("The sidecar file could not be loaded.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let recording, recording.transcription != nil {
                Button("Rebuild Transcript") {
                    rebuildTranscript(for: recording)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Persistence

    private func loadTranscript() async {
        // Use in-memory cache first
        if let rec = recording, let cached = rec.richTranscript {
            richTranscript = cached
            return
        }
        // Fall back to disk
        guard let rec = recording,
              let sidecarURL = rec.transcriptSidecarURL else { return }
        isLoadingFromDisk = true
        do {
            let loaded = try await context.transcriptStore.load(from: sidecarURL)
            richTranscript = loaded
            rec.richTranscript = loaded
        } catch {
            loadError = rec.transcription == nil  // error only if no way to rebuild
        }
        isLoadingFromDisk = false
    }

    private func saveTranscript() {
        guard let sidecarURL = recording?.transcriptSidecarURL,
              let rich = richTranscript else { return }
        // Capture value types and URL — Recording is @MainActor and cannot be captured in detached task
        let store = context.transcriptStore
        Task.detached {
            try? await store.save(rich, to: sidecarURL)
        }
    }

    private func rebuildTranscript(for recording: Recording) {
        guard let transcription = recording.transcription,
              let sidecarURL = recording.transcriptSidecarURL else { return }
        let rebuilt = RichTranscriptBuilder().build(from: transcription)
        richTranscript = rebuilt
        recording.richTranscript = rebuilt
        loadError = false
        let store = context.transcriptStore
        Task.detached {
            try? await store.save(rebuilt, to: sidecarURL)
        }
    }
}
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | grep "error:" | head -15
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/dBrief/UI/TranscriptWindowView.swift \
        Sources/dBrief/App/AppState.swift
git commit -m "feat: implement full TranscriptWindowView with audio sync, filter, and edit persistence"
```

---

## Task 11: Entry points — ResultsView + RecordingHistoryView

**Files:**
- Modify: `Sources/dBrief/UI/ResultsView.swift`
- Modify: `Sources/dBrief/UI/RecordingHistoryView.swift`

- [ ] **Step 1: Add "View Transcript" button to `ResultsView`**

`ResultsView` already has `@Environment(\.openWindow) var openWindow` at the top of `MenuBarView`. Add it to `ResultsView` too.

In `ResultsView`, add the environment property after the existing `@Environment` declarations:

```swift
    @Environment(\.openWindow) private var openWindow
```

In the `actionBar(recording:)` function, add a "View Transcript" button before the `Spacer()`:

```swift
    private func actionBar(recording: Recording) -> some View {
        HStack(spacing: 6) {
            Button(copied ? "Copied!" : "Copy Notes") {
                copyNotes(recording: recording)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(recording.transcription == nil && recording.summary == nil)

            if recording.richTranscript != nil {
                Button("View Transcript") {
                    openWindow(value: recording.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()
            // ... rest of existing buttons unchanged
```

- [ ] **Step 2: Add `hasRichTranscript` to `RecordingHistoryView.HistoryItem`**

In `RecordingHistoryView.HistoryItem`, add:

```swift
        let hasRichTranscript: Bool
```

In `loadRecordings()`, update the `HistoryItem` initialiser to check for the `.richtranscript.json` sidecar:

```swift
        recordings = Array(all.prefix(20)).map { entry in
            let base = entry.url.deletingPathExtension()
            let transcriptURL = base.appendingPathExtension("transcript.json")
            let hasTranscript = FileManager.default.fileExists(atPath: transcriptURL.path)
            let richtranscriptURL = base.appendingPathExtension("richtranscript.json")
            let hasRichTranscript = FileManager.default.fileExists(atPath: richtranscriptURL.path)

            // ... duration loading unchanged ...

            return HistoryItem(
                url: entry.url,
                name: base.lastPathComponent,
                date: entry.createdAt,
                size: entry.size,
                duration: duration,
                profileName: nil,
                hasTranscript: hasTranscript,
                hasRichTranscript: hasRichTranscript
            )
        }
```

Also update `deleteItem` to delete the new sidecar alongside existing files:

```swift
    private func deleteItem(_ item: HistoryItem) {
        let base = item.url.deletingPathExtension()
        let candidates = [
            item.url,
            base.appendingPathExtension("md"),
            base.appendingPathExtension("transcript.json"),
            base.appendingPathExtension("richtranscript.json"),   // ← add this
            base.appendingPathExtension("json"),
        ]
        for url in candidates {
            try? FileManager.default.removeItem(at: url)
        }
        recordings.removeAll { $0.id == item.id }
        if expandedItemId == item.id { expandedItemId = nil }
    }
```

- [ ] **Step 3: Add `openWindow` environment and "Transcript" chip to history**

Add `@Environment(\.openWindow) private var openWindow` to `RecordingHistoryView`.

In the expanded action chips block (around line 146), add a "Transcript" chip after the "Re-run AI" chip:

```swift
                    if item.hasRichTranscript {
                        actionChip(title: "Transcript", systemImage: "text.quote") {
                            // Build a minimal Recording to store in appState for the window
                            let rec = Recording(
                                fileURL: item.url,
                                duration: item.duration,
                                fileSize: item.size,
                                meetingTitleDraft: item.name,
                                finalizedAudioURL: item.url
                            )
                            appState.recentRecordings.append(rec)
                            openWindow(value: rec.id)
                        }
                    }
```

Also add `@Environment(AppState.self) private var appState` to `RecordingHistoryView` (it currently only has `AppSettings` and `AudioPlayer`).

- [ ] **Step 4: Build**

```bash
swift build 2>&1 | grep "error:" | head -15
```

Expected: no errors.

- [ ] **Step 5: Run all tests**

```bash
swift test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/dBrief/UI/ResultsView.swift \
        Sources/dBrief/UI/RecordingHistoryView.swift
git commit -m "feat: add View Transcript entry points in ResultsView and RecordingHistoryView"
```

---

## Task 12: Smoke test and cleanup

- [ ] **Step 1: Build release**

```bash
swift build -c release 2>&1 | grep "error:" | head -10
```

Expected: no errors.

- [ ] **Step 2: Run full test suite**

```bash
swift test 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 3: Manual smoke test checklist**

1. Record a short audio clip and process it with a remote Whisper endpoint that supports `verbose_json`. Verify `*.richtranscript.json` appears in the recordings folder.
2. Open the transcript window from "View Transcript" in the results view. Verify segments appear.
3. Click play — verify the active segment gets highlighted and the scrubber advances.
4. Click a timestamp label — verify audio seeks to that position.
5. Hover a segment — verify star and edit buttons appear.
6. Click ✎, edit text, press checkmark — verify the change persists after closing and reopening the window.
7. Click ☆ on a segment — verify it turns gold and the "Starred" filter shows only that segment.
8. Open the history list, expand a past recording that has a `.richtranscript.json` sidecar — verify the "Transcript" chip appears and opens the window.

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "feat: complete interactive transcript core — window, audio sync, editing, stars"
```
