# WhisperKit Upgrade & Full Model Support

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade WhisperKit version pin, fix transcription hang introduced in 0.10.0+, and support all 27 models from the `argmaxinc/whisperkit-coreml` HuggingFace repository with dynamic model discovery.

**Architecture:** First fix the transcription hang (tokenizer download timeout + model loading observability). Then replace the hardcoded 2-model `WhisperModelSize` enum with a String-based model identifier. Add a `WhisperModelInfo` utility to parse HuggingFace model folder names into display metadata. Fetch available models from HuggingFace at runtime with offline fallback. Migrate existing user settings seamlessly.

**Tech Stack:** Swift 6.2, WhisperKit 0.18.0, SwiftUI, UserDefaults

---

## Context

### Current State
- `Package.swift` pins `from: "0.9.4"` but resolves to 0.18.0 via Package.resolved
- `WhisperModelSize` enum in `AppSettings.swift:140-165` has only `small` and `medium`
- Model names map to `openai_whisper-small` and `openai_whisper-medium`
- `WhisperRuntimeConfig` in `LocalAIPluginProtocol.swift:17-22` uses `modelSize: AppSettings.WhisperModelSize`
- `WhisperKitTranscriptionService.swift` passes `config.modelSize.modelName` to `WhisperKitConfig`
- UI picker in `SettingsTranscriptionTab.swift:77-83` iterates `WhisperModelSize.allCases`

### Known Regression: Transcription Hang
Transcription with WhisperKit 0.18.0 produces no log output and never completes. Root cause analysis identified three probable causes:

1. **Tokenizer download hang (highest probability)** — `loadTokenizer()` silently downloads from HuggingFace Hub with no timeout when local tokenizer isn't found. This was the root cause of [WhisperKit#340](https://github.com/argmaxinc/WhisperKit/issues/340).
2. **Model loading hang during init** — CoreML model compilation on first use can block indefinitely. The `WhisperKit(wkConfig)` init blocks at `loadModels()`.  
3. **v0.10.0 timestamp rules change** — `withoutTimestamps: false` now enforces timestamp rules, dramatically increasing seek iterations for long files.

The fix: enable WhisperKit's verbose logging and model state callbacks, add a `modelStateCallback` to track loading progress, and use `chunkingStrategy` for long files.

### Available Models on HuggingFace (`argmaxinc/whisperkit-coreml`)
```
openai_whisper-tiny              openai_whisper-tiny.en
openai_whisper-base              openai_whisper-base.en
openai_whisper-small             openai_whisper-small.en
openai_whisper-small_216MB       openai_whisper-small.en_217MB
openai_whisper-medium            openai_whisper-medium.en
openai_whisper-large-v2          openai_whisper-large-v2_949MB
openai_whisper-large-v2_turbo    openai_whisper-large-v2_turbo_955MB
openai_whisper-large-v3          openai_whisper-large-v3_947MB
openai_whisper-large-v3_turbo    openai_whisper-large-v3_turbo_954MB
openai_whisper-large-v3-v20240930          openai_whisper-large-v3-v20240930_547MB
openai_whisper-large-v3-v20240930_626MB    openai_whisper-large-v3-v20240930_turbo
openai_whisper-large-v3-v20240930_turbo_632MB
distil-whisper_distil-large-v3             distil-whisper_distil-large-v3_594MB
distil-whisper_distil-large-v3_turbo       distil-whisper_distil-large-v3_turbo_600MB
```

### WhisperKit 0.18.0 API (confirmed compatible)
- `WhisperKit.fetchAvailableModels(from:matching:token:) async throws -> [String]` — discovers models from HuggingFace
- `WhisperKit.recommendedModels() -> ModelSupport` — hardware-optimized recommendations
- All existing API calls (`WhisperKitConfig`, `DecodingOptions`, `transcribe(audioPath:decodeOptions:)`, `unloadModels()`) remain unchanged

---

## File Structure

| Action | File | Responsibility |
|--------|------|---------------|
| Modify | `Sources/dBrief/Services/WhisperKitTranscriptionService.swift:145-181` | Fix hang: verbose logging, model state callback, transcription timeout |
| Create | `Sources/dBrief/Models/WhisperModelInfo.swift` | Parse HF model folder names → display name, family, memory estimate, flags |
| Modify | `Package.swift:9` | Pin WhisperKit `from: "0.18.0"` |
| Modify | `Sources/dBrief/App/AppSettings.swift:52,140-165,286-288,570` | Replace `WhisperModelSize` enum with `whisperModelName: String`, add migration |
| Modify | `Sources/dBrief/Services/LocalAIPluginProtocol.swift:17-22` | Update `WhisperRuntimeConfig` to use `modelName: String` |
| Modify | `Sources/dBrief/Services/RecordingManager.swift:321,505,1109-1111` | Update `WhisperRuntimeConfig` construction |
| Modify | `Sources/dBrief/UI/SettingsTranscriptionTab.swift:12-13,76-126` | Dynamic model picker with HF fetching, recommended badge |
| Create | `Tests/dBriefTests/WhisperModelInfoTests.swift` | Tests for model name parsing and memory estimation |

