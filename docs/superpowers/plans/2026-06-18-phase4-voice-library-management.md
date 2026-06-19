# Phase 4 — Voice Library Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Voice Library settings tab (list / rename / merge / delete / forget-voiceprint) plus an explicit "Save this voice to library" turn-card action, backed by new `VoiceLibraryStore` operations.

**Architecture:** Decouple `KnownPerson.id` from the display name (Approach A — id immutable, new people get a UUID, existing name-derived ids stay opaque, `upsert` matches by case-insensitive name). New store actor methods (`rename`/`merge`/`delete`/`removeVoiceprint`) mutate the single global `library.json`. A new always-visible `SettingsVoiceLibraryTab` SwiftUI view reads the actor into local `@State` and reloads after each mutation. The turn-card affordance reuses the existing `RecordingManager.enrollVoiceprintOnRename` path.

**Tech Stack:** Swift 6.2, SwiftUI, swift-testing, SPM executable. macOS 14+.

## Global Constraints

- macOS 14+, Swift 6.2 (`swift-tools-version: 6.2`); zero new dependencies.
- All UI/state types `@MainActor @Observable`; services that do async work are `actor`-isolated. `VoiceLibraryStore` is an `actor`.
- The voice library is a single global JSON file at `~/Library/Application Support/com.dbrief.app/VoiceLibrary/library.json`; never a per-recording sidecar, never uploaded, never touched by `RetentionCleanup`.
- Voiceprints are biometric-adjacent: keep strictly local, document, allow purge.
- `KnownPerson.id` is opaque and **immutable once created**; `SpeakerLabel.personId` references it and must keep matching after a rename.
- Logging via centralized `Logger` extensions (e.g. `Logger.app`, `Logger.transcription`).
- Tests use the `swift-testing` framework (`import Testing`, `@Test`, `@Suite`, `#expect`).
- Build: `swift build`; test: `swift test`; app bundle: `make app`.

---

### Task 1: VoiceLibraryStore — id decoupling + management operations

**Files:**
- Modify: `Sources/dBrief/Services/VoiceLibraryStore.swift`
- Modify: `Tests/dBriefTests/VoiceLibraryStoreTests.swift`

**Interfaces:**
- Consumes: `VoiceLibrary`, `KnownPerson`, `Voiceprint` (`Models/VoiceLibrary.swift`); `VoiceEnrollment.isDuplicate(_:against:threshold:)` (`Services/VoiceEnrollment.swift`).
- Produces:
  - `enum RenameOutcome: Equatable { case renamed; case notFound; case collision(existingId: String) }`
  - `func rename(id: String, to newName: String) -> RenameOutcome` (actor-isolated)
  - `func merge(sourceId: String, into survivorId: String, maxPerPerson: Int = 5, dedupThreshold: Float = 0.97) -> Bool`
  - `func delete(id: String) -> Bool`
  - `func removeVoiceprint(personId: String, capturedAt: Date) -> Bool`
  - Changed `upsert(...)`: matches by case-insensitive **name**; reuses found person's existing id; mints `UUID().uuidString` for new people. Still `@discardableResult`, still returns the person id (or `""` for blank name).

- [ ] **Step 1: Write failing tests for the new ops + changed upsert**

Append to `Tests/dBriefTests/VoiceLibraryStoreTests.swift` (inside the `struct`):

