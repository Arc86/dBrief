import AppKit
import SwiftUI

/// The font menu shared by Settings, the viewer's Reading options and the Focus
/// Reader: the named fonts, then "Other Font…", which opens `FontFamilyBrowser`
/// over every installed family.
struct ReadingFontPicker: View {
    @Binding var selection: ViewerReadingFont?
    /// Label of a leading entry that clears the selection (the Focus Reader's
    /// "Same as the viewer"); nil offers no such entry.
    var inheritLabel: LocalizedStringKey?
    var includesSameAsInterface = false
    @State private var browsing = false

    private enum Choice: Hashable {
        case inherit
        case font(ViewerReadingFont)
        case other
    }

    var body: some View {
        Picker("Font", selection: choice) {
            if let inheritLabel {
                Text(inheritLabel).tag(Choice.inherit)
            }
            ForEach(ViewerFonts.choices(keeping: selection, includingSameAsInterface: includesSameAsInterface),
                    id: \.self) { font in
                Text(ViewerFonts.isAvailable(font) ? font.displayName : String(localized: "\(font.displayName) (Not Installed)"))
                    .tag(Choice.font(font))
            }
            Divider()
            Text("Other Font…").tag(Choice.other)
        }
        .sheet(isPresented: $browsing) {
            FontFamilyBrowser(current: selection?.familyName) { family in
                selection = ViewerReadingFont.forFamily(family)
            }
        }
    }

    /// "Other Font…" opens the browser and leaves the selection as it was.
    private var choice: Binding<Choice> {
        Binding(
            get: { selection.map(Choice.font) ?? .inherit },
            set: { choice in
                switch choice {
                case .inherit: selection = nil
                case .font(let font): selection = font
                case .other: browsing = true
                }
            })
    }
}

extension ReadingFontPicker {
    /// A menu that always has a font, without an inherit entry.
    init(selection: Binding<ViewerReadingFont>, includesSameAsInterface: Bool = false) {
        self.init(
            selection: Binding(get: { selection.wrappedValue },
                               set: { if let font = $0 { selection.wrappedValue = font } }),
            inheritLabel: nil,
            includesSameAsInterface: includesSameAsInterface)
    }
}

/// Every installed font family, searchable, each name drawn in its own font.
/// Return or a double-click uses the highlighted family; Esc cancels.
struct FontFamilyBrowser: View {
    let current: String?
    let onChoose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var families: [String] = []
    @State private var query = ""
    @State private var selected: String?
    @FocusState private var searchFocused: Bool

    private var filtered: [String] {
        query.isEmpty ? families : families.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a Font")
                .font(.headline)
            TextField("Search fonts", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onKeyPress(.downArrow) { moveSelection(by: 1) }
                .onKeyPress(.upArrow) { moveSelection(by: -1) }
            ScrollViewReader { proxy in
                List(filtered, id: \.self, selection: $selected) { family in
                    FontFamilyRow(family: family)
                }
                .contextMenu(forSelectionType: String.self, menu: { _ in }) { picked in
                    if let family = picked.first { choose(family) }
                }
                .overlay {
                    if filtered.isEmpty, !families.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
                .onChange(of: selected) { _, family in
                    if let family { proxy.scrollTo(family) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use Font") { if let selected { choose(selected) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 380, height: 460)
        .onChange(of: query) {
            if let selected, filtered.contains(selected) { return }
            selected = filtered.first
        }
        .task {
            families = ViewerFonts.installedFamilies()
            selected = current.flatMap { families.contains($0) ? $0 : nil }
            searchFocused = true
        }
    }

    private func moveSelection(by step: Int) -> KeyPress.Result {
        let list = filtered
        guard !list.isEmpty else { return .ignored }
        let index = selected.flatMap(list.firstIndex(of:)).map { $0 + step } ?? 0
        selected = list[min(max(index, 0), list.count - 1)]
        return .handled
    }

    private func choose(_ family: String) {
        onChoose(family)
        dismiss()
    }
}

/// A family name in its own font, or the system font when the family can't
/// draw its own name (symbol and non-Latin fonts).
private struct FontFamilyRow: View {
    let family: String

    var body: some View {
        Text(family)
            .font(Self.font(for: family))
            .lineLimit(1)
            .accessibilityLabel(family)
    }

    private static func font(for family: String) -> Font {
        guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 14),
              font.coveredCharacterSet.isSuperset(of: CharacterSet(charactersIn: family))
        else { return .system(size: 14) }
        return Font(font)
    }
}
