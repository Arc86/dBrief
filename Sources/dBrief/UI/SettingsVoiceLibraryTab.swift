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
            Text("\u{201C}\(deleteTarget?.name ?? "")\u{201D} and all its voiceprints will be removed. This cannot be undone.")
        }
        .alert("Name already exists", isPresented: Binding(get: { collision != nil }, set: { if !$0 { collision = nil } })) {
            Button("Merge", role: .destructive) {
                if let c = collision { Task { await context.voiceLibraryStore.merge(sourceId: c.source.id, into: c.existingId); await reload() } }
            }
            Button("Cancel", role: .cancel) { collision = nil }
        } message: {
            Text("Another person is already named \u{201C}\(collision?.name ?? "")\u{201D}. Merge \u{201C}\(collision?.source.name ?? "")\u{201D} into them?")
        }
        .sheet(item: $renaming) { person in renameSheet(person) }
        .sheet(item: $mergeSource) { person in mergeSheet(person) }
    }

    private var privacySection: some View {
        SettingsSection(title: "Voice Library") {
            Text("dBrief learns each speaker\u{2019}s voice so it can recognize them in future recordings. Voiceprints are stored only on this Mac, are never uploaded, and can be forgotten at any time.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        SettingsSection(title: "Known People") {
            Text("No voices saved yet. A voice is added when you name a speaker in a transcript, or with \u{201C}Save voice to library\u{201D} from the speaker menu.")
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
                    Button("Rename\u{2026}") { renameText = person.name; renaming = person }
                    if library.people.count > 1 {
                        Button("Merge into\u{2026}") { mergeSource = person }
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
                // Index-based identity: capturedAt is not guaranteed unique
                // (two prints can land in the same second), and the list is a
                // fixed-order snapshot, so the offset is a stable, collision-free key.
                ForEach(Array(person.voiceprints.enumerated()), id: \.offset) { _, vp in
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
            return "\(summary) \u{00B7} last heard \(seen.formatted(.relative(presentation: .named)))"
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
            Text("Merge \u{201C}\(source.name)\u{201D} into\u{2026}").font(.headline)
            Text("All of \(source.name)\u{2019}s voiceprints move into the person you pick, and \u{201C}\(source.name)\u{201D} is removed.")
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
