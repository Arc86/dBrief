# Vocabulary Settings Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Custom Vocabulary out of the Whisper-gated transcription section into its own top-level "Vocabulary" Settings tab, visible to all users, with a structured inline-editable list UI and clear explanatory copy.

**Architecture:** Change the backing store from a comma-separated `String` (`whisperPrompt`) to a `[String]` array (`customVocabulary`) with migration from the legacy key. All call sites in `RecordingManager` and `TranscriptSpellingService` switch to the array type. A new `SettingsVocabularyTab` view is added; the old `vocabularySection` in `SettingsTranscriptionTab` is removed.

**Tech Stack:** Swift 6.2, SwiftUI (`Form`, `List`, `@Observable`), UserDefaults (native `stringArray` storage for `[String]`), `swift-testing` for updated profile tests.

## Global Constraints

- macOS 14+ deployment target; Swift 6.2 strict concurrency.
- `@Observable` + `@MainActor` for all `AppSettings` and UI types.
- No new dependencies.
- All `Codable` types must remain backwards-compatible (decode old `whisperPrompt` key, encode new `customVocabulary` key).
- Build command: `swift build`. Test command: `swift test`.

---

## File Map

| File | Action |
|------|--------|
| `Sources/dBrief/App/AppSettings.swift` | Rename property + key; change type `String` → `[String]`; add migration init; rename preset constants |
| `Sources/dBrief/App/AppSettings+EffectiveSettings.swift` | `effectiveWhisperPrompt: String` → `effectiveCustomVocabulary: [String]` |
| `Sources/dBrief/Models/MeetingProfile.swift` | `whisperPrompt: String?` → `customVocabulary: [String]?`; add `init(from:)` with legacy key migration |
| `Sources/dBrief/App/AppSettings+Profiles.swift` | Update `resetToDefault` and preset factories to use `customVocabulary` |
| `Sources/dBrief/Services/TranscriptSpellingService.swift` | Use `effectiveCustomVocabulary: [String]` directly; remove `vocabularyTerms(from:)` |
| `Sources/dBrief/Services/RecordingManager.swift` | 5 call sites: `effectiveWhisperPrompt` → `effectiveCustomVocabulary.joined(separator: ", ")` |
| `Sources/dBrief/UI/SettingsTranscriptionTab.swift` | Remove `vocabularySection` property and its gated `Section` call |
| `Sources/dBrief/UI/SettingsProfilesTab.swift` | Replace `whisperPrompt` override row with `customVocabulary`; add `vocabularyCSVBinding()` helper |
| `Sources/dBrief/UI/SettingsView.swift` | Add `vocabulary` case to `SettingsTab`; add icon; add `case .vocabulary` to body switch |
| `Sources/dBrief/UI/SettingsVocabularyTab.swift` | **Create new** — full vocabulary tab implementation |
| `Tests/dBriefTests/ProfileBehaviorTests.swift` | Update 2 lines: `whisperPrompt: String` → `customVocabulary: [String]` |

---

### Task 1: AppSettings data model — `whisperPrompt: String` → `customVocabulary: [String]`

**Files:**
- Modify: `Sources/dBrief/App/AppSettings.swift`
- Modify: `Sources/dBrief/App/AppSettings+EffectiveSettings.swift`

**Interfaces:**
- Produces: `AppSettings.customVocabulary: [String]` (stored property with `didSet`)
- Produces: `AppSettings.effectiveCustomVocabulary: [String]` (computed, profile-aware)
- Produces: `AppSettings.Keys.customVocabulary: String` (UserDefaults key constant)
- Produces: `AppSettings.teamMeetingVocabulary: [String]` (renamed preset constant)
- Produces: `AppSettings.salesMeetingVocabulary: [String]` (renamed preset constant)

- [ ] **Step 1: In `AppSettings.swift`, rename the `Keys` constant**

Find the line:
```swift
static let whisperPrompt = "whisperPrompt"
```
Replace with:
```swift
static let customVocabulary = "customVocabulary"
```

- [ ] **Step 2: In `AppSettings.swift`, change the stored property**

Find:
```swift
var whisperPrompt: String {
    didSet { UserDefaults.standard.set(whisperPrompt, forKey: Keys.whisperPrompt) }
}
```
Replace with:
```swift
var customVocabulary: [String] {
    didSet { UserDefaults.standard.set(customVocabulary, forKey: Keys.customVocabulary) }
}
```

- [ ] **Step 3: In `AppSettings.swift`, update the `init` to migrate from legacy key**

