import SwiftUI

/// The Speakers page's Known people pane: management surface for the on-device voice library
/// (`VoiceLibraryStore`): a master-detail split with search, company filter/grouping,
/// and sort in the list pane, and rename/merge/forget/per-voiceprint-delete plus an
/// editable company field in the detail pane. Reads the actor into local state and
/// reloads after every mutation.
struct SettingsVoiceLibraryTab: View {
    @Environment(AppContext.self) private var context
    @Environment(\.viewerPalette) private var palette

    @State private var library = VoiceLibrary()
    @State private var loaded = false
    @State private var selectedId: String?
    @State private var query = ""
    @State private var companyFilter: Set<String> = []
    @State private var sort: VoiceLibraryFilter.Sort = .lastHeard
    @State private var collapsedGroups: Set<String> = []
    @State private var expandedPrints: Set<String> = []     // person ids showing voiceprints
    @State private var companyDraft = ""
    // True whenever `companyDraft` holds an uncommitted edit. Guards `reload()` (which
    // otherwise runs after every mutation — delete/rename/merge — and would silently
    // discard in-progress typing) and drives the flush-on-selection-change below.
    @State private var companyDraftDirty = false
    // Suppresses the `companyDraft` onChange from marking the draft dirty when *we*
    // (not the user) assign it programmatically (selection change, reload, commit).
    @State private var isProgrammaticCompanyUpdate = false

    // Rename / merge / delete state (unchanged from the prior implementation).
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
    /// Distinct from the empty-library state: the library has people, but the current
    /// search/company filter matches none of them.
    private var hasNoSearchResults: Bool { !library.people.isEmpty && visiblePeople.isEmpty }

    var body: some View {
        Group {
            if library.people.isEmpty {
                emptyLibraryView
            } else {
                HSplitView {
                    listPane.frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
                    detailPane.frame(minWidth: 280, maxWidth: .infinity)
                }
                .frame(height: 380)
            }
        }
        .task { if !loaded { await reload(); loaded = true } }
        .onChange(of: selectedId) { oldId, newId in
            // Flush any uncommitted edit against the OLD selection before touching the
            // draft — selectedId has already changed to `newId` by the time this fires,
            // so reading `companyDraft` against `selectedId`/`selectedPerson` here would
            // write the just-typed text onto the newly selected person instead.
            flushCompanyDraft(previousId: oldId)
            let newCompany = library.people.first { $0.id == newId }?.company ?? ""
            applyCompanyDraft(newCompany)
        }
        .onChange(of: companyDraft) { _, _ in
            if !isProgrammaticCompanyUpdate {
                companyDraftDirty = true
            }
        }
        .alert("Forget this voice?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("Forget", role: .destructive) {
                if let t = deleteTarget { Task { await context.voiceLibraryStore.delete(id: t.id); await reload() } }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("\u{201C}\(deleteTarget?.name ?? "")\u{201D} and all its voiceprints will be removed. This cannot be undone.")
        }
        .alert("Name already exists", isPresented: Binding(get: { collision != nil }, set: { if !$0 { collision = nil } })) {
            Button("Merge", role: .destructive) {
                if let c = collision {
                    Task {
                        await context.voiceLibraryStore.merge(sourceId: c.source.id, into: c.existingId)
                        selectedId = c.existingId
                        await reload()
                    }
                }
            }
            Button("Cancel", role: .cancel) { collision = nil }
        } message: {
            Text("Another person is already named \u{201C}\(collision?.name ?? "")\u{201D}. Merge \u{201C}\(collision?.source.name ?? "")\u{201D} into them?")
        }
        .sheet(item: $renaming) { person in renameSheet(person) }
        .sheet(item: $mergeSource) { person in mergeSheet(person) }
    }

    // MARK: - Empty library (no people saved yet)

    private var emptyLibraryView: some View {
        SettingsRow("No voices saved yet",
                    caption: "A voice is added when you name a speaker in a transcript, or with “Save voice to library” from the speaker menu.",
                    systemImage: "person.wave.2")
    }