---

### Task 1: Fix transcription hang with WhisperKit 0.18.0

**Files:**
- Modify: `Sources/dBrief/Services/WhisperKitTranscriptionService.swift:145-181`

This task addresses the runtime hang where `WhisperKit(wkConfig)` init or `transcribe()` never returns. Three changes: (a) enable WhisperKit verbose mode + model state callback for observability, (b) add timeout protection around the transcribe call, (c) set explicit language when user has configured one (avoids extra tokenizer round-trip).

- [ ] **Step 1: Add verbose logging and model state callback to WhisperKitConfig**

In `WhisperKitTranscriptionService.swift`, change the `loadWhisperKit` method. Replace the `WhisperKitConfig` construction (lines 165-173) from:

```swift
let wkConfig = WhisperKitConfig(
    model: config.modelSize.modelName,
    downloadBase: downloadBase,
    modelRepo: Self.modelRepo,
    computeOptions: computeOpts,
    prewarm: false,
    load: true,
    download: true
)
```

to:

```swift
let wkConfig = WhisperKitConfig(
    model: config.modelSize.modelName,
    downloadBase: downloadBase,
    modelRepo: Self.modelRepo,
    computeOptions: computeOpts,
    verbose: true,
    logLevel: .debug,
    prewarm: false,
    load: true,
    download: true
)
```

- [ ] **Step 2: Add model state callback for loading observability**

After creating `wkConfig` and before `WhisperKit(wkConfig)`, add a state callback. Replace lines ~175-179:

```swift
Logger.localAI.debug("Creating WhisperKit instance with downloadBase=\(downloadBase.path, privacy: .public)")
let whisper = try await WhisperKit(wkConfig)
self.whisperKit = whisper
self.loadedConfig = config
Logger.localAI.info("WhisperKit instance created and models loaded successfully")
```

with:

```swift
Logger.localAI.debug("Creating WhisperKit instance with downloadBase=\(downloadBase.path, privacy: .public)")
let whisper = try await WhisperKit(wkConfig)
whisper.modelStateCallback = { state in
    Logger.localAI.info("WhisperKit model state: \(String(describing: state), privacy: .public)")
}
self.whisperKit = whisper
self.loadedConfig = config
Logger.localAI.info("WhisperKit instance created and models loaded successfully")
```

- [ ] **Step 3: Add transcription timeout**

In the `transcribe()` method, wrap the `whisper.transcribe()` call (lines 68-71) with a timeout. Replace:

```swift
let wkResults = try await whisper.transcribe(
    audioPath: preparedURL.path,
    decodeOptions: options
)
```

with:

```swift
let wkResults = try await withThrowingTaskGroup(of: [WhisperKit.TranscriptionResult].self) { group in
    group.addTask {
        try await whisper.transcribe(
            audioPath: preparedURL.path,
            decodeOptions: options
        )
    }
    group.addTask {
        try await Task.sleep(for: .seconds(600))
        throw NSError(
            domain: "WhisperKitTranscriptionService",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Transcription timed out after 10 minutes. Try a shorter recording or Remote transcription."]
        )
    }
    let result = try await group.next()!
    group.cancelAll()
    return result
}
```

**Note:** The type `WhisperKit.TranscriptionResult` is the WhisperKit library's own result type (distinct from the app's `TranscriptionResult`). Use the fully qualified name to avoid ambiguity. If the compiler doesn't accept `WhisperKit.TranscriptionResult`, use the type returned by `whisper.transcribe()` directly — check by building.

- [ ] **Step 4: Pass user language setting when available**

In the `transcribe()` method, before the `DecodingOptions` setup (around line 54-63), accept the language from the runtime config. First update the method signature and `WhisperRuntimeConfig` to carry language (this is done in Task 3). For now, change the hardcoded language detection:

Replace:
```swift
options.language = nil
options.detectLanguage = true
```

with:

```swift
options.language = whisperConfig.language
options.detectLanguage = whisperConfig.language == nil
```

And in `LocalAIPluginProtocol.swift`, add `language` to `WhisperRuntimeConfig`:

