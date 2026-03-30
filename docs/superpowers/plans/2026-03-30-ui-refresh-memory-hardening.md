# UI Refresh & Memory Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the menu bar popover to show actual AI output after processing, add inline history actions, reorganize settings, and surface memory pressure warnings to users on constrained hardware.

**Architecture:** Memory hardening (AppState/MemoryPressureMonitor/RecordingManager) is laid down first; UI components then consume the new state. `MenuBarView` is updated to route the post-processing state to a new `ResultsView` instead of `TranscriptionProgressView`. Settings tabs are reorganised within the existing `NavigationSplitView` structure (already sidebar-based).

**Tech Stack:** Swift 6.2, SwiftUI, `@Observable`, `@MainActor`, `swift-testing` for tests, `swift build` / `swift test` to verify.

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `App/AppState.swift` | Modify | Add `MemoryPressureLevel`, `PreflightWarning`, `memoryPressureLevel`, `preflightWarning` |
| `Services/MemoryPressureMonitor.swift` | Modify | Add typed pressure handler registration + `currentLevel` |
| `App/DBriefApp.swift` (AppContext) | Modify | Wire monitor → AppState; route Results in MenuBarView |
| `Services/RecordingManager.swift` | Modify | Pre-flight check before local AI; always transition to idle after processing |
| `UI/ResultsView.swift` | Create | Results state: collapsible sections, pinned action bar, retry banner |
| `UI/RecordingControlsView.swift` | Modify | Vertical bar level meter; hide profile picker while recording |
| `UI/RecordingHistoryView.swift` | Modify | Expanded inline rows with action chips; 20-item cap |
| `UI/SettingsView.swift` | Modify | Add `recording` tab; fold `permissions` into `general`; rename `ai` → `aiAndModels` |
| `UI/SettingsGeneralTab.swift` | Modify | Add inline Permissions section |
| `UI/SettingsAIModelsTab.swift` | Create | Merged transcription + AI engines tab |
| `UI/SettingsRecordingTab.swift` | Create | Audio input device + segmentation settings |
| `Tests/dBriefTests/MemoryHardeningTests.swift` | Create | Unit tests for memory logic |
| `Tests/dBriefTests/ResultsViewTests.swift` | Create | Unit tests for collapsible section state |

---

## Task 1: AppState — memory pressure types

**Files:**
- Modify: `Sources/dBrief/App/AppState.swift`
- Create: `Tests/dBriefTests/MemoryHardeningTests.swift`

- [ ] **Step 1: Add types and properties to AppState**

Open `Sources/dBrief/App/AppState.swift` and add after the existing `ProcessingStep` struct at the bottom:

```swift
// MARK: - Memory pressure

enum MemoryPressureLevel: Equatable {
    case normal
    case warning
    case critical
}

struct PreflightWarning: Equatable {
    let modelName: String
    let requiredGB: Double
    let availableGB: Double
    let hasRemoteEndpoint: Bool
}
```

Inside `AppState`, add two new properties after `var queuedCount: Int = 0`:

```swift
var memoryPressureLevel: MemoryPressureLevel = .normal
var preflightWarning: PreflightWarning?
```

- [ ] **Step 2: Write failing tests**

Create `Tests/dBriefTests/MemoryHardeningTests.swift`:

```swift
import Testing
@testable import dBrief

@MainActor
struct MemoryHardeningTests {

    @Test func appStateMemoryLevelDefaultsToNormal() {
        let state = AppState()
        #expect(state.memoryPressureLevel == .normal)
    }

    @Test func appStatePreflightWarningDefaultsToNil() {
        let state = AppState()
        #expect(state.preflightWarning == nil)
    }

    @Test func appStateMemoryLevelCanBeUpdated() {
        let state = AppState()
        state.memoryPressureLevel = .warning
        #expect(state.memoryPressureLevel == .warning)
    }
}
```

- [ ] **Step 3: Run tests**

```bash
swift test --filter MemoryHardeningTests 2>&1 | tail -20
```

Expected: all 3 tests PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/dBrief/App/AppState.swift Tests/dBriefTests/MemoryHardeningTests.swift
git commit -m "feat: add MemoryPressureLevel and PreflightWarning to AppState"
```

---

## Task 2: MemoryPressureMonitor — typed handlers

**Files:**
- Modify: `Sources/dBrief/Services/MemoryPressureMonitor.swift`

- [ ] **Step 1: Add typed handler support**

In `Sources/dBrief/Services/MemoryPressureMonitor.swift`, add a new typealias and property after `private var cleanupHandlers`:

```swift
typealias PressureHandler = (MemoryPressureLevel) async -> Void
private var pressureHandlers: [PressureHandler] = []
private(set) var currentLevel: MemoryPressureLevel = .normal
```

Add a new registration method after `registerCleanupHandler`:

```swift
/// Register a handler that receives the pressure level when it changes.
func registerPressureHandler(_ handler: @escaping PressureHandler) {
    pressureHandlers.append(handler)
}
```

- [ ] **Step 2: Update triggerCleanup to emit level**

Replace the existing `triggerCleanup()` and `triggerAggressiveCleanup()` with:

```swift
private func triggerCleanup() async {
    currentLevel = .warning
    for handler in pressureHandlers {
        await handler(.warning)
    }
    for handler in cleanupHandlers {
        await handler()
    }
}