```swift
    @Test("Upsert mints a stable id for a new name and reuses it on re-upsert")
    func upsertStableId() async {
        let store = VoiceLibraryStore(url: tempURL())
        let id1 = await store.upsert(name: "Dora", voiceprint: print1([1, 0]))
        let id2 = await store.upsert(name: "dora", voiceprint: print1([0, 1]), dedupThreshold: 2)
        #expect(id1 == id2)            // same person, id reused (case-insensitive)
        #expect(!id1.isEmpty)
        let lib = await store.load()
        #expect(lib.people.count == 1)
        #expect(lib.people[0].id == id1)
    }

    @Test("Rename changes the name but keeps the id stable")
    func renameKeepsId() async {
        let store = VoiceLibraryStore(url: tempURL())
        let id = await store.upsert(name: "Bob", voiceprint: print1([1, 0]))
        let outcome = await store.rename(id: id, to: "Robert")
        #expect(outcome == .renamed)
        let lib = await store.load()
        #expect(lib.people.count == 1)
        #expect(lib.people[0].id == id)        // unchanged
        #expect(lib.people[0].name == "Robert")
    }

    @Test("Rename to an absent id reports notFound")
    func renameNotFound() async {
        let store = VoiceLibraryStore(url: tempURL())
        let outcome = await store.rename(id: "nope", to: "X")
        #expect(outcome == .notFound)
    }

    @Test("Rename onto another person's name reports collision and changes nothing")
    func renameCollision() async {
        let store = VoiceLibraryStore(url: tempURL())
        let bobId = await store.upsert(name: "Bob", voiceprint: print1([1, 0]))
        let amyId = await store.upsert(name: "Amy", voiceprint: print1([0, 1]))
        let outcome = await store.rename(id: amyId, to: "bob")    // case-insensitive collide
        #expect(outcome == .collision(existingId: bobId))
        let lib = await store.load()
        #expect(lib.people.first(where: { $0.id == amyId })?.name == "Amy")  // untouched
    }

    @Test("Merge combines voiceprints into the survivor and drops the source")
    func mergeCombines() async {
        let store = VoiceLibraryStore(url: tempURL())
        let keepId = await store.upsert(name: "Keep", voiceprint: print1([1, 0]))
        let dropId = await store.upsert(name: "Drop", voiceprint: print1([0, 1]))
        let ok = await store.merge(sourceId: dropId, into: keepId, dedupThreshold: 2)
        #expect(ok)
        let lib = await store.load()
        #expect(lib.people.count == 1)
        #expect(lib.people[0].id == keepId)
        #expect(lib.people[0].voiceprints.count == 2)
    }

    @Test("Merge dedups and bounds to maxPerPerson")
    func mergeBoundsAndDedups() async {
        let store = VoiceLibraryStore(url: tempURL())
        let keepId = await store.upsert(name: "Keep", voiceprint: print1([1, 0]), dedupThreshold: 2)
        await store.upsert(name: "Keep", voiceprint: print1([2, 0]), dedupThreshold: 2)
        let dropId = await store.upsert(name: "Drop", voiceprint: print1([1, 0]))   // ~dup of keep's first
        await store.upsert(name: "Drop", voiceprint: print1([0, 5]), dedupThreshold: 2)
        let ok = await store.merge(sourceId: dropId, into: keepId, maxPerPerson: 3, dedupThreshold: 0.97)
        #expect(ok)
        let lib = await store.load()
        #expect(lib.people.count == 1)
        #expect(lib.people[0].voiceprints.count <= 3)   // bounded; near-dup skipped
    }

    @Test("Merge is a no-op for equal ids or a missing id")
    func mergeNoop() async {
        let store = VoiceLibraryStore(url: tempURL())
        let id = await store.upsert(name: "Solo", voiceprint: print1([1, 0]))
        #expect(await store.merge(sourceId: id, into: id) == false)
        #expect(await store.merge(sourceId: "ghost", into: id) == false)
    }

    @Test("Delete removes the person")
    func deletePerson() async {
        let store = VoiceLibraryStore(url: tempURL())
        let id = await store.upsert(name: "Gone", voiceprint: print1([1, 0]))
        #expect(await store.delete(id: id))
        #expect(await store.load().people.isEmpty)
        #expect(await store.delete(id: id) == false)   // already gone
    }

    @Test("removeVoiceprint drops one sample; removing the last drops the person")
    func removeVoiceprint() async {
        let store = VoiceLibraryStore(url: tempURL())
        // Two prints with distinct capturedAt so we can target one.
        var lib = VoiceLibrary()
        let early = Voiceprint(embedding: [1, 0], model: "t", capturedAt: Date(timeIntervalSince1970: 1))
        let late = Voiceprint(embedding: [0, 1], model: "t", capturedAt: Date(timeIntervalSince1970: 2))
        lib.people = [KnownPerson(id: "p", name: "Pat", voiceprints: [early, late])]
        await store.save(lib)
        #expect(await store.removeVoiceprint(personId: "p", capturedAt: early.capturedAt))
        let after = await store.load()
        #expect(after.people[0].voiceprints.count == 1)
        #expect(after.people[0].voiceprints[0].capturedAt == late.capturedAt)
        #expect(await store.removeVoiceprint(personId: "p", capturedAt: late.capturedAt))
        #expect(await store.load().people.isEmpty)   // last sample → person removed
    }
```

