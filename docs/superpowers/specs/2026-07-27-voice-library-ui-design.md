# Voice Library UI Redesign — Design

**Date:** 2026-07-27
**Status:** Approved (design), pending spec review

## Problem

The **Settings → Voice Library** tab (`SettingsVoiceLibraryTab`) renders every known
person as a single flat, scrolling list sorted by last-heard. This does not scale: a
library with dozens of people becomes an undifferentiated wall of rows with no way to
find one person quickly, focus on a subset, or organize by who they work with.

## Goals

- **Search** — find a person fast by name or company.
- **Group by company** — organize people by the company they belong to.
- **Filter by company** — narrow the list to one or more companies.
- **Sort** — choose ordering within the list (last heard / name / #voiceprints).
- Scale gracefully as the library grows.

## Non-Goals

- **"Needs attention" / curation filter** (weak or stale voiceprints) — explicitly
  deferred. Not in this pass.
- Card-grid / avatar layout.
- Any change to how voiceprints are captured, matched, or stored on disk beyond the one
  new field below.
- Keychain/company data sync or upload — everything stays on-device, unchanged.

## Approach

Master–detail layout inside the existing settings tab (the settings window already has
its own outer sidebar, so this becomes a nested list + detail — a standard macOS
pattern, e.g. Users & Groups). Company is a new per-person field that is
**auto-suggested** from calendar-attendee email domains at enrollment and always
user-editable.

## Data Model

Add one optional field to `KnownPerson` (`Models/VoiceLibrary.swift`):

```swift
var company: String?   // nil = "No company". Decoded leniently; old libraries load unchanged.
```

- Optional `Codable` — no migration, no version bump required. Existing `library.json`
  files decode with `company == nil`.
- `VoiceLibrary.version` stays `1`.

New mutation on the `VoiceLibraryStore` actor (mirrors `rename`):

```swift
func setCompany(id: String, to company: String?) async
```

- Trims whitespace; an empty string is stored as `nil`.
- Atomic write, same as the other mutations.

## Auto-Suggest Company (fill-only)

A **pure, unit-tested** helper maps an email domain to a display company name:

```swift
enum CompanyName {
    /// "acme.com" -> "Acme"; "servicenow.com" -> "Servicenow";
    /// nil for consumer/personal domains (gmail, outlook, hotmail, icloud,
    /// yahoo, proton, me, live, aol, gmx, ...) and for empty/invalid input.
    static func fromDomain(_ domain: String?) -> String?
}
```

- Strips the TLD, takes the second-level label, title-cases it.
- Returns `nil` for a curated consumer-domain denylist so personal emails never seed a
  bogus company.

**Where it runs:** at enrollment in `RecordingManager` — both
`enrollVoiceprintOnRename(recording:speakerId:name:)` and the pipeline batch `upsert`
path. After a person is upserted, if their `company` is still `nil` and a calendar
attendee (from the recording's selected/candidate `CalendarEvent`) matches the enrolled
name case-insensitively, derive `CompanyName.fromDomain(attendee.emailDomain)` and, when
non-nil, call `setCompany`.

**Fill-only invariant:** auto-suggest only ever populates an empty company. It never
overwrites a value the user (or a prior enrollment) already set. The user can edit or
clear it at any time in the detail pane.

`CalendarEvent.Person` already exposes `email` and a derived `emailDomain`
(`Models/CalendarEvent.swift`), so no calendar-layer changes are needed.

## Pure Filtering / Grouping Logic

A new pure, no-I/O helper file `Services/VoiceLibraryFilter.swift`, unit-tested the same
way as `VoiceLibraryDisplay`:

```swift
enum VoiceLibraryFilter {
    enum Sort { case lastHeard, name, voiceprintCount }   // default .lastHeard

    /// Filter by search text (name OR company, case-insensitive substring) and by an
    /// optional set of company labels, then sort.
    static func apply(
        people: [KnownPerson],
        query: String,
        companies: Set<String>,          // empty = all companies
        sort: Sort
    ) -> [KnownPerson]

    /// Group the (already-filtered) people by company. "No company" bucket sorts last;
    /// each group carries its people and an implicit count (people.count).
    static func grouped(people: [KnownPerson]) -> [Group]

    struct Group: Identifiable {
        var id: String            // company label, or a sentinel for "No company"
        var label: String         // display label, e.g. "Acme" or "No company"
        var people: [KnownPerson]
    }
}
```

- `.lastHeard` reuses `VoiceLibraryDisplay.lastSeen` semantics (newest-first, no-print
  people last, name tie-break).
- `.name` is case-insensitive ascending.
- `.voiceprintCount` is descending, name tie-break.
- Company labels for the filter picker come from the distinct non-nil companies in the
  library, sorted case-insensitively.

`CompanyName.fromDomain` lives in this file (or an adjacent `CompanyName.swift`).

## Layout

### Left column (people list pane, ~240pt min width)

- **Search field** at top (`name OR company`, live substring filter).
- **Filter row:** a `Company ▾` multi-select menu (distinct companies; empty selection =
  all) and a `Sort ▾` menu (Last heard / Name / # voiceprints).
- **Grouped, collapsible list**, grouped by company by default, each section header
  showing a count badge; "No company" section last. Single-selection highlights the
  active person.
- A short **privacy line** as a footer (same copy as today, condensed): voiceprints are
  on-device only, never uploaded, forgettable anytime.

### Right pane (detail for the selected person)

- Name header.
- **Editable Company field** — plain text field bound through `setCompany`. When the
  company is empty and an auto-suggestion is available, show it as a tappable hint
  (e.g. "Acme? · from calendar") that fills the field on tap.
- Last-heard + voiceprint-count summary (reuses `VoiceLibraryDisplay`).
- **Voiceprint list** with per-print delete (existing behavior, index-keyed).
- Existing actions: **Rename**, **Merge into…**, **Forget voice** (destructive).
- **Empty-selection placeholder** ("Select a person") when nothing is selected.

### Selection behavior after mutations

- **Rename:** keep selection (same `id`).
- **Merge:** select the merge target.
- **Forget / delete:** clear selection (detail returns to placeholder).
- After any reload, if the selected id no longer exists, clear selection.

## Files Touched

| File | Change |
|------|--------|
| `Models/VoiceLibrary.swift` | Add `var company: String?` to `KnownPerson`. |
| `Services/VoiceLibraryStore.swift` | Add `setCompany(id:to:)`. |
| `Services/VoiceLibraryFilter.swift` | **New.** Pure filter/group/sort + `CompanyName.fromDomain`. |
| `Tests/dBriefTests/VoiceLibraryFilterTests.swift` | **New.** Cover filter, group, sort, domain mapping (incl. consumer-domain nil). |
| `Services/RecordingManager.swift` | Derive + set company suggestion at enrollment (fill-only). |
| `UI/SettingsVoiceLibraryTab.swift` | Rewrite as master–detail; extract `VoiceLibraryListPane` + `VoiceLibraryDetailPane` subviews. |

## Testing

- `VoiceLibraryFilterTests`:
  - Search matches name; search matches company; case-insensitive; empty query = all.
  - Company filter narrows; empty set = all.
  - Each `Sort` order (incl. tie-breaks and no-print handling).
  - Grouping: "No company" bucket sorts last; counts correct; distinct companies grouped.
  - `CompanyName.fromDomain`: `acme.com → Acme`; consumer domains → nil; empty/invalid → nil.
- Existing `VoiceLibraryStoreTests` / `VoiceLibraryDisplayTests` continue to pass;
  add a `setCompany` round-trip + fill-only (no overwrite) assertion to the store tests.
- Manual: enroll a speaker matched to a calendar attendee with a corporate email →
  company auto-fills; a gmail attendee → stays "No company"; edit/clear persists.

## Risks / Notes

- Name↔attendee matching for auto-suggest is best-effort and case-insensitive on display
  name; a mismatch simply leaves company empty (no harm, user fills it in).
- Consumer-domain denylist is a curated list; unknown corporate domains still map (that's
  the desired default). The denylist only guards the obvious personal providers.
