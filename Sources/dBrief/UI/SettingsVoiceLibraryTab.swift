import SwiftUI

/// The Speakers page's Known people pane: management surface for the on-device voice
/// library (`VoiceLibraryStore`). A sortable, multi-select table (search, company
/// filter, optional grouping by company) with `VoiceLibraryInspector` beside it for one
/// person's details or bulk merge/forget. Reads the actor into local state and reloads
/// after every mutation.
///
/// The table is drawn rows, not a SwiftUI `Table`: an `NSTableView` paints its
/// selection in the system accent and keeps legacy scrollers, so it can't follow the
/// app's palette.
struct SettingsVoiceLibraryTab: View {
    @Environment(AppContext.self) private var context
    @Environment(\.viewerPalette) private var palette

    @State private var library = VoiceLibrary()
    @State private var loaded = false
    @State private var selection: Set<String> = []
    @State private var query = ""
    @State private var companyFilter: Set<String> = []
    @State private var sortColumn: VoiceLibraryRow.Column = .lastHeard
    @State private var sortAscending = false
    @State private var anchorId: String?
    @State private var hoveredId: String?
    @FocusState private var tableFocused: Bool
    @AppStorage("voiceLibraryGroupByCompany") private var groupByCompany = true

    @State private var renaming: KnownPerson?
    @State private var renameText = ""
    @State private var mergeSource: KnownPerson?
    @State private var collision: (source: KnownPerson, existingId: String, name: String)?
    @State private var forgetTargets: [KnownPerson] = []
    @State private var pendingMerge: (sources: [KnownPerson], survivor: KnownPerson)?

    private var visiblePeople: [KnownPerson] {
        VoiceLibraryFilter.apply(people: library.people, query: query, companies: companyFilter, sort: .name)
    }
    private var rows: [VoiceLibraryRow] {
        VoiceLibraryRow.sorted(visiblePeople.map(VoiceLibraryRow.init), by: sortColumn, ascending: sortAscending)
    }
    private var selectedPeople: [KnownPerson] { library.people.filter { selection.contains($0.id) } }
    private var totalVoiceprints: Int { library.people.reduce(0) { $0 + $1.voiceprints.count } }

    /// Company groups in table order: the sorted rows feed `grouped`, which keeps
    /// input order inside each group.
    private func groups(of rows: [VoiceLibraryRow]) -> [(group: VoiceLibraryFilter.Group, rows: [VoiceLibraryRow])] {
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let people = rows.compactMap { row in visiblePeople.first { $0.id == row.id } }
        return VoiceLibraryFilter.grouped(people: people).map { group in
            (group, group.people.compactMap { byId[$0.id] })
        }
    }

