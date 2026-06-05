# Integration & Calendar Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hide untested integrations (Notion, Evernote, Google Keep, OneNote) from Settings and dispatch, and make the Outlook calendar source appear only when a real Azure client ID is configured.

**Architecture:** One source of truth per area, consulted by both UI and runtime. A static `IntegrationDestination.available` list gates both the Settings list and the dispatch service. A `MicrosoftAuthService.isConfigured` flag gates the Outlook picker row, and an `effectiveCalendarSource` computed property coerces a stale persisted `.outlook` to `.disabled` when unconfigured.

**Tech Stack:** Swift 6.2, SwiftUI, swift-testing. Test runner: `swift test`.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `Sources/dBrief/Models/Integrations.swift` | `IntegrationDestination` enum | Add `available` static list |
| `Sources/dBrief/Services/MicrosoftAuthService.swift` | Outlook OAuth | Add `placeholderClientID`, `isConfigured` |
| `Sources/dBrief/App/AppSettings+EffectiveSettings.swift` | Profile/effective resolution | Add `resolveCalendarSource`, `effectiveCalendarSource` |
| `Sources/dBrief/UI/SettingsIntegrationsTab.swift` | Integrations settings UI | Iterate `available` |
| `Sources/dBrief/Services/IntegrationDispatchService.swift` | Post-recording dispatch | Guard hidden destinations |
| `Sources/dBrief/UI/SettingsGeneralTab.swift` | Calendar source picker | Conditional Outlook row |
| `Sources/dBrief/Services/RecordingManager.swift` | Record-start calendar lookup | Use `effectiveCalendarSource` |
| `Sources/dBrief/UI/PostRecordingSheet.swift` | Post-recording calendar lookup | Use `effectiveCalendarSource` |
| `Tests/dBriefTests/IntegrationVisibilityTests.swift` | New tests | Create |

---

## Task 1: Integration availability source of truth

**Files:**
- Modify: `Sources/dBrief/Models/Integrations.swift:3-27`
- Test: `Tests/dBriefTests/IntegrationVisibilityTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/dBriefTests/IntegrationVisibilityTests.swift`:

```swift
import Testing
@testable import dBrief

struct IntegrationVisibilityTests {
    @Test("available lists exactly the four trusted destinations")
    func testAvailableTrustedOnly() {
        #expect(IntegrationDestination.available == [.obsidian, .appleNotes, .appleReminders, .webhook])
    }

    @Test("available excludes untested destinations")
    func testAvailableExcludesUntested() {
        #expect(!IntegrationDestination.available.contains(.notion))
        #expect(!IntegrationDestination.available.contains(.evernote))
        #expect(!IntegrationDestination.available.contains(.googleKeep))
        #expect(!IntegrationDestination.available.contains(.oneNote))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter IntegrationVisibilityTests`
Expected: FAIL to compile — `available` is not a member of `IntegrationDestination`.

- [ ] **Step 3: Add the `available` list**

In `Sources/dBrief/Models/Integrations.swift`, add inside the `IntegrationDestination` enum, after the `displayName` computed property (after line 26, before the closing brace at line 27):

```swift
    /// Destinations currently exposed to users. Untested integrations
    /// (Notion, Evernote, Google Keep, OneNote) are omitted until verified.
    /// Re-enable one by adding its case back to this list.
    static let available: [IntegrationDestination] = [
        .obsidian, .appleNotes, .appleReminders, .webhook,
    ]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter IntegrationVisibilityTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Models/Integrations.swift Tests/dBriefTests/IntegrationVisibilityTests.swift
git commit -m "feat(integrations): add IntegrationDestination.available source of truth"
```

---

## Task 2: Hide untested integrations in Settings UI

**Files:**
- Modify: `Sources/dBrief/UI/SettingsIntegrationsTab.swift:9-24`

This is a SwiftUI view change with no unit test; verify by build + manual check.

- [ ] **Step 1: Replace the hardcoded order with `available`**

In `Sources/dBrief/UI/SettingsIntegrationsTab.swift`, delete the private `integrationOrder` array (lines 9-18):

```swift
    private let integrationOrder: [IntegrationDestination] = [
        .obsidian,
        .appleNotes,
        .appleReminders,
        .notion,
        .evernote,
        .googleKeep,
        .oneNote,
        .webhook,
    ]
```

Then change the `ForEach` (line 24) from:

```swift
                    ForEach(integrationOrder, id: \.self) { destination in
```

to:

```swift
                    ForEach(IntegrationDestination.available, id: \.self) { destination in
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds. (If any other reference to `integrationOrder` remains in the file, replace it with `IntegrationDestination.available`.)

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/UI/SettingsIntegrationsTab.swift
git commit -m "feat(integrations): show only available destinations in settings"
```

---

## Task 3: Guard hidden integrations in dispatch

**Files:**
- Modify: `Sources/dBrief/Services/IntegrationDispatchService.swift:46-68`

Prevents a previously-enabled hidden integration from silently dispatching. Correctness of the guard follows from Task 1's list test; verify by build.

- [ ] **Step 1: Add availability guards to the four hidden destinations**