```swift
struct WhisperRuntimeConfig: Sendable, Equatable {
    let modelSize: AppSettings.WhisperModelSize
    let computeUnits: AppSettings.WhisperComputeUnits
    let language: String?

    static let `default` = WhisperRuntimeConfig(modelSize: .small, computeUnits: .all, language: nil)
}
```

And update the `RecordingManager` call site (~line 1109) to pass the language:
```swift
let whisperConfig = WhisperRuntimeConfig(
    modelSize: appSettings.whisperModelSize,
    computeUnits: appSettings.whisperComputeUnits,
    language: appSettings.transcriptionLanguage.isEmpty ? nil : appSettings.transcriptionLanguage
)
```

- [ ] **Step 5: Build and verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete!

- [ ] **Step 6: Manual verification**

Test with a short audio file (under 1 minute). Check Console.app logs for:
1. `WhisperKit model state:` lines (confirms model loading is observable)
2. `WhisperKit loading:` and `WhisperKit instance created` (confirms init completes)
3. `whisper.transcribe completed` (confirms transcription finishes)

If the hang persists, the verbose WhisperKit logs in Console.app will now show exactly where it blocks.

- [ ] **Step 7: Commit**

```bash
git add Sources/dBrief/Services/WhisperKitTranscriptionService.swift Sources/dBrief/Services/LocalAIPluginProtocol.swift Sources/dBrief/Services/RecordingManager.swift
git commit -m "fix: prevent WhisperKit transcription hang with verbose logging and timeout

Enable WhisperKit verbose mode and model state callback for observability.
Add 10-minute timeout on transcribe() to prevent indefinite hangs.
Pass user language setting to avoid extra tokenizer network round-trip."
```

---

### Task 2: Create WhisperModelInfo utility

**Files:**
- Create: `Sources/dBrief/Models/WhisperModelInfo.swift`
- Test: `Tests/dBriefTests/WhisperModelInfoTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import dBrief

struct WhisperModelInfoTests {
    @Test
    func parsesBasicModelName() {
        let info = WhisperModelInfo.parse("openai_whisper-small")
        #expect(info.id == "openai_whisper-small")
        #expect(info.displayName == "Whisper Small")
        #expect(info.family == "small")
        #expect(!info.isEnglishOnly)
        #expect(!info.isTurbo)
        #expect(info.quantizedSizeMB == nil)
    }

    @Test
    func parsesEnglishOnlyModel() {
        let info = WhisperModelInfo.parse("openai_whisper-small.en")
        #expect(info.displayName == "Whisper Small (English)")
        #expect(info.family == "small")
        #expect(info.isEnglishOnly)
    }

    @Test
    func parsesQuantizedTurboModel() {
        let info = WhisperModelInfo.parse("openai_whisper-large-v3_turbo_954MB")
        #expect(info.displayName == "Whisper Large V3 Turbo (954 MB)")
        #expect(info.family == "large-v3")
        #expect(info.isTurbo)
        #expect(info.quantizedSizeMB == 954)
        #expect(!info.isEnglishOnly)
    }

    @Test
    func parsesDistilModel() {
        let info = WhisperModelInfo.parse("distil-whisper_distil-large-v3_turbo_600MB")
        #expect(info.displayName == "Distil Large V3 Turbo (600 MB)")
        #expect(info.family == "distil-large-v3")
        #expect(info.isTurbo)
        #expect(info.quantizedSizeMB == 600)
    }

    @Test
    func parsesLargeV3September() {
        let info = WhisperModelInfo.parse("openai_whisper-large-v3-v20240930_626MB")
        #expect(info.displayName == "Whisper Large V3 Sep24 (626 MB)")
        #expect(info.family == "large-v3-v20240930")
        #expect(info.quantizedSizeMB == 626)
    }

    @Test
    func memoryEstimationByFamily() {
        #expect(WhisperModelInfo.parse("openai_whisper-tiny").estimatedMemoryBytes == 500_000_000)
        #expect(WhisperModelInfo.parse("openai_whisper-base").estimatedMemoryBytes == 800_000_000)
        #expect(WhisperModelInfo.parse("openai_whisper-small").estimatedMemoryBytes == 2_000_000_000)
        #expect(WhisperModelInfo.parse("openai_whisper-medium").estimatedMemoryBytes == 3_000_000_000)
        #expect(WhisperModelInfo.parse("openai_whisper-large-v3").estimatedMemoryBytes == 5_000_000_000)
        #expect(WhisperModelInfo.parse("distil-whisper_distil-large-v3").estimatedMemoryBytes == 5_000_000_000)
    }

    @Test
    func memoryEstimationQuantizedModelsUseLowerEstimate() {
        let full = WhisperModelInfo.parse("openai_whisper-large-v3")
        let quantized = WhisperModelInfo.parse("openai_whisper-large-v3_947MB")
        #expect(quantized.estimatedMemoryBytes < full.estimatedMemoryBytes)
    }

    @Test
    func sortOrderPutsSmallBeforeLarge() {
        let models = [
            "openai_whisper-large-v3",
            "openai_whisper-tiny",
            "openai_whisper-small",
            "openai_whisper-medium",
            "openai_whisper-base",
        ].map { WhisperModelInfo.parse($0) }

        let sorted = models.sorted()
        #expect(sorted.map(\.family) == ["tiny", "base", "small", "medium", "large-v3"])
    }

    @Test
    func fallbackListContainsCoreModels() {
        let fallback = WhisperModelInfo.fallbackModelNames
        #expect(fallback.contains("openai_whisper-tiny"))
        #expect(fallback.contains("openai_whisper-small"))
        #expect(fallback.contains("openai_whisper-medium"))
        #expect(fallback.contains("openai_whisper-large-v3"))
        #expect(fallback.contains("openai_whisper-large-v3_turbo"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WhisperModelInfoTests 2>&1 | tail -5`