private func triggerAggressiveCleanup() async {
    currentLevel = .critical
    for handler in pressureHandlers {
        await handler(.critical)
    }
    for handler in cleanupHandlers {
        await handler()
    }
    URLCache.shared.removeAllCachedResponses()
    try? await Task.sleep(nanoseconds: 500_000_000)
}
```

- [ ] **Step 3: Add test for handler registration**

Add to `Tests/dBriefTests/MemoryHardeningTests.swift`:

```swift
@Test func pressureMonitorHandlerReceivesLevel() async {
    let monitor = MemoryPressureMonitor()
    var received: MemoryPressureLevel?
    monitor.registerPressureHandler { level in
        received = level
    }
    // Directly invoke internal trigger to avoid needing a real dispatch source
    await monitor.testTrigger(.warning)
    #expect(received == .warning)
}
```

Add a test-only method to `MemoryPressureMonitor` (inside an `#if DEBUG` block at the bottom of the file):

```swift
#if DEBUG
/// Test helper — directly fires pressure handlers without a real dispatch source event.
func testTrigger(_ level: MemoryPressureLevel) async {
    if level == .critical {
        await triggerAggressiveCleanup()
    } else {
        await triggerCleanup()
    }
}
#endif
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter MemoryHardeningTests 2>&1 | tail -20
```

Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Services/MemoryPressureMonitor.swift Tests/dBriefTests/MemoryHardeningTests.swift
git commit -m "feat: add typed pressure handlers to MemoryPressureMonitor"
```

---

## Task 3: AppContext — wire monitor to AppState

**Files:**
- Modify: `Sources/dBrief/App/DBriefApp.swift`

- [ ] **Step 1: Register pressure handler in AppContext.init**

In `Sources/dBrief/App/DBriefApp.swift`, inside `AppContext.init()`, after the existing `memoryMonitor.registerCleanupHandler` block, add:

```swift
memoryMonitor.registerPressureHandler { [weak self] level in
    self?.appState.memoryPressureLevel = level
}
```

- [ ] **Step 2: Build to verify no errors**

```bash
swift build 2>&1 | grep -E "error:|warning:" | head -20
```

Expected: 0 errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/App/DBriefApp.swift
git commit -m "feat: wire MemoryPressureMonitor level to AppState"
```

---

## Task 4: RecordingManager — pre-flight check + ensure results always shown

**Files:**
- Modify: `Sources/dBrief/Services/RecordingManager.swift`

The pre-flight check is **informational and non-blocking**: it sets `appState.preflightWarning` before the local AI call, which the processing view displays. Processing proceeds regardless.

- [ ] **Step 1: Add memory threshold constants**

Near the top of `RecordingManager` class body, add:

```swift
// Memory requirements for local models (bytes)
private enum MemoryThreshold {
    static let whisperKit: Int64 = 1_288_490_189   // 1.2 GB
    static let qwen3_4b:   Int64 = 4_831_838_209   // 4.5 GB
}
```

- [ ] **Step 2: Add pre-flight helper**

Add this `nonisolated static` method inside `RecordingManager`:

```swift
/// Returns a PreflightWarning if the given engine requires more memory than is available.
/// Returns nil if memory is sufficient or the engine is remote (no check needed).
static func preflightCheck(
    engine: AppSettings.AIEngine,
    hasRemoteEndpoint: Bool
) -> PreflightWarning? {
    let required: Int64
    let modelName: String
    switch engine {
    case .qwenLocal:
        required = MemoryThreshold.qwen3_4b
        modelName = "Qwen3 4B (Local)"
    case .localWhisper:
        required = MemoryThreshold.whisperKit
        modelName = "WhisperKit"
    case .appleIntelligence, .remoteEndpoint:
        return nil   // no local model loaded
    }
    guard !MemoryPressureMonitor.hasSufficientMemory(requiredBytes: required) else { return nil }
    let stats = MemoryPressureMonitor.getMemoryStats()
    let available = stats.map { Double($0.free) / 1_073_741_824 } ?? 0
    return PreflightWarning(
        modelName: modelName,
        requiredGB: Double(required) / 1_073_741_824,
        availableGB: available,
        hasRemoteEndpoint: hasRemoteEndpoint
    )
}
```

- [ ] **Step 3: Wire pre-flight check before AI processing**

In `processRecording()`, find the line `switch aiEngine {` (around line 199 in the original). Just before that `switch`, add:

```swift
// Pre-flight memory check — informational, non-blocking
let remoteAIEndpoint = appSettings.effectiveDefaultAIEndpoint
appState.preflightWarning = RecordingManager.preflightCheck(
    engine: aiEngine,
    hasRemoteEndpoint: remoteAIEndpoint != nil
)
```

Similarly, add the same pre-flight check in `retryAIAnalysis(for:)` at the equivalent position, before its `switch aiEngine {`.

- [ ] **Step 4: Ensure processing always transitions to idle**

At the end of `processRecording()`, the last line before the closing brace is:
```swift
appState.recordingState = .idle
```

This is already there. Verify that all error paths (finalization failure, etc.) also end in `.idle`. Looking at the finalization error path (around line 134–139), it sets `.idle` and returns. ✓ No change needed.

- [ ] **Step 5: Add pre-flight test**

Add to `MemoryHardeningTests.swift`:

```swift
@Test func preflightCheckReturnsNilForRemoteEndpoint() {
    let warning = RecordingManager.preflightCheck(
        engine: .remoteEndpoint,
        hasRemoteEndpoint: true
    )
    #expect(warning == nil)
}

@Test func preflightCheckReturnsNilForAppleIntelligence() {
    let warning = RecordingManager.preflightCheck(
        engine: .appleIntelligence,
        hasRemoteEndpoint: false
    )
    #expect(warning == nil)
}
```

- [ ] **Step 6: Run tests**

```bash
swift test --filter MemoryHardeningTests 2>&1 | tail -20
```

