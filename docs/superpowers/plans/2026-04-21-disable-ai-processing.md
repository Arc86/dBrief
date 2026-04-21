# Disable AI Processing Toggle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a global `aiProcessingEnabled` toggle to AppSettings that, when off, hides AI options in PostRecordingSheet and skips all AI pipeline steps in RecordingManager.

**Architecture:** Single boolean in AppSettings persisted to UserDefaults; PostRecordingSheet reads it to conditionally render the AI section; RecordingManager guards the AI block and preflight check behind it; SettingsAITab exposes the toggle above the engine picker.

**Tech Stack:** Swift 6.2, SwiftUI, `@Observable`, UserDefaults, swift-testing

---

## File Map

| File | Change |
|------|--------|
| `Sources/dBrief/App/AppSettings.swift` | Add `aiProcessingEnabled` key + property + init line |
| `Sources/dBrief/UI/SettingsAITab.swift` | Add toggle at top of AI Analysis tab |
| `Sources/dBrief/UI/PostRecordingSheet.swift` | Conditionally hide AI options section |
| `Sources/dBrief/Services/RecordingManager.swift` | Guard AI block and preflight in `processRecording` and `reprocessRecording` |
| `Tests/dBriefTests/AppSettingsTests.swift` | New file — default value test |

---

### Task 1: AppSettings — add `aiProcessingEnabled`

**Files:**
- Modify: `Sources/dBrief/App/AppSettings.swift:16`, `:123`, `:523`
- Create: `Tests/dBriefTests/AppSettingsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/dBriefTests/AppSettingsTests.swift`:

```swift
import Testing
@testable import dBrief

@MainActor
struct AppSettingsTests {
    @Test func aiProcessingEnabledDefaultsToTrue() {
        // Clear any persisted value so we test the real default
        UserDefaults.standard.removeObject(forKey: "aiProcessingEnabled")
        let settings = AppSettings()
        #expect(settings.aiProcessingEnabled == true)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
swift test --filter AppSettingsTests
```

Expected: compile error — `aiProcessingEnabled` does not exist yet.

- [ ] **Step 3: Add the key to the `Keys` enum**

In `Sources/dBrief/App/AppSettings.swift`, after line 16 (`static let autoTags = "autoTags"`):

```swift
        static let autoTags = "autoTags"
        static let aiProcessingEnabled = "aiProcessingEnabled"
```

- [ ] **Step 4: Add the property after the `autoTags` property (around line 123)**

After the `autoTags` block:

```swift
    var autoTags: Bool {
        didSet { UserDefaults.standard.set(autoTags, forKey: Keys.autoTags) }
    }

    var aiProcessingEnabled: Bool {
        didSet { UserDefaults.standard.set(aiProcessingEnabled, forKey: Keys.aiProcessingEnabled) }
    }
```

- [ ] **Step 5: Add the init line in `init()` after the `autoTags` init line (around line 523)**

```swift
        self.autoTags = defaults.object(forKey: Keys.autoTags) as? Bool ?? true
        self.aiProcessingEnabled = defaults.object(forKey: Keys.aiProcessingEnabled) as? Bool ?? true
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
swift test --filter AppSettingsTests
```

Expected: PASS — `aiProcessingEnabledDefaultsToTrue`

- [ ] **Step 7: Build to confirm no compile errors**

```bash
swift build
```

Expected: Build complete, 0 errors.

- [ ] **Step 8: Commit**

```bash
git add Sources/dBrief/App/AppSettings.swift Tests/dBriefTests/AppSettingsTests.swift
git commit -m "feat: add aiProcessingEnabled setting with UserDefaults persistence"
```

---

### Task 2: SettingsAITab — add toggle at top of AI Analysis tab

**Files:**
- Modify: `Sources/dBrief/UI/SettingsAITab.swift:21`

- [ ] **Step 1: Add a new section before `Section("Engine")` (around line 21)**

The current top of the `Form` body in `SettingsAITab.swift` is:

```swift
            Form {
                Section("Engine") {
                    Picker("AI engine", selection: $settings.aiEngine) {
```

Replace with:

```swift
            Form {
                Section {
                    Toggle("Enable AI processing", isOn: $settings.aiProcessingEnabled)
                    Text("When off, recordings are transcribed only — no summary, action items, or tag analysis.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Engine") {
                    Picker("AI engine", selection: $settings.aiEngine) {
```