Expected: compilation error — `WhisperModelInfo` does not exist

- [ ] **Step 3: Implement WhisperModelInfo**

Create `Sources/dBrief/Models/WhisperModelInfo.swift`:

```swift
import Foundation

struct WhisperModelInfo: Sendable, Equatable, Comparable {
    let id: String
    let displayName: String
    let family: String
    let isEnglishOnly: Bool
    let isTurbo: Bool
    let quantizedSizeMB: Int?
    let estimatedMemoryBytes: Int64

    /// Parse a HuggingFace model folder name into structured metadata.
    /// Examples: "openai_whisper-small", "openai_whisper-large-v3_turbo_954MB", "distil-whisper_distil-large-v3"
    static func parse(_ modelName: String) -> WhisperModelInfo {
        let isEnglish = modelName.hasSuffix(".en") || modelName.contains(".en_")
        let isTurbo = modelName.contains("_turbo")

        // Extract quantized size: trailing _NNNmb pattern
        let quantizedMB: Int? = {
            let pattern = #"_(\d+)MB"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: modelName, range: NSRange(modelName.startIndex..., in: modelName)),
                  let range = Range(match.range(at: 1), in: modelName) else { return nil }
            return Int(modelName[range])
        }()

        // Extract family from the model name
        let family = extractFamily(from: modelName)
        let displayName = buildDisplayName(family: family, isEnglish: isEnglish, isTurbo: isTurbo, quantizedMB: quantizedMB, modelName: modelName)
        let memory = estimateMemory(family: family, quantizedMB: quantizedMB)

        return WhisperModelInfo(
            id: modelName,
            displayName: displayName,
            family: family,
            isEnglishOnly: isEnglish,
            isTurbo: isTurbo,
            quantizedSizeMB: quantizedMB,
            estimatedMemoryBytes: memory
        )
    }

    // MARK: - Comparable (sort by model size ascending)

    private static let familyOrder: [String: Int] = [
        "tiny": 0, "base": 1, "small": 2, "medium": 3,
        "large-v2": 4, "large-v3": 5, "large-v3-v20240930": 6,
        "distil-large-v3": 7,
    ]

    static func < (lhs: WhisperModelInfo, rhs: WhisperModelInfo) -> Bool {
        let lhsOrder = familyOrder[lhs.family] ?? 99
        let rhsOrder = familyOrder[rhs.family] ?? 99
        if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
        // Within same family: non-english before english, non-turbo before turbo, full before quantized
        if lhs.isEnglishOnly != rhs.isEnglishOnly { return !lhs.isEnglishOnly }
        if lhs.isTurbo != rhs.isTurbo { return !lhs.isTurbo }
        return (lhs.quantizedSizeMB ?? Int.max) > (rhs.quantizedSizeMB ?? Int.max)
    }

    /// Offline fallback list of core model names.
    static let fallbackModelNames: [String] = [
        "openai_whisper-tiny",
        "openai_whisper-tiny.en",
        "openai_whisper-base",
        "openai_whisper-base.en",
        "openai_whisper-small",
        "openai_whisper-small.en",
        "openai_whisper-medium",
        "openai_whisper-medium.en",
        "openai_whisper-large-v2",
        "openai_whisper-large-v2_turbo",
        "openai_whisper-large-v3",
        "openai_whisper-large-v3_turbo",
        "openai_whisper-large-v3-v20240930",
        "openai_whisper-large-v3-v20240930_turbo",
        "distil-whisper_distil-large-v3",
        "distil-whisper_distil-large-v3_turbo",
    ]

    // MARK: - Private helpers

    private static func extractFamily(from modelName: String) -> String {
        // Remove prefix: "openai_whisper-" or "distil-whisper_distil-"
        var name = modelName
        if name.hasPrefix("openai_whisper-") {
            name = String(name.dropFirst("openai_whisper-".count))
        } else if name.hasPrefix("distil-whisper_distil-") {
            name = String(name.dropFirst("distil-whisper_distil-".count))
            // Re-add "distil-" prefix for family identification
            name = "distil-" + name
        }

        // Strip suffixes: .en, _turbo, _NNNMB
        name = name.replacingOccurrences(of: #"\.en"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: "_turbo", with: "")
        name = name.replacingOccurrences(of: #"_\d+MB"#, with: "", options: .regularExpression)

        // Clean trailing underscores
        while name.hasSuffix("_") { name = String(name.dropLast()) }

        return name
    }

    private static func buildDisplayName(family: String, isEnglish: Bool, isTurbo: Bool, quantizedMB: Int?, modelName: String) -> String {
        // Map family to human-readable base name
        let baseName: String
        let isDistil = modelName.hasPrefix("distil-whisper")
        switch family {
        case "tiny":                 baseName = "Whisper Tiny"
        case "base":                 baseName = "Whisper Base"
        case "small":                baseName = "Whisper Small"
        case "medium":               baseName = "Whisper Medium"
        case "large-v2":             baseName = "Whisper Large V2"
        case "large-v3":             baseName = "Whisper Large V3"
        case "large-v3-v20240930":   baseName = "Whisper Large V3 Sep24"
        case "distil-large-v3":      baseName = "Distil Large V3"
        default:                     baseName = isDistil ? "Distil \(family.capitalized)" : "Whisper \(family.capitalized)"
        }

        var parts = [baseName]
        if isTurbo { parts.append("Turbo") }
        var result = parts.joined(separator: " ")
        
        // Suffix qualifiers in parentheses
        var qualifiers: [String] = []
        if isEnglish { qualifiers.append("English") }
        if let mb = quantizedMB { qualifiers.append("\(mb) MB") }
        if !qualifiers.isEmpty {
            result += " (\(qualifiers.joined(separator: ", ")))"
        }

        return result
    }

    private static func estimateMemory(family: String, quantizedMB: Int?) -> Int64 {
        // Base memory per family (model + runtime buffer)
        let baseMemory: Int64
        switch family {
        case "tiny":                            baseMemory = 500_000_000      // 0.5 GB
        case "base":                            baseMemory = 800_000_000      // 0.8 GB
        case "small":                           baseMemory = 2_000_000_000    // 2 GB
        case "medium":                          baseMemory = 3_000_000_000    // 3 GB
        case _ where family.contains("large"):  baseMemory = 5_000_000_000    // 5 GB
        default:                                baseMemory = 2_000_000_000    // safe default
        }

        // Quantized models need less memory — scale down proportionally
        if let mb = quantizedMB {
            // Use quantized size + 1 GB runtime buffer as estimate
            return Int64(mb) * 1_000_000 + 1_000_000_000
        }

        return baseMemory
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WhisperModelInfoTests 2>&1 | tail -10`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Models/WhisperModelInfo.swift Tests/dBriefTests/WhisperModelInfoTests.swift
git commit -m "feat: add WhisperModelInfo parser for HuggingFace model names"
```

---

### Task 3: Update Package.swift version constraint

**Files:**
- Modify: `Package.swift:9`

- [ ] **Step 1: Update the version pin**

In `Package.swift:9`, change:
```swift
.package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.4"),
```
to:
```swift
.package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.18.0"),
```

- [ ] **Step 2: Resolve and verify**

Run: `swift package resolve && swift build 2>&1 | tail -5`
Expected: Build successful, Package.resolved still shows 0.18.0

- [ ] **Step 3: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "chore: pin WhisperKit minimum to 0.18.0"
```