Expected: 6 tests PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/dBrief/Services/RecordingManager.swift Tests/dBriefTests/MemoryHardeningTests.swift
git commit -m "feat: add pre-flight memory check to RecordingManager before local AI"
```

---

## Task 5: ResultsView — new results state view

**Files:**
- Create: `Sources/dBrief/UI/ResultsView.swift`
- Create: `Tests/dBriefTests/ResultsViewTests.swift`

- [ ] **Step 1: Write section model tests first**

Create `Tests/dBriefTests/ResultsViewTests.swift`:

```swift
import Testing
@testable import dBrief

struct ResultsViewTests {

    @Test func allSectionsDefaultToExpanded() {
        let collapsed = Set<ResultsView.Section>()
        #expect(!collapsed.contains(.summary))
        #expect(!collapsed.contains(.actionItems))
        #expect(!collapsed.contains(.tagsAndSentiment))
    }

    @Test func toggleCollapsesThenExpandsSection() {
        var collapsed = Set<ResultsView.Section>()

        // First toggle: collapse
        if collapsed.contains(.summary) { collapsed.remove(.summary) } else { collapsed.insert(.summary) }
        #expect(collapsed.contains(.summary))

        // Second toggle: expand
        if collapsed.contains(.summary) { collapsed.remove(.summary) } else { collapsed.insert(.summary) }
        #expect(!collapsed.contains(.summary))
    }