Also update the existing `upsertReturnsId` test, which asserts the old name-derived id. Replace it with:

```swift
    @Test("Upsert returns a non-empty id and rejects a blank name")
    func upsertReturnsId() async {
        let store = VoiceLibraryStore(url: tempURL())
        let id = await store.upsert(name: "  Dora ", voiceprint: print1([1, 0]))
        #expect(!id.isEmpty)
        let blank = await store.upsert(name: "   ", voiceprint: print1([1, 0]))
        #expect(blank == "")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter VoiceLibraryStore`
Expected: FAIL — `rename`/`merge`/`delete`/`removeVoiceprint` / `RenameOutcome` don't exist; `upsertStableId` fails because `upsert` currently keys id by name.

- [ ] **Step 3: Implement the id decoupling + new ops**

In `Sources/dBrief/Services/VoiceLibraryStore.swift`, add the outcome enum above the `actor` (top-level, after imports):

```swift
/// Result of a library rename. `.collision` means the new name already belongs to
/// a different person — the UI should offer a merge instead of creating a duplicate.
enum RenameOutcome: Equatable {
    case renamed
    case notFound
    case collision(existingId: String)
}
```

Change `upsert` to match by name and mint a UUID for new people. Replace the `if let idx = lib.people.firstIndex(where: { $0.id == key })` block's lookup and the `else` branch:

```swift
    @discardableResult
    func upsert(name: String, voiceprint: Voiceprint, maxPerPerson: Int = 5, dedupThreshold: Float = 0.97) -> String {
        let display = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { return "" }
        let key = display.lowercased()
        var lib = load()
        if let idx = lib.people.firstIndex(where: { $0.name.lowercased() == key }) {
            if !VoiceEnrollment.isDuplicate(voiceprint.embedding, against: lib.people[idx].voiceprints, threshold: dedupThreshold) {
                lib.people[idx].voiceprints.append(voiceprint)
                if lib.people[idx].voiceprints.count > maxPerPerson {
                    lib.people[idx].voiceprints.removeFirst(lib.people[idx].voiceprints.count - maxPerPerson)
                }
                save(lib)
            }
            return lib.people[idx].id
        } else {
            let person = KnownPerson(id: UUID().uuidString, name: display, voiceprints: [voiceprint])
            lib.people.append(person)
            save(lib)
            return person.id
        }
    }
```

Add the new methods inside the actor (after `upsert`):