In `Sources/dBrief/Services/IntegrationDispatchService.swift`, update each of the four `if` conditions. Change line 46 from:

```swift
        if snapshot.config.notion.enabled {
```

to:

```swift
        if IntegrationDestination.available.contains(.notion), snapshot.config.notion.enabled {
```

Change line 52 from:

```swift
        if snapshot.config.evernote.enabled {
```

to:

```swift
        if IntegrationDestination.available.contains(.evernote), snapshot.config.evernote.enabled {
```

Change line 58 from:

```swift
        if snapshot.config.googleKeep.enabled {
```

to:

```swift
        if IntegrationDestination.available.contains(.googleKeep), snapshot.config.googleKeep.enabled {
```

Change line 64 from:

```swift
        if snapshot.config.oneNote.enabled {
```

to:

```swift
        if IntegrationDestination.available.contains(.oneNote), snapshot.config.oneNote.enabled {
```

Leave `.appleNotes`, `.appleReminders`, and `.webhook` unchanged (they are in `available`).

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/Services/IntegrationDispatchService.swift
git commit -m "feat(integrations): skip dispatch for unavailable destinations"
```

---

## Task 4: MicrosoftAuthService.isConfigured

**Files:**
- Modify: `Sources/dBrief/Services/MicrosoftAuthService.swift:22`
- Test: `Tests/dBriefTests/IntegrationVisibilityTests.swift`

- [ ] **Step 1: Write the failing test**

Add to the `IntegrationVisibilityTests` struct in `Tests/dBriefTests/IntegrationVisibilityTests.swift`:

```swift
    @Test("isConfigured is false for placeholder and empty client IDs")
    @MainActor
    func testIsConfiguredFalseForPlaceholder() {
        #expect(MicrosoftAuthService.isConfigured(clientID: "YOUR-AZURE-CLIENT-ID") == false)
        #expect(MicrosoftAuthService.isConfigured(clientID: "") == false)
    }

    @Test("isConfigured is true for a real client ID")
    @MainActor
    func testIsConfiguredTrueForRealID() {
        #expect(MicrosoftAuthService.isConfigured(clientID: "11111111-2222-3333-4444-555555555555") == true)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter IntegrationVisibilityTests`
Expected: FAIL to compile — no `isConfigured(clientID:)` on `MicrosoftAuthService`.

- [ ] **Step 3: Implement the flag**

In `Sources/dBrief/Services/MicrosoftAuthService.swift`, change line 22 from:

```swift
    static let clientID = "YOUR-AZURE-CLIENT-ID"
```

to:

```swift
    static let placeholderClientID = "YOUR-AZURE-CLIENT-ID"
    static let clientID = placeholderClientID

    /// Testable predicate: a client ID is usable when it is non-empty and not the placeholder.
    static func isConfigured(clientID: String) -> Bool {
        !clientID.isEmpty && clientID != placeholderClientID
    }

    /// True when a real Azure client ID has been set (placeholder/empty = not configured).
    static var isConfigured: Bool { isConfigured(clientID: clientID) }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter IntegrationVisibilityTests`
Expected: PASS (4 tests now).

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Services/MicrosoftAuthService.swift Tests/dBriefTests/IntegrationVisibilityTests.swift
git commit -m "feat(calendar): add MicrosoftAuthService.isConfigured detection"
```

---

## Task 5: effectiveCalendarSource coercion

**Files:**
- Modify: `Sources/dBrief/App/AppSettings+EffectiveSettings.swift`
- Test: `Tests/dBriefTests/IntegrationVisibilityTests.swift`

- [ ] **Step 1: Write the failing test**

Add to the `IntegrationVisibilityTests` struct in `Tests/dBriefTests/IntegrationVisibilityTests.swift`:

```swift
    @Test("resolveCalendarSource coerces outlook to disabled when unconfigured")
    @MainActor
    func testResolveOutlookUnconfigured() {
        #expect(AppSettings.resolveCalendarSource(.outlook, outlookConfigured: false) == .disabled)
    }

    @Test("resolveCalendarSource keeps outlook when configured")
    @MainActor
    func testResolveOutlookConfigured() {
        #expect(AppSettings.resolveCalendarSource(.outlook, outlookConfigured: true) == .outlook)
    }

    @Test("resolveCalendarSource passes iCal and disabled through unchanged")
    @MainActor
    func testResolvePassThrough() {
        #expect(AppSettings.resolveCalendarSource(.iCal, outlookConfigured: false) == .iCal)
        #expect(AppSettings.resolveCalendarSource(.iCal, outlookConfigured: true) == .iCal)
        #expect(AppSettings.resolveCalendarSource(.disabled, outlookConfigured: true) == .disabled)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter IntegrationVisibilityTests`
Expected: FAIL to compile — no `resolveCalendarSource` on `AppSettings`.

- [ ] **Step 3: Implement the helper and computed property**

In `Sources/dBrief/App/AppSettings+EffectiveSettings.swift`, add inside the `extension AppSettings { ... }` block (after the existing effective properties, before the closing brace):

```swift
    /// Pure coercion: a persisted `.outlook` selection is treated as `.disabled`
    /// when no real Azure client ID is configured, so it cannot drive lookups
    /// against the placeholder. Other sources pass through unchanged.
    static func resolveCalendarSource(_ source: CalendarSource, outlookConfigured: Bool) -> CalendarSource {
        if source == .outlook && !outlookConfigured { return .disabled }
        return source
    }

    /// Calendar source to actually use for lookups (coerces stale `.outlook` when unconfigured).
    var effectiveCalendarSource: CalendarSource {
        AppSettings.resolveCalendarSource(calendarSource, outlookConfigured: MicrosoftAuthService.isConfigured)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter IntegrationVisibilityTests`
Expected: PASS (7 tests now).

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/App/AppSettings+EffectiveSettings.swift Tests/dBriefTests/IntegrationVisibilityTests.swift
git commit -m "feat(calendar): add effectiveCalendarSource coercion for unconfigured outlook"
```

---

## Task 6: Wire effectiveCalendarSource into lookup consumers

**Files:**
- Modify: `Sources/dBrief/Services/RecordingManager.swift:91`
- Modify: `Sources/dBrief/UI/PostRecordingSheet.swift:183,193`

Consumers that perform calendar lookups must use the coerced source. The settings picker binding keeps the raw `calendarSource` (Task 7). Verify by build.

- [ ] **Step 1: Update RecordingManager**

In `Sources/dBrief/Services/RecordingManager.swift`, change line 91 from:

```swift
        switch appSettings.calendarSource {
```

to:

```swift
        switch appSettings.effectiveCalendarSource {
```

- [ ] **Step 2: Update PostRecordingSheet**

In `Sources/dBrief/UI/PostRecordingSheet.swift`, change line 183 from:

```swift
                } else if appSettings.calendarSource == .iCal {
```

to:

```swift
                } else if appSettings.effectiveCalendarSource == .iCal {
```

And change line 193 from:

```swift
                } else if appSettings.calendarSource == .outlook {
```

to:

```swift
                } else if appSettings.effectiveCalendarSource == .outlook {
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/dBrief/Services/RecordingManager.swift Sources/dBrief/UI/PostRecordingSheet.swift
git commit -m "feat(calendar): use effectiveCalendarSource in lookup paths"
```

---

## Task 7: Conditional Outlook picker row

**Files:**
- Modify: `Sources/dBrief/UI/SettingsGeneralTab.swift:72-76`

The picker keeps binding to the raw `$settings.calendarSource`; the Outlook row only renders when configured. Verify by build + manual check.

- [ ] **Step 1: Render the Outlook row conditionally**

In `Sources/dBrief/UI/SettingsGeneralTab.swift`, change the picker body (lines 72-76) from:

```swift
                Picker("Source", selection: $settings.calendarSource) {
                    Text("Off").tag(CalendarSource.disabled)
                    Text("iCal").tag(CalendarSource.iCal)
                    Text("Outlook (Microsoft)").tag(CalendarSource.outlook)
                }
```

to:

```swift
                Picker("Source", selection: $settings.calendarSource) {
                    Text("Off").tag(CalendarSource.disabled)
                    Text("iCal").tag(CalendarSource.iCal)
                    if MicrosoftAuthService.isConfigured {
                        Text("Outlook (Microsoft)").tag(CalendarSource.outlook)
                    }
                }
```

Leave the `switch settings.calendarSource` block below (lines 78-129) unchanged; the `.outlook` case simply becomes unreachable while unconfigured.

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/UI/SettingsGeneralTab.swift
git commit -m "feat(calendar): hide outlook picker row until client ID configured"
```

---

## Task 8: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `swift test`
Expected: All tests pass, including the 7 new `IntegrationVisibilityTests`.

- [ ] **Step 2: Build and launch the app**

Run: `make run`
Expected: Build succeeds and the app launches.

- [ ] **Step 3: Manual verification checklist**

- Open Settings → Integrations: only **Obsidian, Apple Notes, Apple Reminders, Webhook** are listed. Notion, Evernote, Google Keep, OneNote are absent.
- Open Settings → General → Calendar: the Source picker offers only **Off** and **iCal** (no Outlook option) while the placeholder client ID is in place.
- If iCal was previously selected, it still works; calendar lookup behaves as before.

- [ ] **Step 4: No commit** (verification only). If manual checks reveal an issue, fix it under the relevant task and re-run.

---

## Self-Review Notes

- **Spec coverage:** §1 integrations hard-hide → Tasks 1-3; §2 Outlook self-detect (flag, picker, coercion) → Tasks 4, 5, 7 + wiring in Task 6; §3 testing → Tasks 1, 4, 5 (pure logic) + Task 8 (manual). All spec requirements mapped.
- **Type consistency:** `IntegrationDestination.available` (Task 1) used identically in Tasks 2-3. `MicrosoftAuthService.isConfigured` (Task 4) used in Tasks 5 and 7. `AppSettings.resolveCalendarSource` / `effectiveCalendarSource` (Task 5) used in Task 6.
- **YAGNI:** no new persisted settings, no Power User gate, no migration — matches spec scope.