    /// Shown inside the list pane when the library has people but the current
    /// search/company filter matches none of them — distinct from `emptyLibraryView`
    /// (no people saved yet at all), whose copy stays unchanged.
    private var noSearchResultsView: some View {
        VStack(spacing: 6) {
            Text("No people match your search.")
                .uiFont(.system(size: 12))
                .foregroundStyle(palette.heading.color)
            Text("Try a different name or company.")
                .uiFont(.system(size: 11.5))
                .foregroundStyle(palette.secondary.color)
            Button("Clear filters") {
                query = ""
                companyFilter.removeAll()
            }
            .buttonStyle(.settingsSecondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
    }

    // MARK: - List pane

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search name or company", text: $query)
                .settingsTextField()

            HStack {
                Menu {
                    ForEach(VoiceLibraryFilter.companies(in: library.people), id: \.self) { company in
                        Toggle(company, isOn: companyFilterBinding(company))
                    }
                    if !companyFilter.isEmpty {
                        Divider()
                        Button("Clear filter") { companyFilter.removeAll() }
                    }
                } label: {
                    Label("Company", systemImage: "building.2")
                }
                // The page scaffold sets `.switch`; a switch can't render in a menu,
                // so the company items would show disabled.
                .toggleStyle(.automatic)
                .menuStyle(.button)
                .fixedSize()

                Spacer()

                Picker("Sort", selection: $sort) {
                    ForEach(VoiceLibraryFilter.Sort.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            if hasNoSearchResults {
                noSearchResultsView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedId) {
                    ForEach(groups) { group in
                        Section(isExpanded: expandedBinding(for: group)) {
                            ForEach(group.people) { person in
                                listRow(person)
                            }
                        } header: {
                            Text("\(group.label) (\(group.people.count))")
                        }
                    }
                }
                .listStyle(.sidebar)
                // .sidebar keeps the collapsible group headers, but brings the
                // translucent sidebar material with it — hide that backdrop so the
                // list matches the settings pane's solid background.
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)
            }
        }
        .padding(12)
        .background(palette.canvas.color)
    }

    @ViewBuilder
    private func listRow(_ person: KnownPerson) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Semantic styles, not palette colours: they turn white on the list's selection fill.
            Text(person.name).uiFont(.system(size: 12.5, weight: .medium)).foregroundStyle(.primary)
            Text(caption(person)).uiFont(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail pane

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let person = selectedPerson {
                    personDetail(person)
                } else {
                    selectionPlaceholder
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var selectionPlaceholder: some View {
        Text("Select a person")
            .uiFont(.system(size: 12))
            .foregroundStyle(palette.secondary.color)
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .center)
    }

    @ViewBuilder
    private func personDetail(_ person: KnownPerson) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(person.name).uiFont(.system(size: 17, weight: .semibold)).foregroundStyle(palette.heading.color)
            Text(caption(person)).uiFont(.system(size: 11.5)).foregroundStyle(palette.secondary.color)
        }

        HStack {
            Text("Company").uiFont(.system(size: 12, weight: .medium)).foregroundStyle(palette.heading.color)
            TextField("Add company", text: $companyDraft)
                .settingsTextField()
                .frame(width: 240)
                .onSubmit { commitCompany() }
        }

        palette.divider.color.frame(height: 1)

        voiceprintsSection(person)

        palette.divider.color.frame(height: 1)

        actionsRow(person)
    }