```swift
    /// Renames a person by id, preserving the id. Returns `.collision` (no change)
    /// when the new name already belongs to a different person.
    func rename(id: String, to newName: String) -> RenameOutcome {
        let display = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { return .notFound }
        var lib = load()
        guard let idx = lib.people.firstIndex(where: { $0.id == id }) else { return .notFound }
        let key = display.lowercased()
        if let other = lib.people.first(where: { $0.id != id && $0.name.lowercased() == key }) {
            return .collision(existingId: other.id)
        }
        lib.people[idx].name = display
        save(lib)
        return .renamed
    }

    /// Moves the source person's voiceprints into the survivor (deduped, bounded to
    /// `maxPerPerson`, newest kept), then removes the source. No-op for equal ids or
    /// a missing id.
    @discardableResult
    func merge(sourceId: String, into survivorId: String, maxPerPerson: Int = 5, dedupThreshold: Float = 0.97) -> Bool {
        guard sourceId != survivorId else { return false }
        var lib = load()
        guard let si = lib.people.firstIndex(where: { $0.id == sourceId }),
              let di = lib.people.firstIndex(where: { $0.id == survivorId }) else { return false }
        for vp in lib.people[si].voiceprints {
            if !VoiceEnrollment.isDuplicate(vp.embedding, against: lib.people[di].voiceprints, threshold: dedupThreshold) {
                lib.people[di].voiceprints.append(vp)
            }
        }
        if lib.people[di].voiceprints.count > maxPerPerson {
            lib.people[di].voiceprints.removeFirst(lib.people[di].voiceprints.count - maxPerPerson)
        }
        lib.people.remove(at: si)
        save(lib)
        return true
    }

    /// Removes a person entirely.
    @discardableResult
    func delete(id: String) -> Bool {
        var lib = load()
        guard let idx = lib.people.firstIndex(where: { $0.id == id }) else { return false }
        lib.people.remove(at: idx)
        save(lib)
        return true
    }

    /// Removes a single voiceprint (matched by `capturedAt`). If it was the person's
    /// last voiceprint, the person is removed too.
    @discardableResult
    func removeVoiceprint(personId: String, capturedAt: Date) -> Bool {
        var lib = load()
        guard let idx = lib.people.firstIndex(where: { $0.id == personId }) else { return false }
        let before = lib.people[idx].voiceprints.count
        lib.people[idx].voiceprints.removeAll { $0.capturedAt == capturedAt }
        guard lib.people[idx].voiceprints.count != before else { return false }
        if lib.people[idx].voiceprints.isEmpty { lib.people.remove(at: idx) }
        save(lib)
        return true
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter VoiceLibraryStore`
Expected: PASS (all suite tests, including the updated `upsertReturnsId`).

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Services/VoiceLibraryStore.swift Tests/dBriefTests/VoiceLibraryStoreTests.swift
git commit -m "feat: voice library store rename/merge/delete + UUID id decoupling"
```

---

### Task 2: Pure presentation + enrollment helpers

**Files:**
- Create: `Sources/dBrief/Services/VoiceLibraryDisplay.swift`
- Create: `Tests/dBriefTests/VoiceLibraryDisplayTests.swift`

**Interfaces:**
- Consumes: `KnownPerson`, `Voiceprint` (`Models/VoiceLibrary.swift`).
- Produces:
  - `enum VoiceLibraryDisplay` with:
    - `static func lastSeen(_ person: KnownPerson) -> Date?` — newest `capturedAt`, `nil` if none.
    - `static func sampleSummary(_ person: KnownPerson) -> String` — e.g. `"1 voiceprint"` / `"3 voiceprints"`.
    - `static func sortedByLastSeen(_ people: [KnownPerson]) -> [KnownPerson]` — newest-first; people with no prints sort last; ties broken by case-insensitive name.
    - `static func canEnroll(displayName: String, speakerId: String, hasEmbedding: Bool, alreadyEnrolled: Bool) -> Bool` — true when the speaker is **named** (display name non-blank and `!= speakerId`), `hasEmbedding`, and not `alreadyEnrolled`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/dBriefTests/VoiceLibraryDisplayTests.swift`:

```swift
import Foundation
import Testing
@testable import dBrief

@Suite("VoiceLibraryDisplay")
struct VoiceLibraryDisplayTests {
    private func person(_ name: String, _ times: [TimeInterval]) -> KnownPerson {
        KnownPerson(id: name.lowercased(), name: name,
                    voiceprints: times.map { Voiceprint(embedding: [1], model: "t", capturedAt: Date(timeIntervalSince1970: $0)) })
    }

    @Test("lastSeen returns the newest capturedAt, nil when empty")
    func lastSeen() {
        #expect(VoiceLibraryDisplay.lastSeen(person("A", [1, 9, 3])) == Date(timeIntervalSince1970: 9))
        #expect(VoiceLibraryDisplay.lastSeen(person("B", [])) == nil)
    }

    @Test("sampleSummary pluralizes")
    func sampleSummary() {
        #expect(VoiceLibraryDisplay.sampleSummary(person("A", [1])) == "1 voiceprint")
        #expect(VoiceLibraryDisplay.sampleSummary(person("A", [1, 2, 3])) == "3 voiceprints")
        #expect(VoiceLibraryDisplay.sampleSummary(person("A", [])) == "0 voiceprints")
    }

    @Test("sortedByLastSeen is newest-first, empties last, name tiebreak")
    func sorted() {
        let people = [person("Old", [1]), person("New", [100]), person("None", []), person("alsoNew", [100])]
        let names = VoiceLibraryDisplay.sortedByLastSeen(people).map(\.name)
        #expect(names == ["alsoNew", "New", "Old", "None"])
    }

    @Test("canEnroll requires a real name, an embedding, and not-yet-enrolled")
    func canEnroll() {
        // named + embedding + fresh → yes
        #expect(VoiceLibraryDisplay.canEnroll(displayName: "Jesper", speakerId: "Speaker 1", hasEmbedding: true, alreadyEnrolled: false))
        // raw name (== speakerId) → no
        #expect(!VoiceLibraryDisplay.canEnroll(displayName: "Speaker 1", speakerId: "Speaker 1", hasEmbedding: true, alreadyEnrolled: false))
        // blank name → no
        #expect(!VoiceLibraryDisplay.canEnroll(displayName: "  ", speakerId: "Speaker 1", hasEmbedding: true, alreadyEnrolled: false))
        // no embedding → no
        #expect(!VoiceLibraryDisplay.canEnroll(displayName: "Jesper", speakerId: "Speaker 1", hasEmbedding: false, alreadyEnrolled: false))
        // already enrolled → no
        #expect(!VoiceLibraryDisplay.canEnroll(displayName: "Jesper", speakerId: "Speaker 1", hasEmbedding: true, alreadyEnrolled: true))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter VoiceLibraryDisplay`
