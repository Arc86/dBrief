import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var appSettings
    @State private var destination = SettingsDestination(page: .general)
    @State private var profileToEdit: UUID?
    @State private var searchText = ""
    @State private var selectedSearchID: String?
    @State private var revealAdvanced = false
    @State private var searchRequest: SettingsSearchRequest?
    @State private var navigationRevision = UUID()
    @FocusState private var focus: Focus?
    private enum Focus: Hashable { case search, results }
    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var results: [SettingsSearchEntry] { SettingsSearch.results(for: searchText) }

    private func navigate(to target: SettingsDestination) {
        destination = target
        searchRequest = nil
        revealAdvanced = false
        navigationRevision = UUID()
    }

    private func openResult(_ result: SettingsSearchEntry) {
        destination = result.destination
        revealAdvanced = result.requiresAdvanced
        searchRequest = result.destination.section.map { SettingsSearchRequest(section: $0) }
        navigationRevision = UUID()
        focus = nil
    }

    private func clearSearch() {
        searchText = ""
        selectedSearchID = nil
        revealAdvanced = false
        searchRequest = nil
        let visible = destination.page.visibleSelection(advanced: appSettings.powerUserMode)
        if visible != destination.page { navigate(to: SettingsDestination(page: visible)) }
        focus = .search
    }

    private func openSelectedResult() {
        if let result = results.first(where: { $0.id == selectedSearchID }) ?? results.first { openResult(result) }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            TextField("Search settings", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search settings")
                .focused($focus, equals: .search)
                .onSubmit { openSelectedResult() }
                .onExitCommand { clearSearch() }
                .onKeyPress(.downArrow) {
                    guard !results.isEmpty else { return .ignored }
                    selectedSearchID = results.first?.id
                    focus = .results
                    return .handled
                }
            if !searchText.isEmpty {
                Button(action: clearSearch) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear settings search")
            }
        }
        .padding(10)
    }

    private var searchResults: some View {
        List(selection: $selectedSearchID) {
            if results.isEmpty {
                Text("No settings found. Try another word.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(results) { result in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.title)
                        Text(result.destination.page.title + (result.requiresAdvanced ? " · Advanced" : ""))
                            .font(.caption).foregroundStyle(.secondary)
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
        .focused($focus, equals: .results)
        .onKeyPress(.return) { openSelectedResult(); return .handled }
        .onExitCommand { clearSearch() }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                searchField
                if isSearching {
                    searchResults
                        .id(searchText)
                } else {
                List(selection: Binding<SettingsPage?>(
                    get: { destination.page },
                    set: { if let page = $0 { navigate(to: SettingsDestination(page: page)) } }
                )) {
                    ForEach(SettingsGroup.allCases) { group in
                        Section(group.title) {
                            ForEach(group.pages.filter { SettingsPage.visiblePages(advanced: appSettings.powerUserMode).contains($0) }) { page in
                                Label {
                                    Text(page.title).font(.system(size: 14))
                                } icon: {
                                    Image(systemName: page.icon)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 24, height: 24)
                                        .background(page.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                                .padding(.vertical, 3)
                                .tag(page)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                }
                Divider()
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("dBrief v\(version)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
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
                        case .voiceLibrary: SettingsVoiceLibraryTab()
                        case .profiles:     SettingsProfilesTab(selectedProfileId: $profileToEdit)
                        case .benchmark:    SettingsBenchmarkTab()
                        case .about:        AboutTab()
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                    .id(navigationRevision)
                    .environment(\.settingsSearchRevealAdvanced, revealAdvanced)
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
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            Button { focus = .search } label: { Label("Search settings", systemImage: "magnifyingglass") }
                .keyboardShortcut("f", modifiers: .command)
        }
        .onChange(of: searchText) { _, _ in
            selectedSearchID = results.first?.id
            if !isSearching {
                revealAdvanced = false
                searchRequest = nil
                let visiblePage = destination.page.visibleSelection(advanced: appSettings.powerUserMode)
                if visiblePage != destination.page { navigate(to: SettingsDestination(page: visiblePage)) }
            }
        }
        .onChange(of: appSettings.powerUserMode) { _, enabled in
            let visiblePage = destination.page.visibleSelection(advanced: enabled)
            if visiblePage != destination.page && !revealAdvanced { navigate(to: SettingsDestination(page: visiblePage)) }
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