---

### Task 4: Update WhisperRuntimeConfig and AppSettings

**Files:**
- Modify: `Sources/dBrief/Services/LocalAIPluginProtocol.swift:17-22`
- Modify: `Sources/dBrief/App/AppSettings.swift:52,140-165,286-288,570`

- [ ] **Step 1: Update WhisperRuntimeConfig**

In `Sources/dBrief/Services/LocalAIPluginProtocol.swift`, `WhisperRuntimeConfig` was updated in Task 1 to add `language`. Now replace `modelSize` with `modelName`. Change from:
```swift
struct WhisperRuntimeConfig: Sendable, Equatable {
    let modelSize: AppSettings.WhisperModelSize
    let computeUnits: AppSettings.WhisperComputeUnits
    let language: String?

    static let `default` = WhisperRuntimeConfig(modelSize: .small, computeUnits: .all, language: nil)
}
```
to:
```swift
struct WhisperRuntimeConfig: Sendable, Equatable {
    let modelName: String
    let computeUnits: AppSettings.WhisperComputeUnits
    let language: String?

    static let `default` = WhisperRuntimeConfig(modelName: "openai_whisper-small", computeUnits: .all, language: nil)
}
```

- [ ] **Step 2: Replace WhisperModelSize enum in AppSettings**

In `Sources/dBrief/App/AppSettings.swift`, **remove** the `WhisperModelSize` enum (lines 140-165):
```swift
enum WhisperModelSize: String, CaseIterable, Codable, Hashable, Sendable {
    case small
    case medium
    // ... entire enum
}
```