Expected: FAIL — `VoiceLibraryDisplay` does not exist.

- [ ] **Step 3: Implement the helper**

Create `Sources/dBrief/Services/VoiceLibraryDisplay.swift`:

```swift
import Foundation

/// Pure presentation/decision helpers for the voice library UI. No I/O, no actor —
/// trivially unit-testable.
enum VoiceLibraryDisplay {
    /// Newest voiceprint capture date, or nil when the person has no prints.
    static func lastSeen(_ person: KnownPerson) -> Date? {
        person.voiceprints.map(\.capturedAt).max()
    }

    /// "N voiceprint(s)".
    static func sampleSummary(_ person: KnownPerson) -> String {
        let n = person.voiceprints.count
        return "\(n) voiceprint\(n == 1 ? "" : "s")"
    }

    /// Newest-first; people with no prints sort last; ties broken by case-insensitive name.
    static func sortedByLastSeen(_ people: [KnownPerson]) -> [KnownPerson] {
        people.sorted { a, b in
            switch (lastSeen(a), lastSeen(b)) {
            case let (la?, lb?):
                if la != lb { return la > lb }
                return a.name.lowercased() < b.name.lowercased()
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.name.lowercased() < b.name.lowercased()
            }
        }
    }

    /// Whether the "Save this voice to library" affordance should appear for a turn.
    static func canEnroll(displayName: String, speakerId: String, hasEmbedding: Bool, alreadyEnrolled: Bool) -> Bool {
        guard hasEmbedding, !alreadyEnrolled else { return false }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != speakerId
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter VoiceLibraryDisplay`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Services/VoiceLibraryDisplay.swift Tests/dBriefTests/VoiceLibraryDisplayTests.swift
git commit -m "feat: pure voice library display + enrollment helpers"
```

---

### Task 3: Voice Library settings tab

**Files:**
- Create: `Sources/dBrief/UI/SettingsVoiceLibraryTab.swift`
- Modify: `Sources/dBrief/UI/SettingsView.swift`

**Interfaces:**
- Consumes: `AppContext.voiceLibraryStore` (`VoiceLibraryStore`), `VoiceLibrary`/`KnownPerson`/`Voiceprint`, `VoiceLibraryDisplay` (Task 2), `RenameOutcome`/`rename`/`merge`/`delete`/`removeVoiceprint` (Task 1), `SettingsSection`.
- Produces: `SettingsView.SettingsTab.voiceLibrary` (always visible); `struct SettingsVoiceLibraryTab: View`.

- [ ] **Step 1: Add the always-visible tab case**

In `Sources/dBrief/UI/SettingsView.swift`, add the case to the enum (after `integrations`):

```swift
        case voiceLibrary   = "Voice Library"
```

Add its icon in the `icon` switch:

```swift
            case .voiceLibrary:   "person.wave.2"
```

Add the detail switch arm (after `.integrations`):

```swift
                case .voiceLibrary: SettingsVoiceLibraryTab()
```

`visibleTabs` already returns all non-(profiles/benchmark) tabs, so `voiceLibrary` is visible by default — no change there.

- [ ] **Step 2: Create the tab view**

Create `Sources/dBrief/UI/SettingsVoiceLibraryTab.swift`:

```swift
import SwiftUI