    @ViewBuilder
    private func voiceprintsSection(_ person: KnownPerson) -> some View {
        let isExpanded = expandedPrints.contains(person.id)
        Button {
            toggleExpandedPrints(person.id)
        } label: {
            HStack {
                Text(isExpanded ? "Hide voiceprints" : "Show voiceprints (\(person.voiceprints.count))")
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.secondary.color)

        if isExpanded {
            // Index-based identity: capturedAt is not guaranteed unique (two prints
            // can land in the same second), and the list is a fixed-order snapshot,
            // so the offset is a stable, collision-free key.
            ForEach(Array(person.voiceprints.enumerated()), id: \.offset) { _, vp in
                HStack {
                    Text("Captured \(vp.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                        .uiFont(.system(size: 11.5)).foregroundStyle(palette.secondary.color)
                    Spacer()
                    Button {
                        Task {
                            await context.voiceLibraryStore.removeVoiceprint(personId: person.id, capturedAt: vp.capturedAt)
                            await reload()
                        }
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.settingsSecondary)
                    .accessibilityLabel("Forget this voiceprint")
                }
                .padding(.leading, 16)
            }
        }
    }

    @ViewBuilder
    private func actionsRow(_ person: KnownPerson) -> some View {
        HStack(spacing: 8) {
            Button("Rename\u{2026}") { renameText = person.name; renaming = person }
                .buttonStyle(.settingsSecondary)
            if library.people.count > 1 {
                Button("Merge into\u{2026}") { mergeSource = person }
                    .buttonStyle(.settingsSecondary)
            }
            Spacer()
            Button("Forget voice", role: .destructive) { deleteTarget = person }
                .buttonStyle(.settingsDanger)
        }
    }

    private func caption(_ person: KnownPerson) -> String {
        let summary = VoiceLibraryDisplay.sampleSummary(person)
        if let seen = VoiceLibraryDisplay.lastSeen(person) {
            return "\(summary) \u{00B7} last heard \(seen.formatted(.relative(presentation: .named)))"
        }
        return summary
    }

    // MARK: - Sheets

    @ViewBuilder
    private func renameSheet(_ person: KnownPerson) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Voice").uiFont(.headline)
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
            Text("Merge \u{201C}\(source.name)\u{201D} into\u{2026}").uiFont(.headline)
            Text("All of \(source.name)\u{2019}s voiceprints move into the person you pick, and \u{201C}\(source.name)\u{201D} is removed.")
                .uiFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(library.people.filter { $0.id != source.id }) { target in
                Button {
                    Task {
                        await context.voiceLibraryStore.merge(sourceId: source.id, into: target.id)
                        mergeSource = nil
                        selectedId = target.id
                        await reload()
                    }
                } label: {
                    HStack { Text(target.name); Spacer(); Text(VoiceLibraryDisplay.sampleSummary(target)).foregroundStyle(.secondary) }
                }
                .buttonStyle(.typographyBordered)
            }
            HStack { Spacer(); Button("Cancel") { mergeSource = nil } }
        }
        .padding(20)
        .frame(minWidth: 320)
    }

    // MARK: - Mutations

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

    private func commitCompany() {
        guard let id = selectedId else { return }
        let value = companyDraft
        // Clear dirty synchronously (before the await) so any further typing that
        // happens while this Task is in flight (Return keeps focus in the field) is
        // detected as a *new* dirty edit by the companyDraft onChange, and therefore
        // survives the reload() at the end of this same commit (see FIX 4).
        companyDraftDirty = false
        Task {
            await context.voiceLibraryStore.setCompany(id: id, to: value)
            await reload()
        }
    }

    /// Commits the draft against `previousId` (the selection being navigated away
    /// from) if it's dirty and actually differs from that person's stored company;
    /// otherwise a no-op. Always clears the dirty flag — the draft is about to be
    /// replaced by `applyCompanyDraft` for the new selection either way.
    private func flushCompanyDraft(previousId: String?) {
        defer { companyDraftDirty = false }
        guard companyDraftDirty, let id = previousId else { return }
        let value = companyDraft
        let storedValue = library.people.first(where: { $0.id == id })?.company ?? ""
        guard value != storedValue else { return }
        Task {
            await context.voiceLibraryStore.setCompany(id: id, to: value)
            await reload()
        }
    }

    /// Assigns `companyDraft` without marking it dirty — the one path programmatic
    /// resets (selection change, reload, commit) should use instead of `companyDraft = `.
    private func applyCompanyDraft(_ value: String) {
        isProgrammaticCompanyUpdate = true
        companyDraft = value
        isProgrammaticCompanyUpdate = false
    }

    // MARK: - Local UI state helpers

    private func companyFilterBinding(_ company: String) -> Binding<Bool> {
        Binding(
            get: { companyFilter.contains(company) },
            set: { isOn in
                if isOn { companyFilter.insert(company) } else { companyFilter.remove(company) }
            }
        )
    }

    private func expandedBinding(for group: VoiceLibraryFilter.Group) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(group.id) },
            set: { isExpanded in
                if isExpanded { collapsedGroups.remove(group.id) } else { collapsedGroups.insert(group.id) }
            }
        )
    }

    private func toggleExpandedPrints(_ id: String) {
        if expandedPrints.contains(id) { expandedPrints.remove(id) } else { expandedPrints.insert(id) }
    }

    // MARK: - Load

    private func reload() async {
        library = await context.voiceLibraryStore.load()
        if let id = selectedId, !library.people.contains(where: { $0.id == id }) {
            selectedId = nil
        }
        // A mutation elsewhere (voiceprint delete, rename, merge) must not clobber an
        // uncommitted company edit still in progress — only resync the draft from the
        // store when there's nothing pending to lose.
        if !companyDraftDirty {
            applyCompanyDraft(selectedPerson?.company ?? "")
        }
    }
}