- [ ] **Step 2: Build to confirm no compile errors**

```bash
swift build
```

Expected: Build complete, 0 errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/UI/SettingsAITab.swift
git commit -m "feat: add Enable AI processing toggle to Settings AI tab"
```

---

### Task 3: PostRecordingSheet — hide AI section when disabled

**Files:**
- Modify: `Sources/dBrief/UI/PostRecordingSheet.swift:60`

- [ ] **Step 1: Wrap the AI toggles block in a conditional**

The current block (lines 60–72) is:

```swift
            Toggle("Transcribe audio", isOn: $transcribe)
            Toggle("Generate summary", isOn: $summary)
                .disabled(!transcribe)
            Toggle("Extract action items", isOn: $actionItems)
                .disabled(!transcribe)
            Toggle("Analyze tags & sentiment", isOn: $tags)
                .disabled(!transcribe)

            if !transcribe {
                Text("Transcription is required for AI analysis.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
```

Replace with:

```swift
            Toggle("Transcribe audio", isOn: $transcribe)

            if appSettings.aiProcessingEnabled {
                Toggle("Generate summary", isOn: $summary)
                    .disabled(!transcribe)
                Toggle("Extract action items", isOn: $actionItems)
                    .disabled(!transcribe)
                Toggle("Analyze tags & sentiment", isOn: $tags)
                    .disabled(!transcribe)

                if !transcribe {
                    Text("Transcription is required for AI analysis.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("AI processing is disabled in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

- [ ] **Step 2: Build to confirm no compile errors**

```bash
swift build
```

Expected: Build complete, 0 errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/UI/PostRecordingSheet.swift
git commit -m "feat: hide AI options in PostRecordingSheet when AI processing is disabled"
```

---

### Task 4: RecordingManager — guard AI block and preflight

**Files:**
- Modify: `Sources/dBrief/Services/RecordingManager.swift:227`, `:433`

There are two methods that run AI tasks: `processRecording` (line 227) and `reprocessRecording` (line 433). Both need the same guard.

- [ ] **Step 1: Add guard in `processRecording` before the AI block (line 227)**

The current code at line 227:

```swift
        // Step 2: AI tasks (run sequentially to avoid TaskGroup @MainActor issues)
        guard !Task.isCancelled else { return }
        if let transcription = recording.transcription {
            let aiEngine = appSettings.effectiveAIEngine
```

Replace the `if let transcription` block opening with:

```swift
        // Step 2: AI tasks (run sequentially to avoid TaskGroup @MainActor issues)
        guard !Task.isCancelled else { return }
        if appSettings.aiProcessingEnabled, let transcription = recording.transcription {
            let aiEngine = appSettings.effectiveAIEngine
```

This is a one-character change: add `appSettings.aiProcessingEnabled,` as the first condition of the existing `if let`. No indentation changes needed — the block body is untouched.

- [ ] **Step 2: Add the same guard in `reprocessRecording` (around line 433)**

Find:

```swift
            // Step 2: AI tasks (same as processRecording)
            if let transcription = recording.transcription {
                let aiEngine = appSettings.effectiveAIEngine
```

Replace with:

```swift
            // Step 2: AI tasks (same as processRecording)
            if appSettings.aiProcessingEnabled, let transcription = recording.transcription {
                let aiEngine = appSettings.effectiveAIEngine
```

- [ ] **Step 3: Build to confirm no compile errors**

```bash
swift build
```

Expected: Build complete, 0 errors.

- [ ] **Step 4: Run all tests**

```bash
swift test
```

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Services/RecordingManager.swift
git commit -m "feat: skip AI block and preflight when aiProcessingEnabled is false"
```

---

## Manual Verification Checklist

After all tasks:

1. Launch app (`make run` or `swift run`)
2. Open Settings → AI tab → verify "Enable AI processing" toggle appears at the top
3. Turn the toggle **off**
4. Stop a recording → verify PostRecordingSheet shows only transcription toggle + "AI processing is disabled in Settings" note
5. Process the recording → verify no summary/action items/tags appear in the result, only transcript
6. Turn the toggle back **on** → verify PostRecordingSheet shows all AI checkboxes again with their saved defaults intact
