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
        List(selection: $selectedSearchID) {
            if results.isEmpty {
                Text("No settings found. Try another word.")
                    .uiFont(.system(size: 12))
                    .foregroundStyle(palette.secondary.color)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .tag(result.id)
                    .onTapGesture { selectedSearchID = result.id; openResult(result) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { openResult(result) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .focused($focus, equals: .results)
        .onKeyPress(.return) { openSelectedResult(); return .handled }
        .onExitCommand { clearSearch() }
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(
                selection: destination.page,
                badges: [:],
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
            .navigationSplitViewColumnWidth(min: 220, ideal: 236, max: 320)
        } detail: {
            // Keep long grouped forms inside the window's viewport. Without
            // this boundary, the header + form stack can report the form's full
            // content height to NavigationSplitView and push both columns offscreen.
            GeometryReader { geometry in
                let tab = destination.page
                ScrollViewReader { scrollProxy in
                    VStack(spacing: 0) {
                        if tab.editsAppDefaults {
                            SettingsProfileScopeView(fields: tab.profileFields) { id in
                                profileToEdit = id
                                navigate(to: SettingsDestination(page: .profiles))
                            }
                            .id(tab)
                        }
                        switch tab {
                        case .general:      SettingsGeneralTab()
                        case .appearance:   SettingsAppearanceTab()
                        case .storage:      SettingsStorageTab()
                        case .afterRecording:
                            SettingsAfterRecordingTab { id in
                                profileToEdit = id
                                navigate(to: SettingsDestination(section: .profileAutomation))
                            }
                        case .permissions:  SettingsPermissionsTab()
                        case .recording:    SettingsRecordingTab()
                        case .transcription: SettingsTranscriptionTab()
                        case .ai:           SettingsAITab()
                        case .spokenVoice:  SettingsSpokenVoiceTab()
                        case .vocabulary:     SettingsVocabularyTab()
                        case .watchedFolders: SettingsWatchedFoldersTab()
                        case .integrations: SettingsIntegrationsTab()
                        case .meetings:     SettingsMeetingsTab()
                        case .speakers:     SettingsVoiceLibraryTab()
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
        .onAppear {
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
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .containerBackground(color, for: .window)
        } else {
            self
        }
    }
}
