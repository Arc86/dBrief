import SwiftUI

enum SettingsSidebarKeys {
    static func handlesArrows(isSearching: Bool, searchFocused: Bool) -> Bool {
        !isSearching && !searchFocused
    }
}

/// Settings sidebar in the transcript-library style: brand header, search, grouped
/// pages with a flat `selected` fill, footer pages for Performance and About.
struct SettingsSidebar<Results: View>: View {
    let selection: SettingsPage
    let badges: [SettingsPage: Int]
    @Binding var searchText: String
    var searchFocused: FocusState<Bool>.Binding
    let onSelect: (SettingsPage) -> Void
    let onSubmitSearch: () -> Void
    let onSearchDown: () -> Void
    let onClearSearch: () -> Void
    @ViewBuilder var searchResults: Results
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                BrandBarsMark(height: 20)
                Text("Settings")
                    .uiFont(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            if isSearching {
                searchResults
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(SettingsGroup.allCases.filter { $0 != .footer }) { group in
                            Text(group.title)
                                .uiFont(.system(size: 11, weight: .semibold))
                                .foregroundStyle(palette.secondary.color)
                                .padding(.horizontal, 8)
                                .padding(.top, group == SettingsGroup.allCases.first ? 2 : 12)
                                .padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.pages) { page in row(page) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .overlayScrollers()
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            Spacer(minLength: 0)
            palette.divider.color.frame(height: 1)
            VStack(spacing: 1) {
                ForEach(SettingsGroup.footer.pages) { page in footerRow(page) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(
            LinearGradient(colors: [palette.sidebarTop.color, palette.sidebarBottom.color],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(by: -1) }
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
    }

    /// Arrow keys walk the pages only when they aren't meant for search: key presses
    /// bubble up from the search field and results list to this container.
    private func moveSelection(by offset: Int) -> KeyPress.Result {
        guard SettingsSidebarKeys.handlesArrows(isSearching: isSearching, searchFocused: searchFocused.wrappedValue) else {
            return .ignored
        }
        onSelect(SettingsPage.adjacent(to: selection, offset: offset))
        return .handled
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(palette.secondary.color)
            TextField("Search settings", text: $searchText)
                .textFieldStyle(.plain)
                .uiFont(.system(size: 12))
                .focused(searchFocused)
                .onSubmit(onSubmitSearch)
                .onExitCommand(perform: onClearSearch)
                .onKeyPress(.downArrow) { onSearchDown(); return .handled }
                .accessibilityLabel("Search settings")
            if !searchText.isEmpty {
                Button(action: onClearSearch) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.secondary.color)
                    .accessibilityLabel("Clear settings search")
            } else {
                Text("⌘F")
                    .uiFont(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(palette.secondary.color)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(palette.surface.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(searchFocused.wrappedValue ? palette.primary.color : palette.divider.color,
                              lineWidth: searchFocused.wrappedValue ? 1.5 : 1)
        }
    }

    private func row(_ page: SettingsPage) -> some View {
        let isSelected = page == selection
        return Button { onSelect(page) } label: {
            HStack(spacing: 9) {
                Image(systemName: page.icon)
                    .font(.system(size: 14))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(isSelected ? palette.accentText.color : palette.secondary.color)
                Text(page.title)
                    .uiFont(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? palette.accentText.color : palette.heading.color)
                Spacer(minLength: 0)
                if let count = badges[page], count > 0 {
                    Text("\(count)")
                        .uiFont(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(status.warning.color, in: Capsule())
                        .accessibilityLabel("\(count) need attention")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(LibrarySidebarRowStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func footerRow(_ page: SettingsPage) -> some View {
        let isSelected = page == selection
        return Button { onSelect(page) } label: {
            HStack(spacing: 8) {
                Image(systemName: page.icon).font(.system(size: 12))
                Text(page.title).uiFont(.system(size: 12, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
                if page == .about, let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("v\(version)").uiFont(.system(size: 10.5).monospaced())
                }
            }
            .foregroundStyle(isSelected ? palette.accentText.color : palette.secondary.color)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(LibrarySidebarRowStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