- [ ] **Step 3: Update AppSettings property and Keys**

In `Sources/dBrief/App/AppSettings.swift`, change the Keys constant at line 52 from:
```swift
static let whisperModelSize = "whisperModelSize"
```
to:
```swift
static let whisperModelName = "whisperModelName"
```

Change the property at lines 286-288 from:
```swift
var whisperModelSize: WhisperModelSize {
    didSet { UserDefaults.standard.set(whisperModelSize.rawValue, forKey: Keys.whisperModelSize) }
}
```
to:
```swift
var whisperModelName: String {
    didSet { UserDefaults.standard.set(whisperModelName, forKey: Keys.whisperModelName) }
}
```

- [ ] **Step 4: Add migration in AppSettings.init**

In `Sources/dBrief/App/AppSettings.swift`, change the initialization at line 570 from:
```swift
self.whisperModelSize = WhisperModelSize(rawValue: defaults.string(forKey: Keys.whisperModelSize) ?? "") ?? .small
```
to:
```swift
self.whisperModelName = {
    // New key takes priority
    if let name = defaults.string(forKey: Keys.whisperModelName), !name.isEmpty {
        return name
    }
    // Migrate from old enum-based key
    switch defaults.string(forKey: "whisperModelSize") ?? "" {
    case "small":  return "openai_whisper-small"
    case "medium": return "openai_whisper-medium"
    default:       return "openai_whisper-small"
    }
}()
```

- [ ] **Step 5: Verify build compiles**

Run: `swift build 2>&1 | grep -E "(error|Build complete)" | head -10`
Expected: Build errors in RecordingManager and SettingsTranscriptionTab (expected — fixed in Tasks 5, 6 & 7)

- [ ] **Step 6: Commit**

```bash
git add Sources/dBrief/Services/LocalAIPluginProtocol.swift Sources/dBrief/App/AppSettings.swift
git commit -m "refactor: replace WhisperModelSize enum with string-based model name

Migrates existing user settings from old enum values (small/medium)
to HuggingFace model folder names (openai_whisper-small/medium)."
```

---

### Task 5: Update WhisperKitTranscriptionService for string model names

**Files:**
- Modify: `Sources/dBrief/Services/WhisperKitTranscriptionService.swift:25-41,145-181`

- [ ] **Step 1: Update memory gate in transcribe()**

In `WhisperKitTranscriptionService.swift`, change lines 29-41 from:
```swift
let requiredMemory = whisperConfig.modelSize.requiredFreeMemory
let hasSufficientMemory = await MainActor.run {
    MemoryPressureMonitor.hasSufficientMemory(requiredBytes: requiredMemory)
}
guard hasSufficientMemory else {
    throw NSError(
        domain: "WhisperKitTranscriptionService",
        code: 4,
        userInfo: [
            NSLocalizedDescriptionKey: "Insufficient memory to load \(whisperConfig.modelSize.displayName). Need at least \(String(format: "%.1f", Double(requiredMemory) / 1_000_000_000)) GB free. Close other apps or use Remote transcription instead."
        ]
    )
}
```
to:
```swift
let modelInfo = WhisperModelInfo.parse(whisperConfig.modelName)
let requiredMemory = modelInfo.estimatedMemoryBytes
let hasSufficientMemory = await MainActor.run {
    MemoryPressureMonitor.hasSufficientMemory(requiredBytes: requiredMemory)
}
guard hasSufficientMemory else {
    throw NSError(
        domain: "WhisperKitTranscriptionService",
        code: 4,
        userInfo: [
            NSLocalizedDescriptionKey: "Insufficient memory to load \(modelInfo.displayName). Need at least \(String(format: "%.1f", Double(requiredMemory) / 1_000_000_000)) GB free. Close other apps or use Remote transcription instead."
        ]
    )
}
```