/// Always-visible management surface for the on-device voice library: list known
/// people with sample counts + last-heard, rename, merge, forget a person, and
/// forget an individual voiceprint. Reads the `VoiceLibraryStore` actor into local
/// state and reloads after every mutation.
struct SettingsVoiceLibraryTab: View {
    @Environment(AppContext.self) private var context

    @State private var library = VoiceLibrary()
    @State private var loaded = false
    @State private var expanded: Set<String> = []          // person ids showing voiceprints
    @State private var renaming: KnownPerson?
    @State private var renameText = ""
    @State private var deleteTarget: KnownPerson?
    @State private var mergeSource: KnownPerson?
    @State private var collision: (source: KnownPerson, existingId: String, name: String)?

    private var people: [KnownPerson] { VoiceLibraryDisplay.sortedByLastSeen(library.people) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                privacySection
                if people.isEmpty {
                    emptyState
                } else {
                    peopleSection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if !loaded { await reload(); loaded = true } }
        .alert("Forget this voice?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("Forget", role: .destructive) {
                if let t = deleteTarget { Task { await context.voiceLibraryStore.delete(id: t.id); await reload() } }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("“\(deleteTarget?.name ?? "")” and all its voiceprints will be removed. This cannot be undone.")
        }
        .alert("Name already exists", isPresented: Binding(get: { collision != nil }, set: { if !$0 { collision = nil } })) {
            Button("Merge", role: .destructive) {
                if let c = collision { Task { await context.voiceLibraryStore.merge(sourceId: c.source.id, into: c.existingId); await reload() } }
            }
            Button("Cancel", role: .cancel) { collision = nil }
        } message: {
            Text("Another person is already named “\(collision?.name ?? "")”. Merge “\(collision?.source.name ?? "")” into them?")
        }
        .sheet(item: $renaming) { person in renameSheet(person) }
        .sheet(item: $mergeSource) { person in mergeSheet(person) }
    }

