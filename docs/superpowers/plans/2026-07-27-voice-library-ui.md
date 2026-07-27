# Voice Library UI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the flat Voice Library settings list into a searchable, company-grouped master–detail surface that scales as the library grows.

**Architecture:** Add an optional `company` field to `KnownPerson`, auto-suggested (fill-only) from calendar-attendee email domains at enrollment and user-editable. All filter/group/sort logic lives in a pure, unit-tested helper (`VoiceLibraryFilter`); the settings tab is rewritten as a nested list-pane + detail-pane.

**Tech Stack:** Swift 6.2, SwiftUI, `swift-testing` (`@Suite`/`@Test`/`#expect`), SPM. Build: `swift build`. Tests: `swift test`.

## Global Constraints

- macOS 14+, Swift 6.2, `swift-tools-version: 6.2`. Apple-Silicon SPM executable, no new dependencies.
- Pure logic (no I/O, no actor, no SwiftUI) goes in `Services/` enums and is unit-tested, mirroring `VoiceLibraryDisplay`.
- `VoiceLibraryStore` is an `actor`; all mutations `load() → mutate → save()` and are best-effort atomic. Do not change its file location or JSON format beyond additive fields.
- New model fields are **optional** and decode leniently so existing `library.json` files (and old queue/sidecar data) load unchanged. Do not bump `VoiceLibrary.version`.
- `company`: `nil` means "No company". Trimmed empty string is stored as `nil`, never `""`.
- Auto-suggest is **fill-only**: it may populate an empty company, never overwrite an existing value.
- Voiceprint model tag string is `"fluidaudio-wespeaker-256"` (used verbatim at existing enrollment sites — do not change).
- Consumer-domain denylist (return `nil`, no company): `gmail.com`, `googlemail.com`, `outlook.com`, `hotmail.com`, `live.com`, `msn.com`, `icloud.com`, `me.com`, `mac.com`, `yahoo.com`, `ymail.com`, `proton.me`, `protonmail.com`, `aol.com`, `gmx.com`, `gmx.net`.

---

### Task 1: Add `company` to the model + store mutations

**Files:**
- Modify: `Sources/dBrief/Models/VoiceLibrary.swift`
- Modify: `Sources/dBrief/Services/VoiceLibraryStore.swift`
- Test: `Tests/dBriefTests/VoiceLibraryStoreTests.swift` (append)

**Interfaces:**
- Consumes: existing `KnownPerson(id:name:voiceprints:)`, `VoiceLibraryStore.load()/save(_:)`.
- Produces:
  - `KnownPerson.company: String?` (defaults `nil`)
  - `func setCompany(id: String, to company: String?) async` on `VoiceLibraryStore` — trims; empty → `nil`; no-op on missing id.
  - `func suggestCompanyIfEmpty(id: String, to company: String) async -> Bool` — sets only when the person's current company is `nil`/empty; returns whether it changed anything.

- [ ] **Step 1: Add the optional field to `KnownPerson`**

In `Sources/dBrief/Models/VoiceLibrary.swift`, add `company` to the struct and its memberwise usage. `KnownPerson` uses the compiler-synthesized `Codable`; an optional property decodes to `nil` when absent, so no custom `init(from:)` is needed.

```swift
struct KnownPerson: Codable, Sendable, Equatable, Identifiable {
    var id: String           // stable opaque key (UUID string); never changes on rename
    var name: String         // display spelling (first seen)
    var company: String?     // nil = "No company"; auto-suggested from calendar, user-editable
    var voiceprints: [Voiceprint]
}
```

- [ ] **Step 2: Write failing store tests**

Append to `Tests/dBriefTests/VoiceLibraryStoreTests.swift`. If the suite builds its store against a temp URL, follow that existing pattern; the snippet below assumes a helper `makeStore()` returning a `VoiceLibraryStore` on a unique temp file — reuse whatever the file already uses to construct a store.

