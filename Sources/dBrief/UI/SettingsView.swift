import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.viewerPalette) private var palette
    @State private var destination: SettingsDestination
    @State private var profileToEdit: UUID?
    @State private var searchText = ""
    @State private var selectedSearchID: String?
    @State private var searchRequest: SettingsSearchRequest?
    @State private var navigationRevision = UUID()
    @State private var permissions = SettingsPermissionStatus()
    /// Starts open every time, so a remembered collapsed sidebar can't hide navigation.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @FocusState private var focus: Focus?
    @FocusState private var searchFocused: Bool
    private enum Focus: Hashable { case results }
    @Environment(\.viewerMode) private var viewerMode
    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var results: [SettingsSearchEntry] { SettingsSearch.results(for: searchText) }

    init(page: SettingsPage = .general) {
        _destination = State(initialValue: SettingsDestination(page: page))
    }

    /// The Signature workspace colour, shared with the transcript viewer.
    private var canvasColor: Color { palette.canvas.color }

    private func editProfile(_ id: UUID) {
        profileToEdit = id
        navigate(to: SettingsDestination(page: .profiles))
    }

    private func navigate(to target: SettingsDestination) {
        destination = target
        searchRequest = nil
        navigationRevision = UUID()
    }

    private func openResult(_ result: SettingsSearchEntry) {
        destination = result.destination
        searchRequest = result.destination.section.map { SettingsSearchRequest(section: $0) }
        navigationRevision = UUID()
        focus = nil
        searchFocused = false
    }

    private func clearSearch() {
        searchText = ""
        selectedSearchID = nil
        searchRequest = nil
        searchFocused = true
    }

    private func openSelectedResult() {
        if let result = results.first(where: { $0.id == selectedSearchID }) ?? results.first { openResult(result) }
    }

    private var searchResults: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if results.isEmpty {
                    Text("No settings found. Try another word.")
                        .uiFont(.system(size: 12))
                        .foregroundStyle(palette.secondary.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                } else {
                    ForEach(results) { result in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.title)
                                .uiFont(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(palette.heading.color)
                            Text(result.destination.page.title + (result.requiresAdvanced ? " · Advanced" : ""))
                                .uiFont(.system(size: 11))
                                .foregroundStyle(palette.secondary.color)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .settingsSelectableRow(isSelected: selectedSearchID == result.id) {
                            selectedSearchID = result.id
                            openResult(result)
                        }
                        .accessibilityAction { openResult(result) }
                    }
                }
            }
            .padding(.horizontal, 8)
            .overlayScrollers()
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .results)
        .onKeyPress(.upArrow) { moveSearchSelection(by: -1) }
        .onKeyPress(.downArrow) { moveSearchSelection(by: 1) }
        .onKeyPress(.return) { openSelectedResult(); return .handled }
        .onExitCommand { clearSearch() }
    }

    private func moveSearchSelection(by step: Int) -> KeyPress.Result {
        guard let id = SettingsListNavigation.step(step, in: results.map(\.id), from: selectedSearchID) else { return .ignored }
        selectedSearchID = id
        return .handled
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SettingsSidebar(
                selection: destination.page,
                badges: [.permissions: permissions.attentionCount(settings: appSettings)],
                searchText: $searchText,
                searchFocused: $searchFocused,
                onSelect: { navigate(to: SettingsDestination(page: $0)) },
                onSubmitSearch: openSelectedResult,
                onSearchDown: {
                    guard !results.isEmpty else { return }
                    selectedSearchID = results.first?.id
                    focus = .results
                },
                onClearSearch: clearSearch
            ) {
                searchResults.id(searchText)
            }
            .frame(minWidth: 220, idealWidth: 236)
            .navigationSplitViewColumnWidth(min: 220, ideal: 236, max: 320)
            // Replaced by `SettingsSidebarToggle`: the system button draws a glass
            // circle over the custom sidebar background.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            // Keep long grouped forms inside the window's viewport. Without
            // this boundary, the header + form stack can report the form's full
            // content height to NavigationSplitView and push both columns offscreen.
            GeometryReader { geometry in
                let tab = destination.page
                ScrollViewReader { scrollProxy in
                    VStack(spacing: 0) {
                        switch tab {
                        case .general:      SettingsGeneralTab()
                        case .appearance:   SettingsAppearanceTab()
                        case .storage:      SettingsStorageTab(editProfile: editProfile)
                        case .afterRecording:
                            SettingsAfterRecordingTab { id in
                                profileToEdit = id
                                navigate(to: SettingsDestination(section: .profileAutomation))
                            }
                        case .permissions:  SettingsPermissionsTab()
                        case .recording:    SettingsRecordingTab()
                        case .transcription: SettingsTranscriptionTab(editProfile: editProfile)
                        case .ai:           SettingsAITab(editProfile: editProfile)
                        case .spokenVoice:  SettingsSpokenVoiceTab()
                        case .vocabulary:     SettingsVocabularyTab(editProfile: editProfile)
                        case .watchedFolders: SettingsWatchedFoldersTab()
                        case .integrations: SettingsIntegrationsTab(editProfile: editProfile)
                        case .meetings:     SettingsMeetingsTab(editProfile: editProfile)
                        case .speakers:     SettingsSpeakersTab()
                        case .profiles:     SettingsProfilesTab(selectedProfileId: $profileToEdit)
                        case .benchmark:    SettingsBenchmarkTab()
                        case .about:        AboutTab()
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                    .id(navigationRevision)
                    .environment(\.settingsSearchRequest, searchRequest)
                    .task(id: navigationRevision) {
                        if let section = destination.section {
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            // Leave room below the translucent toolbar so the
                            // destination heading stays fully readable.
                            scrollProxy.scrollTo(section, anchor: UnitPoint(x: 0, y: 0.08))
                        }
                    }
                }
            }
            .background(canvasColor.ignoresSafeArea())
        }
        .navigationSplitViewStyle(.balanced)
        .modifier(SettingsSidebarToggle(visibility: $columnVisibility))
        .environment(\.viewerPalette, palette.withSoftDividers(mode: viewerMode))
        // ⌘F focuses the sidebar search field; no toolbar button duplicates it.
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .applyWindowAppearanceWhenAvailable(canvasColor)
        .onChange(of: searchText) { _, _ in
            selectedSearchID = results.first?.id
            if !isSearching { searchRequest = nil }
        }
        .environment(permissions)
        .onAppear {
            permissions.refresh()
            if !appSettings.showDockIcon {
                NSApp.setActivationPolicy(.regular)
            }
        }
        .onDisappear {
            if !appSettings.showDockIcon {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func applyWindowAppearanceWhenAvailable(_ color: Color) -> some View {
        if #available(macOS 15.0, *) {
            // The sidebar already says "Settings"; drop the duplicate window title.
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .toolbar(removing: .title)
                .containerBackground(color, for: .window)
        } else {
            self
        }
    }
}

/// Sidebar show/hide button without the toolbar's shared glass background.
private struct SettingsSidebarToggle: ViewModifier {
    @Binding var visibility: NavigationSplitViewVisibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var button: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                visibility = visibility == .detailOnly ? .all : .detailOnly
            }
        } label: {
            Image(systemName: "sidebar.left")
        }
        .help(visibility == .detailOnly ? "Show sidebar" : "Hide sidebar")
        .accessibilityLabel(visibility == .detailOnly ? "Show sidebar" : "Hide sidebar")
    }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.toolbar {
                ToolbarItem(placement: .navigation) { button }
                    .sharedBackgroundVisibility(.hidden)
            }
        } else {
            content.toolbar {
                ToolbarItem(placement: .navigation) { button }
            }
        }
    }
}