    private var privacySection: some View {
        SettingsSection(title: "Voice Library") {
            Text("dBrief learns each speaker's voice so it can recognize them in future recordings. Voiceprints are stored only on this Mac, are never uploaded, and can be forgotten at any time.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        SettingsSection(title: "Known People") {
            Text("No voices saved yet. A voice is added when you name a speaker in a transcript, or with “Save voice to library” from the speaker menu.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var peopleSection: some View {
        SettingsSection(title: "Known People") {
            ForEach(people) { person in
                personRow(person)
                if person.id != people.last?.id { Divider() }
            }
        }
    }

    @ViewBuilder
    private func personRow(_ person: KnownPerson) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "person.wave.2.fill").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name).font(.body)
                    Text(caption(person)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Rename…") { renameText = person.name; renaming = person }
                    if library.people.count > 1 {
                        Button("Merge into…") { mergeSource = person }
                    }
                    if person.voiceprints.count > 1 {
                        Button(expanded.contains(person.id) ? "Hide voiceprints" : "Show voiceprints") { toggle(person.id) }
                    }
                    Divider()
                    Button("Forget voice", role: .destructive) { deleteTarget = person }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if expanded.contains(person.id) {
                ForEach(person.voiceprints, id: \.capturedAt) { vp in
                    HStack {
                        Text("Captured \(vp.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task { await context.voiceLibraryStore.removeVoiceprint(personId: person.id, capturedAt: vp.capturedAt); await reload() }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                    .padding(.leading, 28)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func caption(_ person: KnownPerson) -> String {
        let summary = VoiceLibraryDisplay.sampleSummary(person)
        if let seen = VoiceLibraryDisplay.lastSeen(person) {
            return "\(summary) · last heard \(seen.formatted(.relative(presentation: .named)))"
        }
        return summary
    }

    @ViewBuilder
    private func renameSheet(_ person: KnownPerson) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Voice").font(.headline)
            TextField("Name", text: $renameText).textFieldStyle(.roundedBorder).frame(width: 260)
            HStack {
                Spacer()
                Button("Cancel") { renaming = nil }
                Button("Save") { commitRename(person) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func mergeSheet(_ source: KnownPerson) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge “\(source.name)” into…").font(.headline)
            Text("All of \(source.name)'s voiceprints move into the person you pick, and “\(source.name)” is removed.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(library.people.filter { $0.id != source.id }) { target in
                Button {
                    Task { await context.voiceLibraryStore.merge(sourceId: source.id, into: target.id); mergeSource = nil; await reload() }
                } label: {
                    HStack { Text(target.name); Spacer(); Text(VoiceLibraryDisplay.sampleSummary(target)).foregroundStyle(.secondary) }
                }
                .buttonStyle(.bordered)
            }
            HStack { Spacer(); Button("Cancel") { mergeSource = nil } }
        }
        .padding(20)
        .frame(minWidth: 320)
    }

    private func commitRename(_ person: KnownPerson) {
        let newName = renameText
        renaming = nil
        Task {
            let outcome = await context.voiceLibraryStore.rename(id: person.id, to: newName)
            if case let .collision(existingId) = outcome {
                collision = (source: person, existingId: existingId, name: newName.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            await reload()
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func reload() async {
        library = await context.voiceLibraryStore.load()
    }
}
```

- [ ] **Step 3: Build and verify the tab compiles + the app launches**

Run: `swift build`
Expected: Build succeeds with no errors.

Run: `make app && open dBrief.app`
Expected: App launches; opening Settings shows a **Voice Library** tab in the sidebar (always present). With no library it shows the empty state; with people it lists them.

- [ ] **Step 4: Commit**

```bash
git add Sources/dBrief/UI/SettingsVoiceLibraryTab.swift Sources/dBrief/UI/SettingsView.swift
git commit -m "feat: Voice Library settings tab (list/rename/merge/forget)"
```

---

### Task 4: "Save this voice to library" turn-card affordance

**Files:**
- Modify: `Sources/dBrief/Services/RecordingManager.swift` (add embedding-availability helper)
- Modify: `Sources/dBrief/UI/TranscriptWindowView.swift` (menu item + state)

**Interfaces:**
- Consumes: `VoiceLibraryDisplay.canEnroll(...)` (Task 2); existing `RecordingManager.enrollVoiceprintOnRename(recording:speakerId:name:)`; existing `displayName(for:)`, `loadKnownPeople()`, `saveTranscript(_:)`, `richTranscript`, `knownPeopleNames`, `knownPersonIds` in `TranscriptWindowView`.
- Produces:
  - `RecordingManager.embeddedSpeakerIds(for recording: Recording) -> Set<String>` — speaker ids that have a non-empty embedding (memory or `.transcript.json` sidecar).
  - A new menu action `Button("Save … voice to library")` in `speakerMenuContent`, gated by `VoiceLibraryDisplay.canEnroll`.

- [ ] **Step 1: Add the embedding-availability helper to RecordingManager**

In `Sources/dBrief/Services/RecordingManager.swift`, immediately after `enrollVoiceprintOnRename` (ends at line ~2563), add:

```swift
    /// Speaker ids with a non-empty voice embedding available right now (from the
    /// in-memory transcription or the persisted `.transcript.json` sidecar) — i.e.
    /// the speakers that `enrollVoiceprintOnRename` could enroll.
    func embeddedSpeakerIds(for recording: Recording) -> Set<String> {
        let embeddings = recording.transcription?.speakerEmbeddings
            ?? loadSavedTranscript(for: recording)?.speakerEmbeddings
        guard let embeddings else { return [] }
        return Set(embeddings.filter { !$0.value.isEmpty }.keys)
    }
```

(`loadSavedTranscript(for:)` is `private` at `RecordingManager.swift:2536`, but `embeddedSpeakerIds` is added in the same type, so the private call resolves — no access change needed. `embeddedSpeakerIds` itself takes no access modifier (internal), so the view in `TranscriptWindowView.swift` can call it.)

- [ ] **Step 2: Add menu state + load embedded-speaker ids in TranscriptWindowView**

In `Sources/dBrief/UI/TranscriptWindowView.swift`, add `@State` near the other speaker state (after line 63, the `knownPersonIds` declaration):

```swift
    @State private var embeddedSpeakerIds: Set<String> = []
    @State private var enrolledSpeakerIds: Set<String> = []
```

In `loadKnownPeople()` (line ~1128), after setting `knownPersonIds`, also refresh the embedded set:

```swift
        embeddedSpeakerIds = context.recordingManager.embeddedSpeakerIds(for: recording)
```

- [ ] **Step 3: Add the enroll action to the speaker menu**

In `speakerMenuContent(turn:isMe:)` (line ~526), insert before the final `Divider()`/"This is me" block (i.e. right after the Reassign `if !others.isEmpty { … }` block, before `Divider()` at line 578):

```swift
        // Save voice to library (explicit enrollment — surfaces the growth loop
        // for an already-named speaker without renaming).
        let sid = turn.speakerId ?? ""
        let speakerName = displayName(for: sid)
        if VoiceLibraryDisplay.canEnroll(displayName: speakerName, speakerId: sid,
                                         hasEmbedding: embeddedSpeakerIds.contains(sid),
                                         alreadyEnrolled: enrolledSpeakerIds.contains(sid)) {
            Divider()
            Button("Save “\(speakerName)” voice to library") { saveVoice(turn: turn, name: speakerName) }
        }
```

- [ ] **Step 4: Add the `saveVoice` action**

In `TranscriptWindowView.swift`, after `renameSpeaker(turn:to:)` (ends ~line 826), add:

```swift
    /// Explicitly bank the speaker's voiceprint under their current display name,
    /// then link the resulting library person id onto the label. Reuses the same
    /// enrollment path as rename; no-op (and the menu item is hidden) when no
    /// embedding is available.
    private func saveVoice(turn: SpeakerTurn, name: String) {
        guard let id = turn.speakerId else { return }
        Task {
            guard let personId = await context.recordingManager
                .enrollVoiceprintOnRename(recording: recording, speakerId: id, name: name) else { return }
            enrolledSpeakerIds.insert(id)
            await loadKnownPeople()
            if var t = richTranscript,
               let i = t.speakerLabels.firstIndex(where: { $0.id == id }),
               t.speakerLabels[i].personId != personId {
                t.speakerLabels[i].personId = personId
                richTranscript = t
                saveTranscript(t)
            }
        }
    }
```

- [ ] **Step 5: Build and verify**

Run: `swift build`
Expected: Build succeeds.

Run: `swift test`
Expected: All tests pass (no regressions; Tasks 1–2 suites green).

- [ ] **Step 6: Manual verification + commit**

Run: `make app && open dBrief.app`
Expected: Open a finished transcript that was diarized with embeddings; the speaker menu on a **named** turn shows "Save "<name>" voice to library"; choosing it adds the person to the Voice Library tab. On a raw "Speaker N" turn (or a transcript with no embeddings) the item is absent.

```bash
git add Sources/dBrief/Services/RecordingManager.swift Sources/dBrief/UI/TranscriptWindowView.swift
git commit -m "feat: Save voice to library action in the transcript speaker menu"
```

---

## Self-Review

**Spec coverage:**
- Identity decoupling (Approach A) → Task 1 (upsert by name + UUID, id immutable). ✓
- Store ops rename/merge/delete/removeVoiceprint → Task 1. ✓
- Voice Library tab (always visible, privacy copy, list, rename, merge, delete, per-voiceprint forget, empty state) → Task 3. ✓
- Enrollment affordance (named + embedding-gated, hidden when unavailable, session feedback) → Tasks 2 (predicate) + 4 (menu/wiring). ✓
- Tests: store ops + upsert-by-name → Task 1; derived display + menu predicate → Task 2. ✓
- Non-goals (mic-energy "me", segmented drop, stub embedding test) → excluded. ✓

**Placeholder scan:** No TBD/TODO; all code shown; no "handle edge cases" hand-waving.

**Type consistency:** `RenameOutcome` (Task 1) consumed by Task 3 `commitRename`. `VoiceLibraryDisplay.canEnroll/sampleSummary/lastSeen/sortedByLastSeen` (Task 2) consumed by Tasks 3–4 with matching signatures. `embeddedSpeakerIds(for:)` (Task 4 RecordingManager) consumed by Task 4 view. `enrollVoiceprintOnRename` signature matches the existing one verified in source. `KnownPerson(id:name:voiceprints:)` and `Voiceprint(embedding:model:capturedAt:)` match `Models/VoiceLibrary.swift`.

**Verified:** `loadSavedTranscript(for:)` is `private` at `RecordingManager.swift:2536`; the new `embeddedSpeakerIds(for:)` lives in the same type and resolves the private call — no access change required.