```swift
@Test("setCompany sets, trims, and clears to nil on empty")
func setCompanyTrimsAndClears() async {
    let store = makeStore()
    let id = await store.upsert(name: "Alice", voiceprint: Voiceprint(embedding: [1], model: "t", capturedAt: Date()))
    await store.setCompany(id: id, to: "  Acme  ")
    #expect(await store.load().people.first(where: { $0.id == id })?.company == "Acme")
    await store.setCompany(id: id, to: "   ")
    #expect(await store.load().people.first(where: { $0.id == id })?.company == nil)
}

@Test("suggestCompanyIfEmpty fills only when empty, never overwrites")
func suggestFillOnly() async {
    let store = makeStore()
    let id = await store.upsert(name: "Bob", voiceprint: Voiceprint(embedding: [1], model: "t", capturedAt: Date()))
    #expect(await store.suggestCompanyIfEmpty(id: id, to: "Acme") == true)
    #expect(await store.load().people.first(where: { $0.id == id })?.company == "Acme")
    #expect(await store.suggestCompanyIfEmpty(id: id, to: "Globex") == false)
    #expect(await store.load().people.first(where: { $0.id == id })?.company == "Acme")
}

@Test("old libraries without company decode with nil")
func lenientDecode() async {
    let json = #"{"version":1,"people":[{"id":"x","name":"Carol","voiceprints":[]}]}"#
    let lib = try! JSONDecoder().decode(VoiceLibrary.self, from: Data(json.utf8))
    #expect(lib.people.first?.company == nil)
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter VoiceLibraryStore`
Expected: FAIL — `setCompany`/`suggestCompanyIfEmpty` do not exist yet.

- [ ] **Step 4: Implement the two mutations**

Add to `VoiceLibraryStore` (after `rename`):

```swift
/// Sets (or clears) a person's company. Trims; an empty string clears to nil.
/// No-op when the id is missing.
func setCompany(id: String, to company: String?) {
    var lib = load()
    guard let idx = lib.people.firstIndex(where: { $0.id == id }) else { return }
    let trimmed = company?.trimmingCharacters(in: .whitespacesAndNewlines)
    lib.people[idx].company = (trimmed?.isEmpty ?? true) ? nil : trimmed
    save(lib)
}

/// Fill-only company suggestion: sets `company` only when it is currently nil/empty.
/// Returns whether a value was written. Never overwrites an existing company.
@discardableResult
func suggestCompanyIfEmpty(id: String, to company: String) -> Bool {
    let trimmed = company.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    var lib = load()
    guard let idx = lib.people.firstIndex(where: { $0.id == id }) else { return false }
    let current = lib.people[idx].company?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard current == nil || current!.isEmpty else { return false }
    lib.people[idx].company = trimmed
    save(lib)
    return true
}
```