- [ ] **Step 2: Update loadWhisperKit config construction**

In `WhisperKitTranscriptionService.swift`, change the log line at ~162 from:
```swift
Logger.localAI.info(
    "WhisperKit loading: model=\(config.modelSize.modelName, privacy: .public) computeUnits=\(config.computeUnits.rawValue, privacy: .public) metalGPU=\(Self.hasMetalGPU, privacy: .public)"
)
```
to:
```swift
Logger.localAI.info(
    "WhisperKit loading: model=\(config.modelName, privacy: .public) computeUnits=\(config.computeUnits.rawValue, privacy: .public) metalGPU=\(Self.hasMetalGPU, privacy: .public)"
)
```

And in the `WhisperKitConfig` construction (already modified in Task 1 to add verbose/logLevel), update the `model:` parameter from `config.modelSize.modelName` to `config.modelName`:
```swift
let wkConfig = WhisperKitConfig(
    model: config.modelName,       // was: config.modelSize.modelName
    downloadBase: downloadBase,
    modelRepo: Self.modelRepo,
    computeOptions: computeOpts,
    verbose: true,
    logLevel: .debug,
    prewarm: false,
    load: true,
    download: true
)
```

- [ ] **Step 3: Verify build compiles (this file only)**

Run: `swift build 2>&1 | grep "WhisperKitTranscriptionService" | head -5`
Expected: No errors in this file (remaining errors expected in RecordingManager/UI)

- [ ] **Step 4: Commit**

```bash
git add Sources/dBrief/Services/WhisperKitTranscriptionService.swift
git commit -m "refactor: use string model name in WhisperKitTranscriptionService

Dynamic memory estimation via WhisperModelInfo replaces hardcoded enum values."
```

---

### Task 6: Update RecordingManager

**Files:**
- Modify: `Sources/dBrief/Services/RecordingManager.swift:321,505,1109-1111`

- [ ] **Step 1: Update WhisperRuntimeConfig construction**

In `RecordingManager.swift`, at line ~1109-1112, the config was already updated in Task 1 to add `language`. Now update `modelSize` → `modelName`. Change from:
```swift
let whisperConfig = WhisperRuntimeConfig(
    modelSize: appSettings.whisperModelSize,
    computeUnits: appSettings.whisperComputeUnits,
    language: appSettings.transcriptionLanguage.isEmpty ? nil : appSettings.transcriptionLanguage
)
```
to:
```swift
let whisperConfig = WhisperRuntimeConfig(
    modelName: appSettings.whisperModelName,
    computeUnits: appSettings.whisperComputeUnits,
    language: appSettings.transcriptionLanguage.isEmpty ? nil : appSettings.transcriptionLanguage
)
```

- [ ] **Step 2: Update model name display strings**

At line ~321, change:
```swift
case .localWhisper: Endpoint(name: "WhisperKit", baseURL: "", modelName: "\(appSettings.whisperModelSize.modelName) (CoreML)")
```
to:
```swift
case .localWhisper: Endpoint(name: "WhisperKit", baseURL: "", modelName: "\(appSettings.whisperModelName) (CoreML)")
```

At line ~505 (same pattern), apply the identical change:
```swift
case .localWhisper: Endpoint(name: "WhisperKit", baseURL: "", modelName: "\(appSettings.whisperModelName) (CoreML)")
```

- [ ] **Step 3: Update MemoryThreshold for whisperKit**

At line ~29, the `MemoryThreshold.whisperKit` constant is hardcoded. Change:
```swift
static let whisperKit: Int64 = 1_288_490_189   // 1.2 GB
```

Search for where `MemoryThreshold.whisperKit` is used and replace with dynamic estimation. Find the usage (likely in a memory check guard) and replace `MemoryThreshold.whisperKit` with:
```swift
WhisperModelInfo.parse(appSettings.whisperModelName).estimatedMemoryBytes
```

If `MemoryThreshold.whisperKit` is only used in one place and the dynamic value is a clean substitute, remove the constant entirely. If it's used as a fallback elsewhere, keep it but set it to `2_000_000_000` (2 GB — covers small model, the default).

- [ ] **Step 4: Build and verify**