Find:
```swift
self.whisperPrompt = defaults.string(forKey: Keys.whisperPrompt) ?? ""
```
Replace with:
```swift
// Migration: if customVocabulary absent but legacy whisperPrompt exists, parse and migrate
if let existing = defaults.stringArray(forKey: Keys.customVocabulary) {
    self.customVocabulary = existing
} else if let legacy = defaults.string(forKey: "whisperPrompt"), !legacy.isEmpty {
    let migrated = legacy
        .components(separatedBy: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    self.customVocabulary = migrated
    defaults.set(migrated, forKey: Keys.customVocabulary)
    defaults.removeObject(forKey: "whisperPrompt")
} else {
    self.customVocabulary = []
}
```

- [ ] **Step 4: In `AppSettings.swift`, rename the preset vocabulary constants**

Find:
```swift
static let teamMeetingWhisperPrompt =
    "Team standup, sprint, backlog, blocker, follow-up, ETA, Jira, PR, release, roadmap, architecture."
```
Replace with:
```swift
static let teamMeetingVocabulary: [String] = [
    "Team standup", "sprint", "backlog", "blocker", "follow-up",
    "ETA", "Jira", "PR", "release", "roadmap", "architecture"
]
```

Find:
```swift
static let salesMeetingWhisperPrompt =
    "Customer, contract, pricing, procurement, renewal, objections, competitor, timeline, stakeholder, action item, follow-up."
```
Replace with:
```swift
static let salesMeetingVocabulary: [String] = [
    "Customer", "contract", "pricing", "procurement", "renewal",
    "objections", "competitor", "timeline", "stakeholder", "action item", "follow-up"
]
```

- [ ] **Step 5: In `AppSettings+EffectiveSettings.swift`, replace `effectiveWhisperPrompt`**

Find:
```swift
var effectiveWhisperPrompt: String {
    activeProfile.overrides.whisperPrompt ?? whisperPrompt
}
```
Replace with:
```swift
var effectiveCustomVocabulary: [String] {
    activeProfile.overrides.customVocabulary ?? customVocabulary
}
```

- [ ] **Step 6: Build to check for compilation errors from the renamed property**

```bash
swift build 2>&1 | grep -E "error:|whisperPrompt|effectiveWhisperPrompt"
```

Expected: errors listing every remaining reference to `whisperPrompt` or `effectiveWhisperPrompt` — these will be fixed in subsequent tasks. No new structural errors.

- [ ] **Step 7: Commit**

```bash
git add Sources/dBrief/App/AppSettings.swift Sources/dBrief/App/AppSettings+EffectiveSettings.swift
git commit -m "refactor: rename whisperPrompt→customVocabulary, change type String→[String] with migration"
```

---

### Task 2: `MeetingProfileOverrides` — rename field + Codable migration

**Files:**
- Modify: `Sources/dBrief/Models/MeetingProfile.swift`
- Modify: `Sources/dBrief/App/AppSettings+Profiles.swift`

**Interfaces:**
- Consumes: `AppSettings.teamMeetingVocabulary: [String]` (from Task 1)
- Consumes: `AppSettings.salesMeetingVocabulary: [String]` (from Task 1)
- Produces: `MeetingProfileOverrides.customVocabulary: [String]?`
- Produces: `MeetingProfileOverrides.init(from:)` — decodes new `"customVocabulary"` key; migrates old `"whisperPrompt"` key

- [ ] **Step 1: In `MeetingProfile.swift`, replace the stored property and add `init(from:)` for migration**

Replace the entire `MeetingProfileOverrides` struct with:

```swift
struct MeetingProfileOverrides: Codable, Equatable, Hashable, Sendable {
    var transcriptionLanguage: String?
    var customVocabulary: [String]?
    var transcriptionEngine: AppSettings.TranscriptionEngine?
    var transcriptionEndpointId: UUID?
    var aiProcessingEnabled: Bool?
    var aiEngine: AppSettings.AIEngine?
    var aiEndpointId: UUID?
    var summaryPrompt: String?
    var actionItemsPrompt: String?
    var tagsPrompt: String?
    var autoTranscribe: Bool?
    var autoSummary: Bool?
    var autoActionItems: Bool?
    var autoTags: Bool?
    var recordingFolderPath: String?
    var transcriptionFolderPath: String?
    var obsidianVaultPath: String?
    var obsidianDefaultFolderRelativePath: String?

    static let empty = MeetingProfileOverrides()

    // Legacy key used only in decoding for migration
    private enum LegacyKeys: String, CodingKey { case whisperPrompt }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transcriptionLanguage           = try c.decodeIfPresent(String.self, forKey: .transcriptionLanguage)
        customVocabulary                = try c.decodeIfPresent([String].self, forKey: .customVocabulary)
        transcriptionEngine             = try c.decodeIfPresent(AppSettings.TranscriptionEngine.self, forKey: .transcriptionEngine)
        transcriptionEndpointId         = try c.decodeIfPresent(UUID.self, forKey: .transcriptionEndpointId)
        aiProcessingEnabled             = try c.decodeIfPresent(Bool.self, forKey: .aiProcessingEnabled)
        aiEngine                        = try c.decodeIfPresent(AppSettings.AIEngine.self, forKey: .aiEngine)
        aiEndpointId                    = try c.decodeIfPresent(UUID.self, forKey: .aiEndpointId)
        summaryPrompt                   = try c.decodeIfPresent(String.self, forKey: .summaryPrompt)
        actionItemsPrompt               = try c.decodeIfPresent(String.self, forKey: .actionItemsPrompt)
        tagsPrompt                      = try c.decodeIfPresent(String.self, forKey: .tagsPrompt)
        autoTranscribe                  = try c.decodeIfPresent(Bool.self, forKey: .autoTranscribe)
        autoSummary                     = try c.decodeIfPresent(Bool.self, forKey: .autoSummary)
        autoActionItems                 = try c.decodeIfPresent(Bool.self, forKey: .autoActionItems)
        autoTags                        = try c.decodeIfPresent(Bool.self, forKey: .autoTags)
        recordingFolderPath             = try c.decodeIfPresent(String.self, forKey: .recordingFolderPath)
        transcriptionFolderPath         = try c.decodeIfPresent(String.self, forKey: .transcriptionFolderPath)
        obsidianVaultPath               = try c.decodeIfPresent(String.self, forKey: .obsidianVaultPath)
        obsidianDefaultFolderRelativePath = try c.decodeIfPresent(String.self, forKey: .obsidianDefaultFolderRelativePath)
        // Migration: if customVocabulary absent, try legacy "whisperPrompt" key
        if customVocabulary == nil {
            let legacyC = try decoder.container(keyedBy: LegacyKeys.self)
            if let legacy = try legacyC.decodeIfPresent(String.self, forKey: .whisperPrompt),
               !legacy.isEmpty {
                customVocabulary = legacy
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        }
    }
}
```

- [ ] **Step 2: In `AppSettings+Profiles.swift`, update `resetToDefault` (line 36)**

Find:
```swift
whisperPrompt = ""
```
Replace with:
```swift
customVocabulary = []
```

- [ ] **Step 3: In `AppSettings+Profiles.swift`, update the team meeting preset factory (line 143)**

Find:
```swift
whisperPrompt: teamMeetingWhisperPrompt,
```
Replace with:
```swift
customVocabulary: AppSettings.teamMeetingVocabulary,
```

- [ ] **Step 4: In `AppSettings+Profiles.swift`, update the sales meeting preset factory (line 159)**

Find:
```swift
whisperPrompt: salesMeetingWhisperPrompt,
```
Replace with:
```swift
customVocabulary: AppSettings.salesMeetingVocabulary,
```

- [ ] **Step 5: Update the export/import test to use the new field**

In `Tests/dBriefTests/ProfileBehaviorTests.swift`, find:
```swift
settings.profiles[index].overrides.whisperPrompt = "custom words"
```
Replace with:
```swift
settings.profiles[index].overrides.customVocabulary = ["custom", "words"]
```

Find:
```swift
#expect(exported.profiles[0].overrides.whisperPrompt == "custom words")
```
Replace with:
```swift
#expect(exported.profiles[0].overrides.customVocabulary == ["custom", "words"])
```

- [ ] **Step 6: Run the profile tests**

```bash
swift test --filter ProfileBehaviorTests 2>&1 | tail -20
```