(Actor isolation makes these `async` at the call site automatically; no `async` keyword in the declaration.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter VoiceLibraryStore`
Expected: PASS (new + existing store tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/dBrief/Models/VoiceLibrary.swift Sources/dBrief/Services/VoiceLibraryStore.swift Tests/dBriefTests/VoiceLibraryStoreTests.swift
git commit -m "feat(voice-library): add editable per-person company field + store mutations"
```

---

### Task 2: Pure filter / group / sort + domain→company helper

**Files:**
- Create: `Sources/dBrief/Services/VoiceLibraryFilter.swift`
- Test: `Tests/dBriefTests/VoiceLibraryFilterTests.swift`

**Interfaces:**
- Consumes: `KnownPerson`, `VoiceLibraryDisplay.lastSeen(_:)`.
- Produces:
  - `enum VoiceLibraryFilter.Sort { case lastHeard, name, voiceprintCount }`
  - `VoiceLibraryFilter.apply(people:query:companies:sort:) -> [KnownPerson]`
  - `VoiceLibraryFilter.grouped(people:) -> [VoiceLibraryFilter.Group]`, `Group { id, label, people }`
  - `VoiceLibraryFilter.companies(in:) -> [String]` (distinct non-nil companies, case-insensitive sort)
  - `CompanyName.fromDomain(_:) -> String?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/dBriefTests/VoiceLibraryFilterTests.swift`:

```swift
import Foundation
import Testing
@testable import dBrief

@Suite("VoiceLibraryFilter")
struct VoiceLibraryFilterTests {
    private func p(_ name: String, company: String? = nil, times: [TimeInterval] = [1]) -> KnownPerson {
        KnownPerson(id: name.lowercased(), name: name, company: company,
                    voiceprints: times.map { Voiceprint(embedding: [1], model: "t", capturedAt: Date(timeIntervalSince1970: $0)) })
    }

    @Test("search matches name or company, case-insensitive; empty = all")
    func search() {
        let people = [p("Alice", company: "Acme"), p("Bob", company: "Globex")]
        #expect(VoiceLibraryFilter.apply(people: people, query: "ali", companies: [], sort: .name).map(\.name) == ["Alice"])
        #expect(VoiceLibraryFilter.apply(people: people, query: "globex", companies: [], sort: .name).map(\.name) == ["Bob"])
        #expect(VoiceLibraryFilter.apply(people: people, query: "  ", companies: [], sort: .name).count == 2)
    }

    @Test("company filter narrows; empty set = all")
    func companyFilter() {
        let people = [p("Alice", company: "Acme"), p("Bob", company: "Globex"), p("Cara", company: nil)]
        #expect(VoiceLibraryFilter.apply(people: people, query: "", companies: ["Acme"], sort: .name).map(\.name) == ["Alice"])
        #expect(VoiceLibraryFilter.apply(people: people, query: "", companies: [], sort: .name).count == 3)
    }

    @Test("sort orders: lastHeard newest-first, name asc, count desc")
    func sorts() {
        let people = [p("Old", times: [1]), p("New", times: [100]), p("Many", times: [2, 3, 4])]
        #expect(VoiceLibraryFilter.apply(people: people, query: "", companies: [], sort: .lastHeard).first?.name == "New")
        #expect(VoiceLibraryFilter.apply(people: people, query: "", companies: [], sort: .name).map(\.name) == ["Many", "New", "Old"])
        #expect(VoiceLibraryFilter.apply(people: people, query: "", companies: [], sort: .voiceprintCount).first?.name == "Many")
    }

    @Test("grouped buckets by company, No company last, counts correct")
    func grouped() {
        let people = [p("Alice", company: "Acme"), p("Bob", company: "Globex"), p("Cara", company: nil), p("Dan", company: "Acme")]
        let groups = VoiceLibraryFilter.grouped(people: people)
        #expect(groups.map(\.label) == ["Acme", "Globex", "No company"])
        #expect(groups.first?.people.count == 2)
        #expect(groups.last?.label == "No company")
    }

    @Test("companies lists distinct non-nil, case-insensitive sorted")
    func companiesList() {
        let people = [p("A", company: "beta"), p("B", company: "Alpha"), p("C", company: nil), p("D", company: "Alpha")]
        #expect(VoiceLibraryFilter.companies(in: people) == ["Alpha", "beta"])
    }

    @Test("CompanyName maps corporate domains, nils consumer/invalid")
    func companyName() {
        #expect(CompanyName.fromDomain("acme.com") == "Acme")
        #expect(CompanyName.fromDomain("servicenow.com") == "Servicenow")
        #expect(CompanyName.fromDomain("mail.acme.co.uk") == "Acme")
        #expect(CompanyName.fromDomain("gmail.com") == nil)
        #expect(CompanyName.fromDomain("icloud.com") == nil)
        #expect(CompanyName.fromDomain(nil) == nil)
        #expect(CompanyName.fromDomain("") == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter VoiceLibraryFilter`
Expected: FAIL — `VoiceLibraryFilter` / `CompanyName` do not exist.

- [ ] **Step 3: Implement the helper**

Create `Sources/dBrief/Services/VoiceLibraryFilter.swift`:

```swift
import Foundation

/// Pure, no-I/O filter/group/sort helpers for the Voice Library UI. Unit-tested
/// like `VoiceLibraryDisplay`.
enum VoiceLibraryFilter {
    enum Sort: String, CaseIterable, Identifiable, Sendable {
        case lastHeard, name, voiceprintCount
        var id: String { rawValue }
        var label: String {
            switch self {
            case .lastHeard: return "Last heard"
            case .name: return "Name"
            case .voiceprintCount: return "Voiceprints"
            }
        }
    }

    struct Group: Identifiable {
        var id: String
        var label: String
        var people: [KnownPerson]
    }

    static let noCompanyLabel = "No company"

    /// Filter by search text (name OR company substring, case-insensitive) and by an
    /// optional set of company labels (empty = all), then sort.
    static func apply(people: [KnownPerson], query: String, companies: Set<String>, sort: Sort) -> [KnownPerson] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = people.filter { person in
            let matchesQuery = q.isEmpty
                || person.name.lowercased().contains(q)
                || (person.company?.lowercased().contains(q) ?? false)
            let matchesCompany = companies.isEmpty || (person.company.map(companies.contains) ?? false)
            return matchesQuery && matchesCompany
        }
        return sorted(filtered, by: sort)
    }

    /// Groups people by company. "No company" bucket always sorts last; other groups
    /// are case-insensitive alphabetical. People within each group keep input order.
    static func grouped(people: [KnownPerson]) -> [Group] {
        var buckets: [String: [KnownPerson]] = [:]
        for person in people {
            let key = person.company?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = (key?.isEmpty ?? true) ? noCompanyLabel : key!
            buckets[label, default: []].append(person)
        }
        let named = buckets.keys.filter { $0 != noCompanyLabel }
            .sorted { $0.lowercased() < $1.lowercased() }
        var groups = named.map { Group(id: $0, label: $0, people: buckets[$0]!) }
        if let none = buckets[noCompanyLabel] {
            groups.append(Group(id: noCompanyLabel, label: noCompanyLabel, people: none))
        }
        return groups
    }

    /// Distinct non-nil company labels, case-insensitive sorted.
    static func companies(in people: [KnownPerson]) -> [String] {
        let names = people.compactMap { person -> String? in
            let c = person.company?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (c?.isEmpty ?? true) ? nil : c
        }
        return Array(Set(names)).sorted { $0.lowercased() < $1.lowercased() }
    }

    private static func sorted(_ people: [KnownPerson], by sort: Sort) -> [KnownPerson] {
        switch sort {
        case .lastHeard:
            return people.sorted { a, b in
                switch (VoiceLibraryDisplay.lastSeen(a), VoiceLibraryDisplay.lastSeen(b)) {
                case let (la?, lb?): return la != lb ? la > lb : a.name.lowercased() < b.name.lowercased()
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a.name.lowercased() < b.name.lowercased()
                }
            }
        case .name:
            return people.sorted { $0.name.lowercased() < $1.name.lowercased() }
        case .voiceprintCount:
            return people.sorted { a, b in
                a.voiceprints.count != b.voiceprints.count
                    ? a.voiceprints.count > b.voiceprints.count
                    : a.name.lowercased() < b.name.lowercased()
            }
        }
    }
}

/// Maps an email domain to a display company name, or nil for consumer/invalid domains.
enum CompanyName {
    private static let consumerDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com",
        "msn.com", "icloud.com", "me.com", "mac.com", "yahoo.com", "ymail.com",
        "proton.me", "protonmail.com", "aol.com", "gmx.com", "gmx.net"
    ]

    /// "acme.com" -> "Acme"; "mail.acme.co.uk" -> "Acme"; consumer/empty/invalid -> nil.
    static func fromDomain(_ domain: String?) -> String? {
        guard let raw = domain?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
        guard !consumerDomains.contains(raw) else { return nil }
        let labels = raw.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        // Second-level label, skipping a trailing 2-letter ccTLD's public suffix
        // (e.g. co.uk / com.au): if the penultimate label is a known public-suffix
        // second level, take the one before it.
        let publicSecondLevels: Set<String> = ["co", "com", "org", "net", "ac", "gov"]
        var idx = labels.count - 2
        if labels.count >= 3, publicSecondLevels.contains(labels[labels.count - 2]) {
            idx = labels.count - 3
        }
        let core = labels[idx]
        guard !core.isEmpty else { return nil }
        return core.prefix(1).uppercased() + core.dropFirst()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter VoiceLibraryFilter`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Services/VoiceLibraryFilter.swift Tests/dBriefTests/VoiceLibraryFilterTests.swift
git commit -m "feat(voice-library): pure filter/group/sort + domain->company helper"
```

---

### Task 3: Auto-suggest company at enrollment (fill-only)

**Files:**
- Modify: `Sources/dBrief/Services/RecordingManager.swift` (enrollment sites near lines 596–604 and 2949–2953)

**Interfaces:**
- Consumes: `CompanyName.fromDomain(_:)`, `VoiceLibraryStore.suggestCompanyIfEmpty(id:to:)`, `Recording.calendarEvent: CalendarEvent?`, `CalendarEvent.Person.name` + `.emailDomain`, existing `upsert`/`enrollVoiceprintOnRename`.
- Produces: `private func suggestCompany(forPersonId:name:recording:) async` on `RecordingManager`.

- [ ] **Step 1: Add the helper method**

Add near `enrollVoiceprintOnRename` in `RecordingManager`:

```swift
/// Fill-only company suggestion: if the enrolled name matches a calendar attendee
/// with a corporate email domain, seed the person's company (never overwrites).
private func suggestCompany(forPersonId personId: String, name: String, recording: Recording) async {
    guard !personId.isEmpty else { return }
    let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !key.isEmpty,
          let attendee = recording.calendarEvent?.attendees.first(where: { $0.name.lowercased() == key }),
          let company = CompanyName.fromDomain(attendee.emailDomain) else { return }
    await voiceLibraryStore.suggestCompanyIfEmpty(id: personId, to: company)
}
```

- [ ] **Step 2: Call it from the growth-loop enrollment**

In `enrollVoiceprintOnRename`, after `let id = await voiceLibraryStore.upsert(...)` and before returning, add:

```swift
await suggestCompany(forPersonId: id, name: trimmed, recording: recording)
```

(Place it before the `return id.isEmpty ? nil : id` line; `id == ""` makes `suggestCompany` a guarded no-op.)

- [ ] **Step 3: Call it from the pipeline enrollment loop**

In the pipeline enrollment loop (the `for entry in VoiceEnrollment.enrollable(...)` block), capture the upsert id and suggest. Replace:

```swift
await voiceLibraryStore.upsert(
    name: entry.name,
    voiceprint: Voiceprint(embedding: entry.embedding, model: "fluidaudio-wespeaker-256", capturedAt: Date())
)
```

with:

```swift
let enrolledId = await voiceLibraryStore.upsert(
    name: entry.name,
    voiceprint: Voiceprint(embedding: entry.embedding, model: "fluidaudio-wespeaker-256", capturedAt: Date())
)
await suggestCompany(forPersonId: enrolledId, name: entry.name, recording: recording)
```

Confirm the enclosing scope has a `recording` in scope at this site; if the local variable is named differently (e.g. `self.recording` or a job's recording), use that reference. Search the method for the recording binding before editing.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds clean (no test for this glue — behavior is covered by Task 1's fill-only test and Task 2's domain test; this task is pure wiring). If `recording` is not in scope at the pipeline site, resolve the correct binding rather than adding a parameter.

- [ ] **Step 5: Commit**

```bash
git add Sources/dBrief/Services/RecordingManager.swift
git commit -m "feat(voice-library): auto-suggest company from calendar attendee domain at enrollment"
```

---

### Task 4: Rewrite the settings tab as master–detail

**Files:**
- Modify (rewrite): `Sources/dBrief/UI/SettingsVoiceLibraryTab.swift`

**Interfaces:**
- Consumes: everything above — `VoiceLibraryFilter` (`apply`/`grouped`/`companies`/`Sort`), `VoiceLibraryStore` (`setCompany`, plus existing `rename`/`merge`/`delete`/`removeVoiceprint`/`load`), `VoiceLibraryDisplay` (`sampleSummary`/`lastSeen`), `KnownPerson.company`.
- Produces: no new cross-file API (self-contained view). Internal subviews `VoiceLibraryListPane` and `VoiceLibraryDetailPane` may be `private struct`s in the same file.

Note: SwiftUI views are verified by build + manual check, not unit tests — the logic they drive is already covered by Tasks 1–2.

- [ ] **Step 1: Rewrite the tab as an HSplitView master–detail**

Rewrite `SettingsVoiceLibraryTab` so its body is a list pane + detail pane. Preserve all existing capabilities (rename with collision→merge alert, merge sheet, forget-voice alert, per-voiceprint delete, privacy copy, empty state) and add: search field, `Company ▾` multi-select, `Sort ▾`, company-grouped collapsible list, single selection, and an editable company field in the detail pane. Keep the `@State`/`reload()` actor-load pattern and reselection rules below.

Key structure (fill in the existing alert/sheet modifiers, which stay unchanged in behavior):

```swift
import SwiftUI

struct SettingsVoiceLibraryTab: View {
    @Environment(AppContext.self) private var context

    @State private var library = VoiceLibrary()
    @State private var loaded = false
    @State private var selectedId: String?
    @State private var query = ""
    @State private var companyFilter: Set<String> = []
    @State private var sort: VoiceLibraryFilter.Sort = .lastHeard
    @State private var expandedGroups: Set<String> = []   // collapsed groups tracked by inverse if preferred
    @State private var expandedPrints: Set<String> = []   // person ids showing voiceprints

    // rename / merge / delete state (unchanged from current implementation)
    @State private var renaming: KnownPerson?
    @State private var renameText = ""
    @State private var deleteTarget: KnownPerson?
    @State private var mergeSource: KnownPerson?
    @State private var collision: (source: KnownPerson, existingId: String, name: String)?

    private var visiblePeople: [KnownPerson] {
        VoiceLibraryFilter.apply(people: library.people, query: query, companies: companyFilter, sort: sort)
    }
    private var groups: [VoiceLibraryFilter.Group] { VoiceLibraryFilter.grouped(people: visiblePeople) }
    private var selectedPerson: KnownPerson? { library.people.first { $0.id == selectedId } }

    var body: some View {
        HSplitView {
            listPane.frame(minWidth: 240, idealWidth: 260, maxWidth: 340)
            detailPane.frame(minWidth: 320, maxWidth: .infinity)
        }
        .task { if !loaded { await reload(); loaded = true } }
        // keep existing .alert(...) x2 and .sheet(item:) x2 modifiers here, unchanged
    }
    // listPane, detailPane, reload(), commitRename(...), etc. below
}
```

- [ ] **Step 2: Implement the list pane**

- A `TextField("Search", text: $query)` (rounded), a `Menu("Company")` with a toggle `Button` per `VoiceLibraryFilter.companies(in: library.people)` (checkmark when in `companyFilter`), and a `Picker` bound to `$sort` over `VoiceLibraryFilter.Sort.allCases` using `.label`.
- A `List(selection: $selectedId)` (or `ScrollView` + rows) rendering each `group` as a `Section`/`DisclosureGroup` with header `"\(group.label) (\(group.people.count))"`, collapsible via `expandedGroups`. Each person row shows `person.name` and `VoiceLibraryDisplay.sampleSummary(person)` + last-heard, tappable to set `selectedId = person.id`.
- Privacy copy (current string from `privacySection`) as a small `.footnote`/secondary footer at the bottom of the pane.
- Empty state (current `emptyState` copy) when `library.people.isEmpty`.

- [ ] **Step 3: Implement the detail pane**

- When `selectedPerson == nil`: a centered placeholder `Text("Select a person")` (secondary).
- Otherwise: name header; an editable company field:

```swift
// Company editor: local text bound to a per-selection @State, committed on change.
@State private var companyDraft = ""   // reset in .onChange(of: selectedId)
// ...
HStack {
    TextField("Add company", text: $companyDraft)
        .textFieldStyle(.roundedBorder).frame(width: 240)
        .onSubmit { commitCompany() }
    if companyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       let suggestion = companySuggestion(for: person) {
        Button("\(suggestion)?") { companyDraft = suggestion; commitCompany() }
            .buttonStyle(.link)
    }
}
```

  where `commitCompany()` calls `await context.voiceLibraryStore.setCompany(id: person.id, to: companyDraft); await reload()`. `companySuggestion(for:)` may return `nil` for now (no recording context in Settings) — keep the hook but it is acceptable for it to always return `nil` here; the real suggestion is written at enrollment (Task 3). Reset `companyDraft = selectedPerson?.company ?? ""` in `.onChange(of: selectedId)` and after `reload()`.
- Last-heard + `VoiceLibraryDisplay.sampleSummary(person)` summary line.
- Voiceprint list with per-print delete (reuse current index-keyed `ForEach` + trash button calling `removeVoiceprint`).
- Actions row: `Rename…`, `Merge into…` (when `library.people.count > 1`), `Forget voice` (destructive) — wired to the same `renaming`/`mergeSource`/`deleteTarget` state as today.

- [ ] **Step 4: Reselection after mutations**

In `reload()`, after loading, keep selection valid:

```swift
private func reload() async {
    library = await context.voiceLibraryStore.load()
    if let id = selectedId, !library.people.contains(where: { $0.id == id }) {
        selectedId = nil
    }
    companyDraft = selectedPerson?.company ?? ""
}
```

Additionally: on merge, set `selectedId = target.id` before reload; on delete, the invalid-id guard clears it. On rename, `selectedId` (the person id) is unchanged and stays valid.

- [ ] **Step 5: Build and verify**

Run: `swift build`
Expected: builds clean.

Run the full suite to confirm nothing regressed: `swift test`
Expected: PASS.

Manual verification (document what you observe):
- Search by a name and by a company substring narrows the list.
- `Company ▾` multi-select narrows; clearing shows all.
- Sort menu reorders (last heard / name / #voiceprints).
- People are grouped under company headers with counts; "No company" is last; groups collapse.
- Selecting a person shows detail; editing the company field persists (reopen Settings to confirm) and re-groups; clearing it moves the person to "No company".
- Rename / Merge / Forget / per-voiceprint delete still work, and selection lands sensibly after each.

- [ ] **Step 6: Commit**

```bash
git add Sources/dBrief/UI/SettingsVoiceLibraryTab.swift
git commit -m "feat(voice-library): master-detail tab with search, company grouping, sort"
```

---

## Self-Review

**Spec coverage:**
- Search (name+company) → Task 2 `apply` + Task 4 search field. ✓
- Group by company → Task 2 `grouped` + Task 4 list. ✓
- Filter by company → Task 2 `apply(companies:)` + Task 4 `Company ▾`. ✓
- Sort → Task 2 `Sort` + Task 4 `Sort ▾`. ✓
- `company` field + lenient decode → Task 1. ✓
- `setCompany` mutation → Task 1. ✓
- Fill-only auto-suggest from email domain → Task 1 `suggestCompanyIfEmpty` + Task 2 `CompanyName` + Task 3 wiring. ✓
- Master–detail layout, editable company w/ suggestion hint, empty-selection, reselection rules → Task 4. ✓
- "Needs attention" filter → correctly ABSENT (Non-Goal). ✓
- New pure file + tests mirroring convention → Task 2. ✓

**Placeholder scan:** `companySuggestion(for:)` in the Settings detail pane is intentionally allowed to return `nil` (Settings has no recording/calendar context) — this is a documented design decision, not a TODO; the suggestion path that matters is the enrollment write in Task 3. No other placeholders.

**Type consistency:** `suggestCompanyIfEmpty(id:to:)`, `setCompany(id:to:)`, `VoiceLibraryFilter.apply(people:query:companies:sort:)`, `.grouped(people:)`, `.companies(in:)`, `Sort` cases, `CompanyName.fromDomain(_:)`, `KnownPerson.company`, model tag `"fluidaudio-wespeaker-256"` — used identically across tasks. ✓