Run: `swift build 2>&1 | grep -E "(error|Build complete)" | head -10`
Expected: Remaining errors only in SettingsTranscriptionTab (fixed in Task 7)

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Services/RecordingManager.swift
git commit -m "refactor: use string model name in RecordingManager"
```

---

### Task 7: Update Settings UI with dynamic model picker

**Files:**
- Modify: `Sources/dBrief/UI/SettingsTranscriptionTab.swift:12-13,76-126`

- [ ] **Step 1: Add state for fetched models**

At the top of `SettingsTranscriptionTab` (around line 12-14), add state properties. Change the existing state block to include:

```swift
@State private var whisperModels: [WhisperModelInfo] = []
@State private var isFetchingWhisperModels = false
@State private var whisperModelFetchError: String?
```

- [ ] **Step 2: Add model fetching method**

Add a private method to the struct:

```swift
private func fetchWhisperModels() {
    guard !isFetchingWhisperModels else { return }
    isFetchingWhisperModels = true
    whisperModelFetchError = nil
    Task {
        do {
            let modelNames = try await WhisperKit.fetchAvailableModels(
                from: "argmaxinc/whisperkit-coreml"
            )
            whisperModels = modelNames.map { WhisperModelInfo.parse($0) }.sorted()
        } catch {
            whisperModels = WhisperModelInfo.fallbackModelNames
                .map { WhisperModelInfo.parse($0) }.sorted()
            whisperModelFetchError = "Using offline model list — couldn't reach HuggingFace."
        }
        isFetchingWhisperModels = false
    }
}
```

Add `import WhisperKit` at the top of the file (after `import Metal`).

- [ ] **Step 3: Replace the model picker in engineSection**

Replace the local whisper section (lines ~76-126) with:

```swift
case .localWhisper:
    VStack(alignment: .leading, spacing: 8) {
        LabeledContent("Model:") {
            if isFetchingWhisperModels && whisperModels.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 280, alignment: .trailing)
            } else {
                Picker("", selection: $settings.whisperModelName) {
                    if whisperModels.isEmpty {
                        Text("openai_whisper-small").tag("openai_whisper-small")
                    } else {
                        ForEach(whisperModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 280, alignment: .trailing)
            }
        }

        LabeledContent("GPU acceleration:") {
            Picker("", selection: $settings.whisperComputeUnits) {
                ForEach(AppSettings.WhisperComputeUnits.allCases, id: \.self) { units in
                    Text(units.displayName).tag(units)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 280, alignment: .trailing)
        }

        if !hasMetalGPU {
            Label("No Metal GPU detected — GPU options will fall back to Neural Engine.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        if let error = whisperModelFetchError {
            Label(error, systemImage: "wifi.slash")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        HStack {
            Text("On-device transcription using WhisperKit. Audio never leaves your Mac. Models downloaded once from HuggingFace.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                fetchWhisperModels()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Refresh model list from HuggingFace")
        }

        Button("Purge local WhisperKit model") {
            Task {
                do {
                    try await recordingManager.purgeLocalWhisperModel()
                    purgeMessage = "Local WhisperKit model cache removed."
                } catch {
                    purgeMessage = error.localizedDescription
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        if let purgeMessage {
            Text(purgeMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
    .onAppear { fetchWhisperModels() }
```

- [ ] **Step 4: Build and verify full project compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete!

- [ ] **Step 5: Run all tests**

Run: `swift test 2>&1 | tail -15`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add Sources/dBrief/UI/SettingsTranscriptionTab.swift
git commit -m "feat: dynamic WhisperKit model picker with HuggingFace discovery

Fetches all available models from argmaxinc/whisperkit-coreml at runtime.
Falls back to curated offline list when HuggingFace is unreachable.
Shows model display names parsed from folder names with size estimates."
```

---

### Task 8: Verify and clean up

**Files:**
- All modified files

- [ ] **Step 1: Full build**

Run: `swift build -c release 2>&1 | tail -5`
Expected: Build complete!

- [ ] **Step 2: Run all tests**

Run: `swift test 2>&1 | tail -15`
Expected: All tests pass (including new WhisperModelInfoTests)

- [ ] **Step 3: Verify no remaining references to WhisperModelSize**

Run: `grep -r "WhisperModelSize" Sources/ Tests/`
Expected: No matches (the enum has been fully removed)

- [ ] **Step 4: Verify no remaining references to old key**

Run: `grep -r "whisperModelSize" Sources/ --include="*.swift" | grep -v "// Migration"`
Expected: Only the migration code in AppSettings.init (reading old key for backward compat)

- [ ] **Step 5: Build app bundle**

Run: `make app 2>&1 | tail -5`
Expected: App bundle builds successfully

- [ ] **Step 6: Commit any cleanup**

If any issues were found and fixed, commit them. Otherwise skip.

```bash
git add -A
git commit -m "chore: clean up WhisperKit upgrade — remove stale references"
```