    var body: some View {
        Group {
            if library.people.isEmpty {
                emptyLibraryView
            } else {
                VStack(spacing: 0) {
                    toolbar
                    palette.divider.color.frame(height: 1)
                    HStack(spacing: 0) {
                        table
                        palette.divider.color.frame(width: 1)
                        VoiceLibraryInspector(selected: selectedPeople, libraryCount: library.people.count,
                                              voiceprintCount: totalVoiceprints, actions: actions)
                            .frame(width: 260)
                    }
                }
                .frame(minHeight: 420, maxHeight: .infinity)
            }
        }
        .task { if !loaded { await reload(); loaded = true } }
        .alert(forgetTitle, isPresented: Binding(get: { !forgetTargets.isEmpty }, set: { if !$0 { forgetTargets = [] } })) {
            Button("Forget", role: .destructive) {
                let ids = forgetTargets.map(\.id)
                Task {
                    for id in ids { await context.voiceLibraryStore.delete(id: id) }
                    await reload()
                }
            }
            Button("Cancel", role: .cancel) { forgetTargets = [] }
        } message: {
            Text("\(quotedNames(forgetTargets)) and all \(forgetTargets.count == 1 ? "its" : "their") voiceprints will be removed. This cannot be undone.")
        }
        .alert(mergeTitle, isPresented: Binding(get: { pendingMerge != nil }, set: { if !$0 { pendingMerge = nil } })) {
            Button("Merge", role: .destructive) {
                if let merge = pendingMerge { performMerge(sources: merge.sources, into: merge.survivor) }
            }
            Button("Cancel", role: .cancel) { pendingMerge = nil }
        } message: {
            if let merge = pendingMerge {
                let others = merge.sources.filter { $0.id != merge.survivor.id }
                Text("The voiceprints of \(quotedNames(others)) move into \u{201C}\(merge.survivor.name)\u{201D}, and \(others.count == 1 ? "that person is" : "those people are") removed. This cannot be undone.")
            }
        }
        .alert("Name already exists", isPresented: Binding(get: { collision != nil }, set: { if !$0 { collision = nil } })) {
            Button("Merge", role: .destructive) {
                if let c = collision {
                    Task {
                        await context.voiceLibraryStore.merge(sourceId: c.source.id, into: c.existingId)
                        selection = [c.existingId]
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

    // MARK: - Empty states

    private var emptyLibraryView: some View {
        SettingsRow("No voices saved yet",
                    caption: "A voice is added when you name a speaker in a transcript, or with “Save voice to library” from the speaker menu.",
                    systemImage: "person.wave.2")
    }

    /// The library has people, but the search/company filter matches none of them.
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
        .padding(.horizontal, 12)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Search name or company", text: $query)
                .settingsTextField()
                .frame(width: 220)

            Menu {
                ForEach(VoiceLibraryFilter.companies(in: library.people), id: \.self) { company in
                    Toggle(company, isOn: companyFilterBinding(company))
                }
                if !companyFilter.isEmpty {
                    Divider()
                    Button("Clear filter") { companyFilter.removeAll() }
                }
            } label: {
                Label(companyFilter.isEmpty ? "All companies" : "\(companyFilter.count) selected", systemImage: "building.2")
            }
            // The page scaffold sets `.switch`, which can't render in a menu.
            .toggleStyle(.automatic)
            .menuStyle(.button)
            .fixedSize()

            Toggle("Group by company", isOn: $groupByCompany)
                .toggleStyle(.checkbox)
                .tint(palette.primary.color)
                .uiFont(.system(size: 12))

            Spacer(minLength: 8)

            if selection.count > 1 {
                Text("\(selection.count) selected")
                    .uiFont(.system(size: 11.5))
                    .foregroundStyle(palette.secondary.color)
                Button("Merge \(selection.count)\u{2026}") { requestMerge(selectedPeople) }
                    .buttonStyle(.settingsSecondary)
                Button("Forget \(selection.count)", role: .destructive) { forgetTargets = selectedPeople }
                    .buttonStyle(.settingsDanger)
            } else {
                Text("\(library.people.count) \(library.people.count == 1 ? "person" : "people") · \(totalVoiceprints) voiceprints")
                    .uiFont(.system(size: 11.5))
                    .foregroundStyle(palette.secondary.color)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Table

    private enum ColumnWidth {
        static let company: CGFloat = 160
        static let voiceprints: CGFloat = 90
        static let firstHeard: CGFloat = 100
        static let lastHeard: CGFloat = 110
        static let spacing: CGFloat = 12
    }

    private var table: some View {
        let rows = rows
        let order = rows.map(\.id)
        return VStack(spacing: 0) {
            columnHeader
            palette.divider.color.frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if groupByCompany {
                        ForEach(groups(of: rows), id: \.group.id) { entry in
                            Text("\(entry.group.label) · \(entry.rows.count)")
                                .uiFont(.system(size: 11, weight: .semibold))
                                .foregroundStyle(palette.secondary.color)
                                .padding(.horizontal, 10)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(entry.rows) { row in rowView(row, order: order) }
                        }
                    } else {
                        ForEach(rows) { row in rowView(row, order: order) }
                    }
                }
                .padding(6)
                .overlayScrollers()
            }
            .scrollBounceBehavior(.basedOnSize)
            .overlay {
                if rows.isEmpty { noSearchResultsView }
            }
        }
        .frame(maxWidth: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($tableFocused)
        .onKeyPress(.upArrow) { moveSelection(by: -1, order: order) }
        .onKeyPress(.downArrow) { moveSelection(by: 1, order: order) }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard !selection.isEmpty else { return .ignored }
            forgetTargets = selectedPeople
            return .handled
        }
        .onKeyPress(characters: ["a"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            selection = Set(order)
            return .handled
        }
    }

    private var columnHeader: some View {
        HStack(spacing: ColumnWidth.spacing) {
            headerButton(.name).frame(maxWidth: .infinity, alignment: .leading)
            headerButton(.company).frame(width: ColumnWidth.company, alignment: .leading)
            headerButton(.voiceprints).frame(width: ColumnWidth.voiceprints, alignment: .leading)
            headerButton(.firstHeard).frame(width: ColumnWidth.firstHeard, alignment: .leading)
            headerButton(.lastHeard).frame(width: ColumnWidth.lastHeard, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
    }

    private func headerButton(_ column: VoiceLibraryRow.Column) -> some View {
        let active = sortColumn == column
        return Button {
            if active {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = column.startsAscending
            }
        } label: {
            HStack(spacing: 4) {
                Text(column.title)
                if active {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .uiFont(.system(size: 11.5, weight: active ? .semibold : .medium))
            .foregroundStyle(active ? palette.heading.color : palette.secondary.color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(column.title)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func rowView(_ row: VoiceLibraryRow, order: [String]) -> some View {
        let isSelected = selection.contains(row.id)
        let person = library.people.first { $0.id == row.id }
        return HStack(spacing: ColumnWidth.spacing) {
            HStack(spacing: 8) {
                VoiceLibraryAvatar(name: row.name, colorKey: row.company ?? row.name)
                Text(row.name)
                    .uiFont(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(palette.heading.color)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)

            Group {
                if let person {
                    VoiceLibraryCompanyField(company: row.company) { setCompany(person, $0) }
                        .id(row.id)
                        .uiFont(.system(size: 12))
                        .foregroundStyle(palette.text.color)
                }
            }
            .frame(width: ColumnWidth.company, alignment: .leading)

            Group {
                HStack(spacing: 6) {
                    VoiceLibraryStrengthMeter(strength: row.strength)
                    Text("\(row.voiceprintCount)").uiFont(.system(size: 12).monospacedDigit())
                }
                .frame(width: ColumnWidth.voiceprints, alignment: .leading)
                Text(row.firstHeard?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                    .frame(width: ColumnWidth.firstHeard, alignment: .leading)
                Text(row.lastHeard?.formatted(.relative(presentation: .named)) ?? "—")
                    .frame(width: ColumnWidth.lastHeard, alignment: .leading)
            }
            .uiFont(.system(size: 12))
            .foregroundStyle(palette.secondary.color)
            .lineLimit(1)
            .allowsHitTesting(false)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        // Clicks land on this layer (the cells above ignore hits) so the company
        // field keeps its own clicks for editing.
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? palette.selected.color
                      : hoveredId == row.id ? palette.divider.color.opacity(0.35) : .clear)
                .contentShape(Rectangle())
                .onTapGesture { click(row, order: order) }
        }
        .onHover { inside in
            if inside { hoveredId = row.id } else if hoveredId == row.id { hoveredId = nil }
        }
        .contextMenu {
            contextMenu(for: selection.contains(row.id) ? selectedPeople : person.map { [$0] } ?? [])
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Rename") { if let person { actions.rename(person) } }
    }

    private func click(_ row: VoiceLibraryRow, order: [String]) {
        tableFocused = true
        if NSApp.currentEvent?.clickCount == 2, let person = library.people.first(where: { $0.id == row.id }) {
            selection = [row.id]
            actions.rename(person)
            return
        }
        let flags = NSEvent.modifierFlags
        let next = VoiceLibrarySelection.click(row.id, order: order, current: selection, anchor: anchorId,
                                               command: flags.contains(.command), shift: flags.contains(.shift))
        selection = next.selection
        anchorId = next.anchor
    }

    private func moveSelection(by step: Int, order: [String]) -> KeyPress.Result {
        guard let id = VoiceLibrarySelection.move(by: step, order: order, current: selection) else { return .ignored }
        selection = [id]
        anchorId = id
        return .handled
    }

    @ViewBuilder
    private func contextMenu(for people: [KnownPerson]) -> some View {
        if people.count == 1, let person = people.first {
            Button("Rename\u{2026}") { actions.rename(person) }
            if library.people.count > 1 {
                Button("Merge into\u{2026}") { actions.mergeInto(person) }
            }
            Divider()
            Button("Forget voice", role: .destructive) { forgetTargets = [person] }
        } else if people.count > 1 {
            Button("Merge \(people.count) people\u{2026}") { requestMerge(people) }
            Divider()
            Button("Forget \(people.count) voices", role: .destructive) { forgetTargets = people }
        }
    }

    // MARK: - Actions

    private var actions: VoiceLibraryActions {
        VoiceLibraryActions(
            rename: { person in renameText = person.name; renaming = person },
            mergeInto: { person in mergeSource = person },
            merge: { sources, survivor in pendingMerge = (sources, survivor) },
            forget: { people in forgetTargets = people },
            removeVoiceprint: { person, capturedAt in
                Task {
                    await context.voiceLibraryStore.removeVoiceprint(personId: person.id, capturedAt: capturedAt)
                    await reload()
                }
            },
            setCompany: { person, value in setCompany(person, value) }
        )
    }

    private func requestMerge(_ people: [KnownPerson]) {
        guard people.count > 1, let survivor = VoiceLibraryDisplay.mergeSurvivor(people) else { return }
        pendingMerge = (people, survivor)
    }

    private func performMerge(sources: [KnownPerson], into survivor: KnownPerson) {
        let sourceIds = sources.map(\.id).filter { $0 != survivor.id }
        Task {
            for id in sourceIds { await context.voiceLibraryStore.merge(sourceId: id, into: survivor.id) }
            selection = [survivor.id]
            await reload()
        }
    }

    private func setCompany(_ person: KnownPerson, _ value: String) {
        Task {
            await context.voiceLibraryStore.setCompany(id: person.id, to: value)
            await reload()
        }
    }

    private var forgetTitle: String {
        forgetTargets.count == 1 ? "Forget this voice?" : "Forget \(forgetTargets.count) voices?"
    }

    private var mergeTitle: String {
        guard let merge = pendingMerge else { return "" }
        return "Merge into \u{201C}\(merge.survivor.name)\u{201D}?"
    }

    private func quotedNames(_ people: [KnownPerson]) -> String {
        people.map { "\u{201C}\($0.name)\u{201D}" }.formatted(.list(type: .and))
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
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(VoiceLibraryDisplay.sortedByLastSeen(library.people.filter { $0.id != source.id })) { target in
                        Button {
                            Task {
                                await context.voiceLibraryStore.merge(sourceId: source.id, into: target.id)
                                mergeSource = nil
                                selection = [target.id]
                                await reload()
                            }
                        } label: {
                            HStack { Text(target.name); Spacer(); Text(VoiceLibraryDisplay.sampleSummary(target)).foregroundStyle(.secondary) }
                        }
                        .buttonStyle(.typographyBordered)
                    }
                }
            }
            .frame(maxHeight: 360)
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

    private func companyFilterBinding(_ company: String) -> Binding<Bool> {
        Binding(
            get: { companyFilter.contains(company) },
            set: { isOn in
                if isOn { companyFilter.insert(company) } else { companyFilter.remove(company) }
            }
        )
    }

    // MARK: - Load

    private func reload() async {
        library = await context.voiceLibraryStore.load()
        let ids = Set(library.people.map(\.id))
        selection.formIntersection(ids)
    }
}