Expected: All `ProfileBehaviorTests` pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/dBrief/Models/MeetingProfile.swift Sources/dBrief/App/AppSettings+Profiles.swift Tests/dBriefTests/ProfileBehaviorTests.swift
git commit -m "refactor: MeetingProfileOverrides.whisperPrompt→customVocabulary [String]? with Codable migration"
```

---

### Task 3: Update call sites — `RecordingManager` + `TranscriptSpellingService`

**Files:**
- Modify: `Sources/dBrief/Services/RecordingManager.swift`
- Modify: `Sources/dBrief/Services/TranscriptSpellingService.swift`

**Interfaces:**
- Consumes: `AppSettings.effectiveCustomVocabulary: [String]` (from Task 1)
- Consumes: `UnifiedInsightsPrompt.vocabularyBlock(_ customVocabulary: String) -> String` (unchanged — we join the array before passing)

- [ ] **Step 1: In `RecordingManager.swift`, fix the Apple Intelligence call (line ~1611)**

Find:
```swift
customVocabulary: appSettings.effectiveWhisperPrompt
```
(the one near the Apple Intelligence / `LocalAIService` call)

Replace with:
```swift
customVocabulary: appSettings.effectiveCustomVocabulary.joined(separator: ", ")
```

- [ ] **Step 2: In `RecordingManager.swift`, fix the MLX/Gemma plugin call (line ~1666)**

Find the second occurrence of:
```swift
customVocabulary: self.appSettings.effectiveWhisperPrompt
```
Replace with:
```swift
customVocabulary: self.appSettings.effectiveCustomVocabulary.joined(separator: ", ")
```

- [ ] **Step 3: In `RecordingManager.swift`, fix the Local CLI call (line ~1744)**

Find the third occurrence of:
```swift
customVocabulary: appSettings.effectiveWhisperPrompt
```
Replace with:
```swift
customVocabulary: appSettings.effectiveCustomVocabulary.joined(separator: ", ")
```

- [ ] **Step 4: In `RecordingManager.swift`, fix the `UnifiedInsightsPrompt.vocabularyBlock` call (line ~1780)**

Find:
```swift
prompt + UnifiedInsightsPrompt.vocabularyBlock(appSettings.effectiveWhisperPrompt)
```
Replace with:
```swift
prompt + UnifiedInsightsPrompt.vocabularyBlock(appSettings.effectiveCustomVocabulary.joined(separator: ", "))
```

- [ ] **Step 5: In `RecordingManager.swift`, fix the spelling-service guard (line ~2083)**

Find:
```swift
guard !TranscriptSpellingService.vocabularyTerms(from: appSettings.effectiveWhisperPrompt).isEmpty else {
```
Replace with:
```swift
guard !appSettings.effectiveCustomVocabulary.isEmpty else {
```

- [ ] **Step 6: In `TranscriptSpellingService.swift`, use the array directly**

Find the `correct(_:)` method body opening:
```swift
let terms = Self.vocabularyTerms(from: appSettings.effectiveWhisperPrompt)
```
Replace with:
```swift
let terms = appSettings.effectiveCustomVocabulary
```

- [ ] **Step 7: In `TranscriptSpellingService.swift`, delete the now-unused `vocabularyTerms(from:)` method**

Delete these lines entirely:
```swift
static func vocabularyTerms(from raw: String) -> [String] {
    raw
        .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}
```

- [ ] **Step 8: Build to verify no remaining `effectiveWhisperPrompt` or `whisperPrompt` references**

```bash
swift build 2>&1 | grep -E "error:" | head -20
grep -rn "effectiveWhisperPrompt\|whisperPrompt" Sources/ --include="*.swift"
```

Expected: `swift build` succeeds (no errors). `grep` returns only the UI files not yet updated (SettingsTranscriptionTab, SettingsProfilesTab) — those are fixed in Task 4.

- [ ] **Step 9: Commit**

```bash
git add Sources/dBrief/Services/RecordingManager.swift Sources/dBrief/Services/TranscriptSpellingService.swift
git commit -m "refactor: update call sites to effectiveCustomVocabulary [String]; remove vocabularyTerms(from:)"
```

---

### Task 4: Remove old vocabulary UI; update profile override row

**Files:**
- Modify: `Sources/dBrief/UI/SettingsTranscriptionTab.swift`
- Modify: `Sources/dBrief/UI/SettingsProfilesTab.swift`

**Interfaces:**
- Consumes: `MeetingProfileOverrides.customVocabulary: [String]?` (from Task 2)
- Consumes: `AppSettings.customVocabulary: [String]` (from Task 1)

- [ ] **Step 1: In `SettingsTranscriptionTab.swift`, remove the vocabulary section call**

Find and delete these lines (the engine-gated vocabulary block, around lines 59–65):
```swift
if appSettings.powerUserMode {
    if appSettings.transcriptionEngine == .localWhisper || appSettings.transcriptionEngine == .remoteEndpoint {
        Section("Custom Vocabulary") { vocabularySection }
            .listRowBackground(Color.clear)
    }
}
```

- [ ] **Step 2: In `SettingsTranscriptionTab.swift`, remove the `vocabularySection` computed property**

Find and delete this entire computed property (around lines 519–528):
```swift
private var vocabularySection: some View {
    @Bindable var settings = appSettings
    return VStack(alignment: .leading, spacing: 8) {
        Text("Helps Whisper recognize proper nouns, acronyms, and domain-specific terms. Press return or comma to add a term.")
            .font(.caption)
            .foregroundStyle(.secondary)
        TokenField(text: $settings.whisperPrompt, placeholder: "e.g. Acme Corp, JIRA, Kubernetes, GraphQL")
            .frame(minHeight: 22)
    }
}
```

- [ ] **Step 3: In `SettingsProfilesTab.swift`, add the CSV binding helper above `overrideRow`**

Find the `private func overrideBinding` method (around line 646) and insert this new helper immediately before it:

```swift
private func vocabularyCSVBinding() -> Binding<String> {
    let inner = overrideBinding(\.customVocabulary, fallback: appSettings.customVocabulary)
    return Binding(
        get: { inner.wrappedValue.joined(separator: ", ") },
        set: { str in
            inner.wrappedValue = str
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    )
}
```

- [ ] **Step 4: In `SettingsProfilesTab.swift`, replace the `whisperPrompt` override row**

Find (around lines 370–374):
```swift
overrideRow("Whisper prompt", \.whisperPrompt,
            defaultValue: appSettings.whisperPrompt) {
    NativeTextView(text: overrideBinding(\.whisperPrompt, fallback: appSettings.whisperPrompt))
        .frame(height: 70)
}
```
Replace with:
```swift
overrideRow("Vocabulary", \.customVocabulary,
            defaultValue: appSettings.customVocabulary) {
    TextField("e.g. Kubernetes, JIRA, Acme Corp", text: vocabularyCSVBinding())
}
```

- [ ] **Step 5: In `SettingsProfilesTab.swift`, update the `overrideGroupLabel` call for transcription**

Find (around line 393–396):
```swift
overrideGroupLabel("Transcription", keyPaths: [
    isSet(\.transcriptionEngine), isSet(\.transcriptionLanguage),
    isSet(\.whisperPrompt), isSet(\.transcriptionEndpointId)
])
```
Replace with:
```swift
overrideGroupLabel("Transcription", keyPaths: [
    isSet(\.transcriptionEngine), isSet(\.transcriptionLanguage),
    isSet(\.customVocabulary), isSet(\.transcriptionEndpointId)
])
```

- [ ] **Step 6: Build and verify no remaining `whisperPrompt` references**

```bash
swift build 2>&1 | grep "error:" | head -20
grep -rn "whisperPrompt" Sources/ --include="*.swift"
```

Expected: clean build; `grep` returns zero results.

- [ ] **Step 7: Run all tests**

```bash
swift test 2>&1 | tail -20
```

Expected: All tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/dBrief/UI/SettingsTranscriptionTab.swift Sources/dBrief/UI/SettingsProfilesTab.swift
git commit -m "feat: remove vocabulary from transcription tab; update profile override row to customVocabulary"
```

---

### Task 5: New Vocabulary tab — `SettingsView` + `SettingsVocabularyTab`

**Files:**
- Modify: `Sources/dBrief/UI/SettingsView.swift`
- Create: `Sources/dBrief/UI/SettingsVocabularyTab.swift`

**Interfaces:**
- Consumes: `AppSettings.customVocabulary: [String]` (from Task 1)

- [ ] **Step 1: In `SettingsView.swift`, add the `vocabulary` tab case**

Find:
```swift
case watchedFolders = "Watched Folders"
```
Insert the new case immediately before it:
```swift
case vocabulary     = "Vocabulary"
case watchedFolders = "Watched Folders"
```

- [ ] **Step 2: In `SettingsView.swift`, add the icon for the vocabulary tab**

Find the icon switch block. The `watchedFolders` case is:
```swift
case .watchedFolders: "folder.badge.gearshape"
```
Insert before it:
```swift
case .vocabulary:     "text.word.spacing"
```

- [ ] **Step 3: In `SettingsView.swift`, add the tab body case**

Find:
```swift
case .watchedFolders: SettingsWatchedFoldersTab()
```
Insert before it:
```swift
case .vocabulary:     SettingsVocabularyTab()
```

- [ ] **Step 4: Create `SettingsVocabularyTab.swift`**

Create the file `Sources/dBrief/UI/SettingsVocabularyTab.swift` with this content:

```swift
import SwiftUI

@MainActor
struct SettingsVocabularyTab: View {
    @Environment(AppSettings.self) private var appSettings
    @State private var editingIndex: Int? = nil
    @State private var editingText: String = ""
    @State private var newTermText: String = ""
    @State private var hoveredIndex: Int? = nil
    @FocusState private var editFocused: Bool

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Terms you add here help the AI understand your domain. After transcription, the AI corrects misspellings of these terms in the transcript. During analysis, they're provided to generate more accurate summaries and action items.")
                    Text("Add names, acronyms, product names, and technical terms your recordings commonly include.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Terms") {
                if appSettings.customVocabulary.isEmpty {
                    Text("No terms yet — add your first one below.")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                } else {
                    ForEach(Array(appSettings.customVocabulary.enumerated()), id: \.offset) { index, term in
                        termRow(index: index, term: term)
                    }
                }
            }

            Section {
                HStack {
                    TextField("Add a term…", text: $newTermText)
                        .onSubmit { addTerm() }
                    Button("Add") { addTerm() }
                        .disabled(newTermText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Vocabulary")
    }

    @ViewBuilder
    private func termRow(index: Int, term: String) -> some View {
        HStack {
            if editingIndex == index {
                TextField("", text: $editingText)
                    .focused($editFocused)
                    .onSubmit { commitEdit() }
                    .onExitCommand { cancelEdit() }
                    .onChange(of: editFocused) { _, focused in
                        if !focused { commitEdit() }
                    }
            } else {
                Text(term)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { startEdit(at: index, term: term) }
                    .onHover { isHovered in hoveredIndex = isHovered ? index : (hoveredIndex == index ? nil : hoveredIndex) }

                if hoveredIndex == index {
                    Button(role: .destructive) {
                        deleteTerm(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.1), value: hoveredIndex)
    }

    private func startEdit(at index: Int, term: String) {
        editingIndex = index
        editingText = term
        DispatchQueue.main.async { editFocused = true }
    }

    private func commitEdit() {
        guard let index = editingIndex else { return }
        editingIndex = nil
        let trimmed = editingText.trimmingCharacters(in: .whitespaces)
        editingText = ""
        guard !trimmed.isEmpty else { return }
        let isDuplicate = appSettings.customVocabulary.enumerated().contains { i, t in
            i != index && t.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        if !isDuplicate {
            @Bindable var settings = appSettings
            settings.customVocabulary[index] = trimmed
        }
    }

    private func cancelEdit() {
        editingIndex = nil
        editingText = ""
    }

    private func deleteTerm(at index: Int) {
        @Bindable var settings = appSettings
        settings.customVocabulary.remove(at: index)
        if hoveredIndex == index { hoveredIndex = nil }
    }

    private func addTerm() {
        let trimmed = newTermText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let isDuplicate = appSettings.customVocabulary.contains {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        if !isDuplicate {
            @Bindable var settings = appSettings
            settings.customVocabulary.append(trimmed)
        }
        newTermText = ""
    }
}
```

- [ ] **Step 5: Build**

```bash
swift build 2>&1 | grep "error:" | head -20
```

Expected: clean build, zero errors.

- [ ] **Step 6: Run all tests**

```bash
swift test 2>&1 | tail -20
```

Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/dBrief/UI/SettingsView.swift Sources/dBrief/UI/SettingsVocabularyTab.swift
git commit -m "feat: add Vocabulary settings tab with inline-editable term list"
```

---

## Self-Review Notes

- **Migration coverage:** AppSettings covers `stringArray` → `[String]` migration from legacy `whisperPrompt` key. `MeetingProfileOverrides.init(from:)` handles legacy `"whisperPrompt"` JSON key for persisted profiles. Both paths tested implicitly via the `ProfileBehaviorTests` round-trip test (Task 2, Step 6).
- **No remaining `whisperPrompt` references** after Task 4, Step 6 grep confirms zero hits.
- **`vocabularyTerms(from:)` removed** — its only callers were updated in Task 3.
- **`overrideRow` generic signature** accepts `[String]?` because `T` is unconstrained; confirmed from reading the function at lines 531–560 of SettingsProfilesTab.swift.
- **`encode(to:)` synthesized** for `MeetingProfileOverrides` — Swift synthesizes it independently from the manual `init(from:)`; output key will be `"customVocabulary"` (not `"whisperPrompt"`).
- **Tab visibility** — `vocabulary` is not in the `powerUserMode` guard in `visibleTabs`, so it's shown to all users.
