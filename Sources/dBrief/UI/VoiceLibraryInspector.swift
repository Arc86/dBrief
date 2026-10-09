import SwiftUI

/// What the voice-library inspector asks its owner to do. Every mutation goes through
/// `SettingsVoiceLibraryTab`, which owns the store, confirmations, and reloads.
struct VoiceLibraryActions {
    var rename: (KnownPerson) -> Void
    var mergeInto: (KnownPerson) -> Void
    var merge: (_ sources: [KnownPerson], _ survivor: KnownPerson) -> Void
    var forget: ([KnownPerson]) -> Void
    var removeVoiceprint: (KnownPerson, Date) -> Void
    var setCompany: (KnownPerson, String) -> Void
}

/// Right-hand pane of the voice library: one person's details, or bulk merge/forget
/// for a multi-selection.
struct VoiceLibraryInspector: View {
    let selected: [KnownPerson]
    let libraryCount: Int
    let voiceprintCount: Int
    let actions: VoiceLibraryActions
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch selected.count {
                case 0: placeholder
                case 1: PersonDetail(person: selected[0], canMerge: libraryCount > 1, actions: actions)
                default: SelectionDetail(people: selected, actions: actions)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlayScrollers()
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("^[\(libraryCount) person](inflect: true) · ^[\(voiceprintCount) voiceprint](inflect: true)")
                .uiFont(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(palette.heading.color)
            Text("Select a person to see their voiceprints. Select several to merge or forget them together.")
                .uiFont(.system(size: 11.5))
                .foregroundStyle(palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - One person

private struct PersonDetail: View {
    let person: KnownPerson
    let canMerge: Bool
    let actions: VoiceLibraryActions
    @Environment(\.viewerPalette) private var palette

    private var strength: VoiceLibraryDisplay.Strength { VoiceLibraryDisplay.strength(person) }

    var body: some View {
        HStack(spacing: 10) {
            VoiceLibraryAvatar(name: person.name, colorKey: person.company ?? person.name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .uiFont(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                    .textSelection(.enabled)
                Text(heardCaption)
                    .uiFont(.system(size: 11))
                    .foregroundStyle(palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        VStack(alignment: .leading, spacing: 5) {
            label("Company")
            // A fresh field per person: a draft typed for one person must never be
            // saved onto the next one when the selection changes mid-edit.
            VoiceLibraryCompanyField(company: person.company, bordered: true) { actions.setCompany(person, $0) }
                .id(person.id)
        }

        VStack(alignment: .leading, spacing: 5) {
            HStack {
                label("Recognition")
                Spacer()
                VoiceLibraryStrengthMeter(strength: strength)
                Text(strength.label)
                    .uiFont(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(palette.heading.color)
            }
            Text(strengthHint)
                .uiFont(.system(size: 11))
                .foregroundStyle(palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 0) {
            label("Voiceprints (\(person.voiceprints.count))").padding(.bottom, 4)
            // Index identity: `capturedAt` can repeat within a second, and the list is a
            // fixed-order snapshot until the next reload.
            ForEach(Array(person.voiceprints.sorted { $0.capturedAt > $1.capturedAt }.enumerated()), id: \.offset) { _, print in
                HStack {
                    Text(print.capturedAt.formatted(date: .abbreviated, time: .shortened))
                        .uiFont(.system(size: 11.5))
                        .foregroundStyle(palette.heading.color)
                    Spacer()
                    Button {
                        actions.removeVoiceprint(person, print.capturedAt)
                    } label: {
                        Image(systemName: "trash").font(.system(size: 10.5))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(palette.secondary.color)
                    .help("Forget this voiceprint")
                    .accessibilityLabel("Forget voiceprint from \(print.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                }
                .padding(.vertical, 5)
                .overlay(alignment: .bottom) { palette.divider.color.frame(height: 1) }
            }
        }

        HStack(spacing: 8) {
            Button("Rename\u{2026}") { actions.rename(person) }
                .buttonStyle(.settingsSecondary)
            if canMerge {
                Button("Merge into\u{2026}") { actions.mergeInto(person) }
                    .buttonStyle(.settingsSecondary)
            }
        }
        Button("Forget voice", role: .destructive) { actions.forget([person]) }
            .buttonStyle(.settingsDanger)
    }

    private var heardCaption: String {
        guard let first = VoiceLibraryDisplay.firstHeard(person),
              let last = VoiceLibraryDisplay.lastSeen(person) else { return "No voiceprints" }
        return "First heard \(first.formatted(date: .abbreviated, time: .omitted)) · last heard \(last.formatted(.relative(presentation: .named)))"
    }

    private var strengthHint: String {
        switch strength {
        case .weak: "One voiceprint. Name them in another recording to recognise them more reliably."
        case .good: "Recognised well. One more voiceprint makes it more reliable."
        case .strong: "Enough voiceprints to recognise them reliably."
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .uiFont(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(palette.heading.color)
    }
}

// MARK: - Several people

private struct SelectionDetail: View {
    let people: [KnownPerson]
    let actions: VoiceLibraryActions
    @State private var survivorId: String?
    /// Pairwise voiceprint comparison is costly, so it runs once per selection.
    @State private var similarity: Float?
    @Environment(\.viewerPalette) private var palette

    private var survivor: KnownPerson? {
        people.first { $0.id == survivorId } ?? VoiceLibraryDisplay.mergeSurvivor(people)
    }

    var body: some View {
        let survivor = survivor
        VStack(alignment: .leading, spacing: 14) {
            content(survivor: survivor)
        }
        // Keyed on ids and print counts: a removed or added voiceprint recomputes it.
        .task(id: people.map { "\($0.id)#\($0.voiceprints.count)" }) {
            similarity = VoiceLibraryDisplay.selectionSimilarity(people)
        }
    }

    @ViewBuilder
    private func content(survivor: KnownPerson?) -> some View {
        Text("\(people.count) people selected")
            .uiFont(.system(size: 13, weight: .semibold))
            .foregroundStyle(palette.heading.color)

        HStack(spacing: -6) {
            ForEach(people.prefix(6)) { person in
                VoiceLibraryAvatar(name: person.name, colorKey: person.company ?? person.name, size: 28)
                    .overlay { Circle().strokeBorder(palette.surface.color, lineWidth: 2) }
            }
        }
        Text(people.map(\.name).joined(separator: ", "))
            .uiFont(.system(size: 11.5))
            .foregroundStyle(palette.secondary.color)
            .fixedSize(horizontal: false, vertical: true)

        if let similarity {
            let percent = Int((max(0, similarity) * 100).rounded())
            if similarity >= VoiceLibraryDisplay.likelySamePersonThreshold {
                Label("Voices \(percent)% alike. Probably the same person.", systemImage: "person.2.wave.2")
                    .uiFont(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(palette.accentText.color)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.selected.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Text("Voices \(percent)% alike.")
                    .uiFont(.system(size: 11.5))
                    .foregroundStyle(palette.secondary.color)
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("Merge into")
                .uiFont(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(palette.heading.color)
            Picker("Merge into", selection: Binding(get: { survivor?.id }, set: { survivorId = $0 })) {
                ForEach(people) { person in
                    Text("\(person.name) (\(person.voiceprints.count))").tag(Optional(person.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Button("Merge \(people.count) people") {
                if let survivor { actions.merge(people, survivor) }
            }
            .buttonStyle(.settingsPrimary)
            .disabled(survivor == nil)
        }

        Button("Forget \(people.count) voices", role: .destructive) { actions.forget(people) }
            .buttonStyle(.settingsDanger)
    }
}

// MARK: - Shared pieces

/// Initials on a colour picked from the person's company (or name), so a company's
/// people share a colour.
struct VoiceLibraryAvatar: View {
    let name: String
    let colorKey: String
    var size: CGFloat = 22

    private static let hues: [Double] = [0.61, 0.75, 0.47, 0.08, 0.92, 0.36, 0.55, 0.02]

    var body: some View {
        let hue = Self.hues[VoiceLibraryDisplay.avatarIndex(for: colorKey.lowercased(), count: Self.hues.count)]
        Text(VoiceLibraryDisplay.initials(name))
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hue: hue, saturation: 0.5, brightness: 0.72), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Three bars: one per strength step.
struct VoiceLibraryStrengthMeter: View {
    let strength: VoiceLibraryDisplay.Strength
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...3, id: \.self) { step in
                RoundedRectangle(cornerRadius: 1)
                    .fill(step <= strength.rawValue ? palette.accentText.color : palette.divider.color)
                    .frame(width: 4, height: 10)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Recognition \(strength.label)")
    }
}

/// Company text field that saves on Return, on losing focus, or when it goes away
/// (selection change), and follows the stored value whenever it isn't being edited.
/// Give it an `.id` per person so its draft and `commit` always belong together.
struct VoiceLibraryCompanyField: View {
    let company: String?
    var bordered = false
    var onFocusChange: ((Bool) -> Void)? = nil
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if bordered {
                TextField("Add company", text: $draft).settingsTextField()
            } else {
                TextField("Add company", text: $draft).textFieldStyle(.plain)
            }
        }
        .focused($focused)
        .onSubmit(save)
        .onAppear { draft = company ?? "" }
        .onDisappear {
            if focused { onFocusChange?(false) }
            save()
        }
        .onChange(of: focused) { _, isFocused in
            onFocusChange?(isFocused)
            if !isFocused { save() }
        }
        .onChange(of: company) { _, newValue in if !focused { draft = newValue ?? "" } }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (company ?? "") else { return }
        commit(trimmed)
    }
}
