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
    // Starts wide so the first frame shows every column; the measured width follows.
    @State private var tableWidth: CGFloat = .greatestFiniteMagnitude
    @State private var editingCompany = false
    @FocusState private var tableFocused: Bool
    @AppStorage("voiceLibraryGroupByCompany") private var groupByCompany = true

    @State private var renaming: KnownPerson?
    @State private var renameText = ""
    @State private var mergeSource: KnownPerson?
    @State private var collision: NameCollision?
    @State private var showingCollision = false
    @State private var forgetTargets: [KnownPerson] = []
    @State private var confirmingForget = false
    @State private var pendingMerge: MergeRequest?
    @State private var confirmingMerge = false

    private struct MergeRequest {
        let sources: [KnownPerson]
        let survivor: KnownPerson
    }

    private struct NameCollision {
        let source: KnownPerson
        let existingId: String
        let name: String
    }

    private var visiblePeople: [KnownPerson] {
        VoiceLibraryFilter.apply(people: library.people, query: query, companies: companyFilter, sort: .name)
    }
    private var rows: [VoiceLibraryRow] {
        VoiceLibraryRow.sorted(visiblePeople.map(VoiceLibraryRow.init), by: sortColumn, ascending: sortAscending)
    }
    private var selectedPeople: [KnownPerson] { library.people.filter { selection.contains($0.id) } }
    private var totalVoiceprints: Int { library.people.reduce(0) { $0 + $1.voiceprints.count } }

    private var columns: VoiceLibraryColumns { VoiceLibraryColumns(tableWidth: tableWidth) }

    /// Company groups in table order: the sorted rows feed `grouped`, which keeps
    /// input order inside each group.
    private func groups(of rows: [VoiceLibraryRow],
                        peopleById: [String: KnownPerson]) -> [(group: VoiceLibraryFilter.Group, rows: [VoiceLibraryRow])] {
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let people = rows.compactMap { peopleById[$0.id] }
        return VoiceLibraryFilter.grouped(people: people).map { group in
            (group, group.people.compactMap { byId[$0.id] })
        }
    }

    var body: some View {
        Group {
            if library.people.isEmpty {
                emptyLibraryView
            } else {
                let columns = columns
                VStack(spacing: 0) {
                    toolbar(compact: !columns.showsDates)
                    palette.divider.color.frame(height: 1)
                    HStack(spacing: 0) {
                        table(columns)
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
        // `presenting:` keeps each alert's data intact while it animates out.
        .alert(forgetTitle, isPresented: $confirmingForget, presenting: forgetTargets) { targets in
            Button("Forget", role: .destructive) {
                let ids = targets.map(\.id)
                Task {
                    for id in ids { await context.voiceLibraryStore.delete(id: id) }
                    await reload()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { targets in
            Text("\(quotedNames(targets)) and all \(targets.count == 1 ? "its" : "their") voiceprints will be removed. This cannot be undone.")
        }
        .alert(mergeTitle, isPresented: $confirmingMerge, presenting: pendingMerge) { merge in
            Button("Merge", role: .destructive) { performMerge(sources: merge.sources, into: merge.survivor) }
            Button("Cancel", role: .cancel) {}
        } message: { merge in
            let others = merge.sources.filter { $0.id != merge.survivor.id }
            Text("The voiceprints of \(quotedNames(others)) move into \u{201C}\(merge.survivor.name)\u{201D}, and \(others.count == 1 ? "that person is" : "those people are") removed. This cannot be undone.")
        }
        .alert("Name already exists", isPresented: $showingCollision, presenting: collision) { collision in
            Button("Merge", role: .destructive) {
                Task {
                    await context.voiceLibraryStore.merge(sourceId: collision.source.id, into: collision.existingId)
                    selection = [collision.existingId]
                    await reload()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { collision in
            Text("Another person is already named \u{201C}\(collision.name)\u{201D}. Merge \u{201C}\(collision.source.name)\u{201D} into them?")
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

    /// `compact` (the table is too narrow for the date columns) drops the trailing
    /// count and bulk actions; the inspector shows both.
    private func toolbar(compact: Bool) -> some View {
        HStack(spacing: 10) {
            TextField("Search name or company", text: $query)
                .settingsTextField()
                .frame(minWidth: 140, maxWidth: 220)

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
                .uiFont(.system(size: 12))

            Spacer(minLength: 8)

            if !compact {
                if selection.count > 1 {
                    Text("\(selection.count) selected")
                        .uiFont(.system(size: 11.5))
                        .foregroundStyle(palette.secondary.color)
                    Button("Merge \(selection.count)\u{2026}") { requestMerge(selectedPeople) }
                        .buttonStyle(.settingsSecondary)
                    Button("Forget \(selection.count)", role: .destructive) { requestForget(selectedPeople) }
                        .buttonStyle(.settingsDanger)
                } else {
                    Text("^[\(library.people.count) person](inflect: true) · ^[\(totalVoiceprints) voiceprint](inflect: true)")
                        .uiFont(.system(size: 11.5))
                        .foregroundStyle(palette.secondary.color)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Table

    private func table(_ columns: VoiceLibraryColumns) -> some View {
        let rows = rows
        let order = rows.map(\.id)
        let peopleById = Dictionary(library.people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let selected = selectedPeople
        return VStack(spacing: 0) {
            columnHeader(columns)
            palette.divider.color.frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if groupByCompany {
                        ForEach(groups(of: rows, peopleById: peopleById), id: \.group.id) { entry in
                            Text("\(entry.group.label) · \(entry.rows.count)")
                                .uiFont(.system(size: 11, weight: .semibold))
                                .foregroundStyle(palette.secondary.color)
                                .padding(.horizontal, 10)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(entry.rows) { row in
                                rowView(row, person: peopleById[row.id], columns: columns, order: order, selected: selected)
                            }
                        }
                    } else {
                        ForEach(rows) { row in
                            rowView(row, person: peopleById[row.id], columns: columns, order: order, selected: selected)
                        }
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tableWidth = $0 }
        // Our own focus ring (the system one ignores the palette), hidden while the
        // focus is in a row's company field.
        .overlay {
            Rectangle()
                .strokeBorder(palette.primary.color.opacity(0.6), lineWidth: 2)
                .opacity(tableFocused && !editingCompany ? 1 : 0)
                .allowsHitTesting(false)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($tableFocused)
        .onKeyPress(.upArrow) { moveSelection(by: -1, order: order) }
        .onKeyPress(.downArrow) { moveSelection(by: 1, order: order) }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard !selection.isEmpty else { return .ignored }
            requestForget(selectedPeople)
            return .handled
        }
        .onKeyPress(characters: ["a"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            selection = Set(order)
            return .handled
        }
    }

    private func columnHeader(_ columns: VoiceLibraryColumns) -> some View {
        HStack(spacing: VoiceLibraryColumns.spacing) {
            headerButton(.name).frame(maxWidth: .infinity, alignment: .leading)
            headerButton(.company).frame(width: columns.companyWidth, alignment: .leading)
            if columns.showsVoiceprints {
                headerButton(.voiceprints).frame(width: VoiceLibraryColumns.voiceprints, alignment: .leading)
            }
            if columns.showsDates {
                headerButton(.firstHeard).frame(width: VoiceLibraryColumns.firstHeard, alignment: .leading)
                headerButton(.lastHeard).frame(width: VoiceLibraryColumns.lastHeard, alignment: .leading)
            }
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

    private func rowView(_ row: VoiceLibraryRow, person: KnownPerson?, columns: VoiceLibraryColumns,
                         order: [String], selected: [KnownPerson]) -> some View {
        let isSelected = selection.contains(row.id)
        return VoiceLibraryTableRow(
            row: row,
            isSelected: isSelected,
            columns: columns,
            onClick: { click(row, order: order) },
            onSelect: { selection = [row.id]; anchorId = row.id },
            onRename: { if let person { actions.rename(person) } },
            onSetCompany: person.map { person in { setCompany(person, $0) } },
            onCompanyFocus: { editingCompany = $0 }
        ) {
            contextMenu(for: isSelected ? selected : person.map { [$0] } ?? [])
        }
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
            Button("Forget voice", role: .destructive) { requestForget([person]) }
        } else if people.count > 1 {
            Button("Merge \(people.count) people\u{2026}") { requestMerge(people) }
            Divider()
            Button("Forget \(people.count) voices", role: .destructive) { requestForget(people) }
        }
    }

    // MARK: - Actions

    private var actions: VoiceLibraryActions {
        VoiceLibraryActions(
            rename: { person in renameText = person.name; renaming = person },
            mergeInto: { person in mergeSource = person },
            merge: { sources, survivor in
                pendingMerge = MergeRequest(sources: sources, survivor: survivor)
                confirmingMerge = true
            },
            forget: { people in requestForget(people) },
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
        pendingMerge = MergeRequest(sources: people, survivor: survivor)
        confirmingMerge = true
    }

    private func requestForget(_ people: [KnownPerson]) {
        guard !people.isEmpty else { return }
        forgetTargets = people
        confirmingForget = true
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
            Text("Rename Voice").uiFont(.headline).foregroundStyle(palette.heading.color)
            TextField("Name", text: $renameText).settingsTextField().frame(width: 260)
            HStack {
                Spacer()
                Button("Cancel") { renaming = nil }
                    .buttonStyle(.settingsSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commitRename(person) }
                    .buttonStyle(.settingsPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .background(palette.canvas.color)
    }

    @ViewBuilder
    private func mergeSheet(_ source: KnownPerson) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge \u{201C}\(source.name)\u{201D} into\u{2026}").uiFont(.headline).foregroundStyle(palette.heading.color)
            Text("All of \(source.name)\u{2019}s voiceprints move into the person you pick, and \u{201C}\(source.name)\u{201D} is removed.")
                .uiFont(.system(size: 11.5)).foregroundStyle(palette.secondary.color).fixedSize(horizontal: false, vertical: true)
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
                            HStack {
                                Text(target.name)
                                Spacer()
                                Text(VoiceLibraryDisplay.sampleSummary(target)).foregroundStyle(palette.secondary.color)
                            }
                        }
                        .buttonStyle(.settingsSecondary)
                    }
                }
            }
            .frame(maxHeight: 360)
            HStack {
                Spacer()
                Button("Cancel") { mergeSource = nil }
                    .buttonStyle(.settingsSecondary)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
        .background(palette.canvas.color)
    }

    // MARK: - Mutations

    private func commitRename(_ person: KnownPerson) {
        let newName = renameText
        renaming = nil
        Task {
            let outcome = await context.voiceLibraryStore.rename(id: person.id, to: newName)
            if case let .collision(existingId) = outcome {
                collision = NameCollision(source: person, existingId: existingId,
                                          name: newName.trimmingCharacters(in: .whitespacesAndNewlines))
                showingCollision = true
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

/// The table's columns for its measured width. Name keeps a usable width: the date
/// columns go first, then the voiceprints column, and Company narrows once the dates
/// are gone.
private struct VoiceLibraryColumns {
    static let company: CGFloat = 160
    static let compactCompany: CGFloat = 120
    static let voiceprints: CGFloat = 90
    static let firstHeard: CGFloat = 100
    static let lastHeard: CGFloat = 110
    static let spacing: CGFloat = 12
    /// 16 pt each side: the header's padding, or a row's 10 pt inside the list's 6 pt.
    static let insets: CGFloat = 32
    static let nameMin: CGFloat = 140
    static let compactNameMin: CGFloat = 120

    /// Widest set: every column with Name at `nameMin` (680 pt).
    static let datesMinWidth = nameMin + company + voiceprints + firstHeard + lastHeard + 4 * spacing + insets
    /// Without dates: Name, a narrower Company, and Voiceprints (386 pt).
    static let voiceprintsMinWidth = compactNameMin + compactCompany + voiceprints + 2 * spacing + insets

    let showsDates: Bool
    let showsVoiceprints: Bool

    init(tableWidth: CGFloat) {
        showsDates = tableWidth >= Self.datesMinWidth
        showsVoiceprints = tableWidth >= Self.voiceprintsMinWidth
    }

    var companyWidth: CGFloat { showsDates ? Self.company : Self.compactCompany }
}

/// One table row. Its own view so hovering repaints only this row, not the table
/// and inspector.
private struct VoiceLibraryTableRow<MenuItems: View>: View {
    let row: VoiceLibraryRow
    let isSelected: Bool
    let columns: VoiceLibraryColumns
    let onClick: () -> Void
    let onSelect: () -> Void
    let onRename: () -> Void
    /// Nil when the row has no stored person (no company field).
    let onSetCompany: ((String) -> Void)?
    let onCompanyFocus: (Bool) -> Void
    @ViewBuilder let menuItems: () -> MenuItems
    @State private var hovered = false
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        HStack(spacing: VoiceLibraryColumns.spacing) {
            HStack(spacing: 8) {
                VoiceLibraryAvatar(name: row.name, colorKey: row.company ?? row.name)
                Text(row.name)
                    .uiFont(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(palette.heading.color)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
            // For VoiceOver the name cell stands for the row; the company field stays
            // its own editable element.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { onSelect() }
            .accessibilityAction(named: "Rename") { onRename() }

            Group {
                if let onSetCompany {
                    VoiceLibraryCompanyField(company: row.company, onFocusChange: onCompanyFocus, commit: onSetCompany)
                        .id(row.id)
                        .uiFont(.system(size: 12))
                        .foregroundStyle(palette.text.color)
                        .accessibilityLabel("Company")
                }
            }
            .frame(width: columns.companyWidth, alignment: .leading)

            Group {
                if columns.showsVoiceprints {
                    HStack(spacing: 6) {
                        VoiceLibraryStrengthMeter(strength: row.strength)
                        Text("\(row.voiceprintCount)").uiFont(.system(size: 12).monospacedDigit())
                    }
                    .frame(width: VoiceLibraryColumns.voiceprints, alignment: .leading)
                }
                if columns.showsDates {
                    Text(row.firstHeard?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                        .frame(width: VoiceLibraryColumns.firstHeard, alignment: .leading)
                    Text(row.lastHeard?.formatted(.relative(presentation: .named)) ?? "—")
                        .frame(width: VoiceLibraryColumns.lastHeard, alignment: .leading)
                }
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
                .fill(isSelected ? palette.selected.color : hovered ? palette.divider.color.opacity(0.35) : .clear)
                .contentShape(Rectangle())
                .onTapGesture(perform: onClick)
        }
        .onHover { hovered = $0 }
        .contextMenu { menuItems() }
        .accessibilityElement(children: .contain)
    }
}