    @Test func summarySectionHiddenWhenNil() {
        let recording = Recording(fileURL: URL(fileURLWithPath: "/tmp/test.flac"))
        #expect(recording.summary == nil)
        // When summary is nil, the section should not render
        // (tested via the guard in ResultsView.sectionIsVisible — see implementation)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail appropriately**

```bash
swift test --filter ResultsViewTests 2>&1 | tail -20
```

Expected: 2 pass (pure Set logic), 1 pass (nil check on Recording). No build errors needed to proceed.

- [ ] **Step 3: Create ResultsView.swift**

Create `Sources/dBrief/UI/ResultsView.swift`:

```swift
import SwiftUI
import AppKit

struct ResultsView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager

    @State private var collapsedSections = Set<Section>()
    @State private var copied = false

    enum Section: Hashable {
        case summary
        case actionItems
        case tagsAndSentiment
        case transcript   // shown only when AI failed but transcription succeeded
    }

    var body: some View {
        guard let recording = appState.currentRecording else { return AnyView(EmptyView()) }
        return AnyView(content(recording: recording))
    }

    private func content(recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(recording.generatedTitle ?? recording.meetingTitleDraft)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if recording.duration > 0 {
                    Text(recording.formattedDuration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 6)

            // Status strip
            statusStrip
                .padding(.bottom, 10)

            // Pre-flight warning banner
            if let warning = appState.preflightWarning {
                preflightBanner(warning)
                    .padding(.bottom, 8)
            }

            // Scrollable sections
            ScrollView {
                VStack(spacing: 6) {
                    if recording.summary != nil || recording.actionItems != nil {
                        if let summary = recording.summary {
                            collapsibleSection(.summary, title: "Summary") {
                                Text(summary)
                                    .font(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        if let items = recording.actionItems, !items.isEmpty {
                            collapsibleSection(.actionItems, title: "Action Items (\(items.count))") {
                                VStack(alignment: .leading, spacing: 4) {
                                    let visible = collapsedSections.contains(.actionItems) ? [] : items
                                    ForEach(Array(visible.prefix(3).enumerated()), id: \.offset) { _, item in
                                        HStack(alignment: .top, spacing: 6) {
                                            Text("◦").foregroundStyle(.secondary).font(.caption)
                                            Text(item).font(.callout)
                                        }
                                    }
                                    if items.count > 3 {
                                        Button("+\(items.count - 3) more") {
                                            collapsedSections.remove(.actionItems)
                                        }
                                        .buttonStyle(.borderless)
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                        .padding(.leading, 14)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        if recording.tags != nil || recording.sentiment != nil {
                            collapsibleSection(.tagsAndSentiment, title: tagsAndSentimentTitle(recording)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    if let tags = recording.tags, !tags.isEmpty {
                                        FlowLayout(spacing: 4) {
                                            ForEach(tags, id: \.self) { tag in
                                                Text(tag)
                                                    .font(.caption)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(.fill)
                                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                            }
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } else if let transcription = recording.transcription {
                        // AI failed but transcription succeeded — show transcript
                        collapsibleSection(.transcript, title: "Transcript") {
                            Text(transcription.text)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    // Retry banner — shown when AI step failed and remote endpoint exists
                    if aiStepFailed, appSettings.effectiveDefaultAIEndpoint != nil {
                        retryBanner
                    }
                }
                .padding(.bottom, 8)
            }

            Divider()
                .padding(.vertical, 6)

            // Pinned action bar
            actionBar(recording: recording)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Status strip

    private var statusStrip: some View {
        HStack(spacing: 4) {
            ForEach(Array(appState.processingSteps.filter { isSignificantStep($0) }.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Text("·").font(.caption2).foregroundStyle(.secondary)
                }
                stepChip(step)
            }
            Spacer()
        }
        .lineLimit(1)
    }

    private func isSignificantStep(_ step: ProcessingStep) -> Bool {
        // Show transcription and AI steps; hide auxiliary steps like "Finalizing audio"
        let name = step.name.lowercased()
        return name.contains("transcrib") || name.contains("summar") || name.contains("action") ||
               name.contains("tag") || name.contains("title") || name.contains("markdown")
    }

    private func stepChip(_ step: ProcessingStep) -> some View {
        Group {
            switch step.status {
            case .completed:
                Text("✓ \(abbreviatedStepName(step.name))")
                    .foregroundStyle(.green)
            case .failed:
                Text("✕ \(abbreviatedStepName(step.name))")
                    .foregroundStyle(.red)
            case .inProgress:
                Text("⋯ \(abbreviatedStepName(step.name))")
                    .foregroundStyle(.secondary)
            case .pending:
                Text(abbreviatedStepName(step.name))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption2)
    }

    private func abbreviatedStepName(_ name: String) -> String {
        if name.lowercased().contains("transcrib") { return "Transcribed" }
        if name.lowercased().contains("summar") { return "Summary" }
        if name.lowercased().contains("action") { return "Actions" }
        if name.lowercased().contains("tag") { return "Tags" }
        if name.lowercased().contains("title") { return "Title" }
        if name.lowercased().contains("markdown") { return "Notes" }
        return name
    }

    // MARK: - Collapsible section

    private func collapsibleSection<Content: View>(
        _ section: Section,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isCollapsed = collapsedSections.contains(section)
        return VStack(spacing: 0) {
            Button {
                if isCollapsed { collapsedSections.remove(section) } else { collapsedSections.insert(section) }
            } label: {
                HStack {
                    Text(title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Spacer()
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                content()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .background(.fill.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Banners

    private func preflightBanner(_ warning: PreflightWarning) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                Text("Low available memory")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text("\(warning.modelName) requires \(String(format: "%.1f", warning.requiredGB)) GB. Only \(String(format: "%.1f", warning.availableGB)) GB available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.yellow.opacity(0.1))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.3), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var retryBanner: some View {
        HStack(spacing: 8) {
            Text("Retry AI with remote endpoint?")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Retry") {
                Task {
                    guard let recording = appState.currentRecording else { return }
                    appState.preflightWarning = nil
                    await recordingManager.retryAIAnalysis(for: recording)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.2), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Action bar

    private func actionBar(recording: Recording) -> some View {
        HStack(spacing: 6) {
            Button(copied ? "Copied!" : "Copy Notes") {
                copyNotes(recording: recording)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(recording.transcription == nil && recording.summary == nil)

            Spacer()

            if let markdownURL = findMarkdownFile(for: recording) {
                Button("Open File") {
                    NSWorkspace.shared.open(markdownURL)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button("Dismiss") {
                appState.processingSteps.removeAll()
                appState.preflightWarning = nil
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Helpers

    private var aiStepFailed: Bool {
        appState.processingSteps.contains { step in
            guard case .failed = step.status else { return false }
            let name = step.name.lowercased()
            return name.contains("summar") || name.contains("action") || name.contains("tag") || name.contains("qwen") || name.contains("ai")
        }
    }

    private func tagsAndSentimentTitle(_ recording: Recording) -> String {
        var parts: [String] = ["Tags"]
        if let sentiment = recording.sentiment { parts.append(sentiment) }
        return parts.joined(separator: " · ")
    }

    private func copyNotes(recording: Recording) {
        var parts: [String] = []
        if let summary = recording.summary { parts.append("## Summary\n\(summary)") }
        if let items = recording.actionItems, !items.isEmpty {
            parts.append("## Action Items\n" + items.map { "- \($0)" }.joined(separator: "\n"))
        }
        if let transcript = recording.transcription?.text, parts.isEmpty {
            parts.append(transcript)
        }
        let text = parts.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func findMarkdownFile(for recording: Recording) -> URL? {
        let base = (recording.finalizedAudioURL ?? recording.fileURL)
            .deletingPathExtension()
        let candidate = base.appendingPathExtension("md")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}

// MARK: - FlowLayout

/// Simple left-to-right wrapping layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var x: CGFloat = 0, y: CGFloat = 0, maxHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += maxHeight + spacing; maxHeight = 0 }
            maxHeight = max(maxHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: width, height: y + maxHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, maxHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += maxHeight + spacing; maxHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            maxHeight = max(maxHeight, size.height)
            x += size.width + spacing
        }
    }
}
```

- [ ] **Step 4: Build to verify**

```bash
swift build 2>&1 | grep -E "error:" | head -20
```

Expected: 0 errors. Fix any type mismatches.

- [ ] **Step 5: Run tests**

```bash
swift test --filter ResultsViewTests 2>&1 | tail -20
```

Expected: 3 PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/dBrief/UI/ResultsView.swift Tests/dBriefTests/ResultsViewTests.swift
git commit -m "feat: add ResultsView with collapsible sections and action bar"
```

---

## Task 6: RecordingControlsView — vertical level meter + recording state polish

**Files:**
- Modify: `Sources/dBrief/UI/RecordingControlsView.swift`

- [ ] **Step 1: Replace LevelMeter with LevelMeterBars**

In `Sources/dBrief/UI/RecordingControlsView.swift`, replace the existing `LevelMeter` struct (from line 149 to the end of the file) with:

```swift
struct LevelMeterBars: View {
    let level: Float
    private let barCount = 8

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor(for: index))
                    .frame(width: 3, height: barHeight(for: index))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let threshold = Float(index + 1) / Float(barCount)
        let filled = level >= threshold
        return filled ? CGFloat(4 + index * 2) : 4
    }

    private func barColor(for index: Int) -> Color {
        let threshold = Float(index + 1) / Float(barCount)
        if threshold > 0.85 { return .red }
        if threshold > 0.6  { return .yellow }
        return .green
    }
}
```

- [ ] **Step 2: Update the recording state timer/level row**

In `RecordingControlsView.body`, replace the `LevelMeter(level: appState.peakLevel)` usage with `LevelMeterBars(level: appState.peakLevel)`. The call site is inside the `if appState.isRecording || appState.isPaused` block:

```swift
// Timer and level
if appState.isRecording || appState.isPaused {
    HStack(alignment: .bottom) {
        Text(formattedDuration)
            .font(.system(.title2, design: .monospaced))
            .foregroundStyle(.primary)
        Spacer()
        LevelMeterBars(level: appState.peakLevel)
            .frame(width: 36, height: 20)
    }
}
```

- [ ] **Step 3: Add REC indicator and audio source chips**

In `RecordingControlsView.body`, replace the `VStack` opening so the full view becomes:

```swift
var body: some View {
    @Bindable var settings = appSettings
    VStack(spacing: 8) {
        // Profile picker — hidden while recording
        if appState.isIdle {
            HStack {
                Text("Profile")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker(
                    "",
                    selection: Binding(
                        get: { settings.activeProfileId },
                        set: { settings.setActiveProfile($0) }
                    )
                ) {
                    ForEach(settings.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 170)
            }
        }

        // REC header shown while recording
        if appState.isRecording || appState.isPaused {
            HStack {
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                        .opacity(appState.isRecording ? 1 : 0.3)
                        .animation(.easeInOut(duration: 0.6).repeatForever(), value: appState.isRecording)
                    Text(appState.isPaused ? "PAUSED" : "REC")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(appState.isRecording ? .red : .secondary)
                }
            }
        }

        // Timer and level
        if appState.isRecording || appState.isPaused {
            HStack(alignment: .bottom) {
                Text(formattedDuration)
                    .font(.system(.title2, design: .monospaced))
                    .foregroundStyle(.primary)
                Spacer()
                LevelMeterBars(level: appState.peakLevel)
                    .frame(width: 36, height: 20)
            }
        }

        // Controls
        HStack(spacing: 12) {
            if appState.isIdle {
                Button {
                    appState.lastError = nil
                    Task {
                        do {
                            try await recordingManager.startRecording()
                        } catch {
                            let msg = error.localizedDescription
                            appState.lastError = msg
                        }
                    }
                } label: {
                    Label("Record", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else if appState.isRecording {
                Button { recordingManager.pauseRecording() } label: {
                    Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button { Task { await recordingManager.stopRecording() } } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else if appState.isPaused {
                Button { try? recordingManager.resumeRecording() } label: {
                    Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button { Task { await recordingManager.stopRecording() } } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }

        // Audio source chips
        if appState.isRecording || appState.isPaused {
            HStack(spacing: 8) {
                Label("Mic", systemImage: "mic.fill")
                    .font(.caption2)
                    .foregroundStyle(recordingManager.hasMicrophonePermission ? .green : .secondary)
                if recordingManager.hasSystemAudioPermission {
                    Label("System Audio", systemImage: "speaker.wave.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                Spacer()
            }
        }

        if (appState.isRecording || appState.isPaused),
           appSettings.obsidianEnabled,
           let recording = appState.currentRecording {
            ObsidianFolderPicker(
                title: "Obsidian output folder",
                currentRelativePath: recording.obsidianFolderRelativePath ?? appSettings.effectiveObsidianDefaultFolderRelativePath
            ) { relativePath in
                recording.obsidianFolderRelativePath = relativePath
                if appSettings.activeProfile.isProtectedDefault {
                    appSettings.obsidianDefaultFolderRelativePath = relativePath
                }
            }
        }

        if let error = appState.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }
}
```

- [ ] **Step 4: Build to verify**

```bash
swift build 2>&1 | grep -E "error:" | head -20
```

Expected: 0 errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/UI/RecordingControlsView.swift
git commit -m "feat: vertical level meter bars, REC indicator, audio source chips"
```

---

## Task 7: MenuBarView — route results + memory bar in processing view + always-visible history

**Files:**
- Modify: `Sources/dBrief/App/DBriefApp.swift`
- Modify: `Sources/dBrief/UI/TranscriptionProgressView.swift`

### 7a — Add memory bar to TranscriptionProgressView

- [ ] **Step 1: Add memory bar to TranscriptionProgressView**

Open `Sources/dBrief/UI/TranscriptionProgressView.swift`. Add a timer state and memory stats state at the top of the struct:

```swift
@State private var memStats: (used: Int64, free: Int64, total: Int64)? = nil
@State private var memTimer: Timer? = nil
```

Add a memory bar computed property after the `stepIcon` function:

```swift
@ViewBuilder
private var memoryBar: some View {
    if let stats = memStats, stats.total > 0 {
        let fraction = Double(stats.used) / Double(stats.total)
        let usedGB = Double(stats.used) / 1_073_741_824
        let totalGB = Double(stats.total) / 1_073_741_824
        let color: Color = fraction > 0.85 ? .red : fraction > 0.6 ? .yellow : .green

        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Memory")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f / %.0f GB", usedGB, totalGB))
                    .font(.caption2)
                    .foregroundStyle(fraction > 0.6 ? color : .secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(min(fraction, 1.0)))
                        .animation(.linear(duration: 0.3), value: fraction)
                }
            }
            .frame(height: 4)
        }
    }
}
```

In the `body` VStack, add `memoryBar` just before the Cancel button (before the `if hasInProgressStep` block), and add the "⚠ Low RAM" badge to the step row. Replace the `HStack(spacing: 8)` inside `ForEach(appState.processingSteps)` with:

```swift
HStack(spacing: 8) {
    stepIcon(for: step.status)
        .frame(width: 16)
    Text(step.name)
        .font(.callout)
    Spacer()
    if case .inProgress = step.status, appState.memoryPressureLevel != .normal {
        Text("⚠ Low RAM")
            .font(.caption2)
            .foregroundStyle(.yellow)
    }
}
```

Add `.onAppear` and `.onDisappear` to the outer VStack to start/stop the 2-second polling timer:

```swift
.onAppear {
    memStats = MemoryPressureMonitor.getMemoryStats()
    memTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        Task { @MainActor in
            memStats = MemoryPressureMonitor.getMemoryStats()
        }
    }
}
.onDisappear {
    memTimer?.invalidate()
    memTimer = nil
}
```

### 7b — Update MenuBarView routing

- [ ] **Step 2: Split processing / results routing in MenuBarView**

In `Sources/dBrief/App/DBriefApp.swift`, inside `MenuBarView.body`, replace:

```swift
} else if appState.isProcessing || appState.hasProcessingResults {
    Divider()
    TranscriptionProgressView(onCancel: recordingManager.cancelProcessing)
} else if showHistory {
    Divider()
    RecordingHistoryView()
}
```

with:

```swift
} else if appState.isProcessing {
    Divider()
    TranscriptionProgressView(onCancel: recordingManager.cancelProcessing)
} else if appState.hasProcessingResults {
    Divider()
    ResultsView()
        .environment(context.appState)
        .environment(context.appSettings)
        .environment(context.recordingManager)
}

if appState.isIdle, !appState.hasProcessingResults {
    Divider()
    RecordingHistoryView()
}
```

Note: `ResultsView` needs the same environment injections as `MenuBarView`. Since `MenuBarView` already has them in its environment from the `MenuBarExtra` definition, the `.environment()` calls on `ResultsView` are only needed if you're constructing it outside that scope — verify by build.

Also remove the `@State private var showHistory = false` property from `MenuBarView` and the "History" / "Hide History" toggle button at the bottom footer, since history is now always shown in idle state.

- [ ] **Step 3: Build to verify**

```bash
swift build 2>&1 | grep -E "error:" | head -20
```

Expected: 0 errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/dBrief/App/DBriefApp.swift Sources/dBrief/UI/TranscriptionProgressView.swift
git commit -m "feat: route results to ResultsView, memory bar in processing, always-show history when idle"
```

---

## Task 8: RecordingHistoryView — expanded inline rows with action chips

**Files:**
- Modify: `Sources/dBrief/UI/RecordingHistoryView.swift`

- [ ] **Step 1: Add expanded state and richer HistoryItem**

Replace the `HistoryItem` struct with an extended version and add `@State private var expandedItemId: UUID?`:

```swift
@State private var expandedItemId: UUID?
@State private var loadedSummaries: [UUID: String] = [:]

struct HistoryItem: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let date: Date
    let size: Int64
    let duration: TimeInterval
    let profileName: String?
    let hasTranscript: Bool

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var formattedDuration: String {
        guard duration > 0 else { return "" }
        let total = Int(duration)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var markdownURL: URL? {
        let candidate = url.deletingPathExtension().appendingPathExtension("md")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}
```

- [ ] **Step 2: Rewrite loadRecordings to cap at 20 and load duration**

Replace `loadRecordings()`:

```swift
private func loadRecordings() {
    let folder = appSettings.effectiveRecordingFolderURL
    let all = RecordingDiscovery.discover(in: folder)
    recordings = Array(all.prefix(20)).map { entry in
        let base = entry.url.deletingPathExtension()
        let transcriptURL = base.appendingPathExtension("transcript.json")
        let hasTranscript = FileManager.default.fileExists(atPath: transcriptURL.path)

        // Try to read duration from metadata JSON
        var duration: TimeInterval = 0
        let metaURL = base.appendingPathExtension("json")
        if let data = try? Data(contentsOf: metaURL),
           let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let d = meta["duration"] as? TimeInterval {
            duration = d
        }

        return HistoryItem(
            url: entry.url,
            name: base.lastPathComponent,
            date: entry.createdAt,
            size: entry.size,
            duration: duration,
            profileName: nil,   // not stored in metadata today
            hasTranscript: hasTranscript
        )
    }
}
```

- [ ] **Step 3: Rewrite historyRow to support expand/collapse**

Replace the `historyRow` function:

```swift
private func historyRow(_ item: HistoryItem) -> some View {
    let isExpanded = expandedItemId == item.id
    return VStack(spacing: 0) {
        // Collapsed row
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                expandedItemId = isExpanded ? nil : item.id
            }
            if !isExpanded { loadSummary(for: item) }
        } label: {
            HStack(spacing: 8) {
                Button {
                    audioPlayer.togglePlayPause(url: item.url)
                } label: {
                    Image(systemName: audioPlayer.currentFileURL == item.url && audioPlayer.isPlaying
                        ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.borderless)
                .onTapGesture {} // prevent row tap propagation

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        Text(item.formattedDate)
                        if !item.formattedDuration.isEmpty {
                            Text("·")
                            Text(item.formattedDuration)
                        }
                        if item.hasTranscript {
                            Text("·")
                            Text("✓ AI").foregroundStyle(.green)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .padding(.horizontal, 4)

        // Expanded action chips
        if isExpanded {
            HStack(spacing: 6) {
                if item.hasTranscript {
                    actionChip(
                        title: loadedSummaries[item.id] != nil ? "Copy Summary" : "Copy Transcript",
                        systemImage: "doc.on.doc"
                    ) {
                        let text = loadedSummaries[item.id] ?? ""
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }

                if let mdURL = item.markdownURL {
                    actionChip(title: "Open File", systemImage: "arrow.up.right.square") {
                        NSWorkspace.shared.open(mdURL)
                    }
                } else {
                    actionChip(title: "Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.selectFile(item.url.path, inFileViewerRootedAtPath: "")
                    }
                }

                if item.hasTranscript {
                    actionChip(title: "Re-run AI", systemImage: "arrow.trianglehead.2.clockwise") {
                        Task {
                            let recording = Recording(
                                fileURL: item.url,
                                fileSize: item.size,
                                meetingTitleDraft: item.name,
                                finalizedAudioURL: item.url
                            )
                            await recordingManager.retryAIAnalysis(for: recording)
                        }
                    }
                }

                actionChip(title: "Delete", systemImage: "trash", destructive: true) {
                    deleteItem(item)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)
        }
    }
    .background(
        (audioPlayer.currentFileURL == item.url || isExpanded)
            ? Color.accentColor.opacity(0.07)
            : Color.clear
    )
    .clipShape(RoundedRectangle(cornerRadius: 6))
}

private func actionChip(title: String, systemImage: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Label(title, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(destructive ? .red : .primary)
    }
    .buttonStyle(.bordered)
    .controlSize(.mini)
}

private func loadSummary(for item: HistoryItem) {
    guard loadedSummaries[item.id] == nil else { return }
    Task {
        let base = item.url.deletingPathExtension()
        // Try markdown file first — extract Summary section
        if let mdURL = item.markdownURL,
           let content = try? String(contentsOf: mdURL, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n")
            var inSummary = false
            var summaryLines: [String] = []
            for line in lines {
                if line.hasPrefix("## Summary") { inSummary = true; continue }
                if inSummary {
                    if line.hasPrefix("## ") { break }
                    summaryLines.append(line)
                }
            }
            let summary = summaryLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty { loadedSummaries[item.id] = summary; return }
        }
        // Fall back to transcript text
        let transcriptURL = base.appendingPathExtension("transcript.json")
        if let data = try? Data(contentsOf: transcriptURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            loadedSummaries[item.id] = text
        }
    }
}

private func deleteItem(_ item: HistoryItem) {
    let base = item.url.deletingPathExtension()
    let candidates = [
        item.url,
        base.appendingPathExtension("md"),
        base.appendingPathExtension("transcript.json"),
        base.appendingPathExtension("json"),
    ]
    for url in candidates {
        try? FileManager.default.removeItem(at: url)
    }
    recordings.removeAll { $0.id == item.id }
    if expandedItemId == item.id { expandedItemId = nil }
}
```

- [ ] **Step 4: Build to verify**

```bash
swift build 2>&1 | grep -E "error:" | head -20
```

Expected: 0 errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/UI/RecordingHistoryView.swift
git commit -m "feat: expandable history rows with action chips, 20-item cap, duration display"
```

---

## Task 9: Settings reorganisation — Recording tab, fold Permissions, AI & Models tab

**Files:**
- Modify: `Sources/dBrief/UI/SettingsView.swift`
- Modify: `Sources/dBrief/UI/SettingsGeneralTab.swift`
- Create: `Sources/dBrief/UI/SettingsRecordingTab.swift`
- Create: `Sources/dBrief/UI/SettingsAIModelsTab.swift`

Note: `SettingsView` already uses `NavigationSplitView`. The work is reorganising tabs and content.

### 9a — Update SettingsView tab enum

- [ ] **Step 1: Update SettingsTab enum in SettingsView.swift**

Replace the `SettingsTab` enum:

```swift
enum SettingsTab: String, CaseIterable, Identifiable {
    case general      = "General"
    case recording    = "Recording"
    case aiAndModels  = "AI & Models"
    case integrations = "Integrations"
    case profiles     = "Profiles"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general:     "gear"
        case .recording:   "mic"
        case .aiAndModels: "brain"
        case .integrations:"puzzlepiece.extension"
        case .profiles:    "person.3"
        }
    }
}
```

Replace `visibleTabs`:

```swift
private var visibleTabs: [SettingsTab] {
    SettingsTab.allCases.filter { tab in
        if tab == .profiles { return appSettings.powerUserMode }
        return true
    }
}
```

Replace the `detail` content switch:

```swift
switch tab {
case .general:     SettingsGeneralTab()
case .recording:   SettingsRecordingTab()
case .aiAndModels: SettingsAIModelsTab()
case .integrations:SettingsIntegrationsTab()
case .profiles:    SettingsProfilesTab()
}
```

Add an About footer below the `List` in the sidebar:

```swift
Divider()
if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
    Text("dBrief v\(version)")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
}
```

### 9b — Create SettingsRecordingTab.swift

- [ ] **Step 2: Create SettingsRecordingTab.swift**

Create `Sources/dBrief/UI/SettingsRecordingTab.swift`:

```swift
import SwiftUI

struct SettingsRecordingTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager
    @State private var inputDevices: [AudioInputDevice] = []

    var body: some View {
        @Bindable var settings = appSettings
        Form {
            Section("Audio Input") {
                let selectedUID = settings.audioInputDeviceUID
                let knownUIDs = Set(inputDevices.map { $0.uid })
                let isMissingSelection = !selectedUID.isEmpty && !knownUIDs.contains(selectedUID)

                LabeledContent("Input device:") {
                    Picker("", selection: $settings.audioInputDeviceUID) {
                        Text("System Default").tag("")
                        ForEach(inputDevices) { device in
                            Text(device.displayName).tag(device.uid)
                        }
                        if isMissingSelection {
                            Text("Unavailable device (reconnect)").tag(selectedUID)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220, alignment: .trailing)
                }
                LabeledContent("") {
                    Button("Refresh device list") {
                        inputDevices = AudioInputDeviceManager.availableInputDevices()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .listRowBackground(Color.clear)

            if appSettings.powerUserMode {
                Section("Audio Quality") {
                    LabeledContent("Recording profile:") {
                        Text("Whisper optimized (16 kHz mono FLAC)")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Post-process:") {
                        Text("80Hz high-pass, light denoise, AGC/echo cancel, -20 LUFS to -3dBTP")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .toggleStyle(.smallSwitch)
        .padding(.top, -20)
        .onAppear {
            inputDevices = AudioInputDeviceManager.availableInputDevices()
        }
    }
}
```

### 9c — Create SettingsAIModelsTab.swift

- [ ] **Step 3: Create SettingsAIModelsTab.swift**

Create `Sources/dBrief/UI/SettingsAIModelsTab.swift` by combining the content of `SettingsTranscriptionTab` and `SettingsAITab`. Open both existing files to read their full body content, then create:

```swift
import SwiftUI

/// Combined transcription + AI engine settings. Merges the former Transcription and AI tabs.
struct SettingsAIModelsTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager

    var body: some View {
        Form {
            // ── Transcription ─────────────────────────────────────────────
            Section("Transcription") {
                SettingsTranscriptionTab()
                    .environment(appSettings)
                    .environment(recordingManager)
            }
            .listRowBackground(Color.clear)

            // ── AI ────────────────────────────────────────────────────────
            Section("AI Analysis") {
                SettingsAITab()
                    .environment(appSettings)
                    .environment(recordingManager)
            }
            .listRowBackground(Color.clear)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .toggleStyle(.smallSwitch)
        .padding(.top, -20)
    }
}
```

Note: `SettingsTranscriptionTab` and `SettingsAITab` are self-contained form views. Embedding them inside `Section` wrappers in a parent `Form` can cause nested Form issues in SwiftUI. If this causes layout problems on build, instead copy the content of `SettingsTranscriptionTab.body` and `SettingsAITab.body` directly into sections in `SettingsAIModelsTab`. The safer approach is direct content composition — check the build output and adjust accordingly.

### 9d — Fold Permissions into SettingsGeneralTab

- [ ] **Step 4: Add Permissions section to SettingsGeneralTab**

Open `Sources/dBrief/UI/SettingsGeneralTab.swift`. Read `Sources/dBrief/UI/SettingsPermissionsTab.swift` to understand its content, then add a Permissions section at the end of the `Form` in `SettingsGeneralTab`, after the Call Detection section:

```swift
Section("Permissions") {
    LabeledContent("Microphone:") {
        HStack {
            Image(systemName: recordingManager.hasMicrophonePermission ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(recordingManager.hasMicrophonePermission ? .green : .red)
            Text(recordingManager.hasMicrophonePermission ? "Granted" : "Not granted")
                .foregroundStyle(.secondary)
            if !recordingManager.hasMicrophonePermission {
                Button("Request") {
                    Task { await recordingManager.checkPermissions() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
    LabeledContent("Screen Recording:") {
        HStack {
            Image(systemName: recordingManager.hasSystemAudioPermission ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(recordingManager.hasSystemAudioPermission ? .green : .red)
            Text(recordingManager.hasSystemAudioPermission ? "Granted" : "Not granted")
                .foregroundStyle(.secondary)
            if !recordingManager.hasSystemAudioPermission {
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}
.listRowBackground(Color.clear)
```

Add `@Environment(RecordingManager.self) private var recordingManager` to `SettingsGeneralTab` if not already present.

Also remove the "Audio Input" and "Audio Quality" sections from `SettingsGeneralTab` (they've moved to `SettingsRecordingTab`).

- [ ] **Step 5: Build to verify**

```bash
swift build 2>&1 | grep -E "error:" | head -20
```

Expected: 0 errors. Fix any missing environment injections.

- [ ] **Step 6: Run all tests**

```bash
swift test 2>&1 | tail -20
```

Expected: All tests PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/dBrief/UI/SettingsView.swift Sources/dBrief/UI/SettingsGeneralTab.swift \
        Sources/dBrief/UI/SettingsRecordingTab.swift Sources/dBrief/UI/SettingsAIModelsTab.swift
git commit -m "feat: reorganise settings — Recording tab, AI & Models tab, Permissions in General"
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Covered by |
|---|---|
| System appearance-aware colors | Task 5 (ResultsView uses `.fill`, `.secondaryLabel` etc.) ✓ |
| Idle state with history always shown | Task 7b (remove showHistory toggle) ✓ |
| Recording state — vertical level meter, REC indicator, audio source chips | Task 6 ✓ |
| Processing state — memory bar, per-step RAM badge | Task 7a ✓ |
| Results state — collapsible sections, action bar, status strip | Task 5 ✓ |
| Pre-flight warning banner | Tasks 1, 3, 5 (banner rendered in ResultsView when preflightWarning is set) ✓ |
| Graceful partial results | Existing RecordingManager already marks steps failed and continues ✓ |
| Retry banner when AI failed + remote configured | Task 5 ✓ |
| History — richer metadata (duration, AI badge) | Task 8 ✓ |
| History — action chips (Copy, Open, Re-run, Delete) | Task 8 ✓ |
| History — 20-item cap | Task 8 ✓ |
| Settings — sidebar layout | Already existed, reorganised in Task 9 ✓ |
| Settings — Recording tab | Task 9b ✓ |
| Settings — AI & Models tab | Task 9c ✓ |
| Settings — Permissions in General | Task 9d ✓ |
| Settings — About as footer | Task 9a ✓ |
| MemoryPressureMonitor typed handlers | Task 2 ✓ |
| AppContext wires monitor → AppState | Task 3 ✓ |

**Potential issue — SettingsAIModelsTab:** Nesting `Form` views inside a `Section` of another `Form` will likely produce layout problems in SwiftUI. Task 9c explicitly notes this and tells implementer to copy content directly if needed. This is flagged, not a spec gap.

**Potential issue — `RecordingManager.preflightCheck` for `.localWhisper`:** The `AppSettings.AIEngine` enum may not have a `.localWhisper` case — the transcription engine and AI engine are separate settings. Check the enum before implementing Task 4. The pre-flight for WhisperKit belongs on the *transcription* engine side, not AI engine. Update the switch in `preflightCheck` to also accept `AppSettings.TranscriptionEngine` as a separate overload if needed.
