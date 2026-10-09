import SwiftUI

/// Shared sidebar composition for the recording library. Results and all service
/// operations remain owned by TranscriptBrowserView and arrive through closures.
struct ViewerLibrarySidebar<Results: View>: View {
    @Binding private var searchText: String
    @Binding private var selectedView: LibrarySmartView
    @Binding private var statusFilter: LibraryRecordingStatus?

    let isLoading: Bool
    let isRefreshing: Bool
    let error: String?
    let emptyMessage: String?
    let isRecordEnabled: Bool
    let onRecord: () -> Void
    let onRefresh: () -> Void
    let onRebuildSearchIndex: () -> Void
    let onSettings: () -> Void
    /// The selected row, kept in view as the selection moves.
    let selectedRowID: AnyHashable?
    /// ↑/↓ while the list has focus: -1 or +1 rows.
    let onMove: (Int) -> Void
    private let results: (ViewerSidebarStatusFilterMenu) -> Results

    @Environment(\.viewerPalette) private var palette
    @Environment(\.uiTypography) private var typography
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    init(
        searchText: Binding<String>,
        selectedView: Binding<LibrarySmartView>,
        statusFilter: Binding<LibraryRecordingStatus?>,
        isLoading: Bool,
        isRefreshing: Bool,
        error: String?,
        emptyMessage: String?,
        isRecordEnabled: Bool,
        onRecord: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onRebuildSearchIndex: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        selectedRowID: AnyHashable? = nil,
        onMove: @escaping (Int) -> Void = { _ in },
        @ViewBuilder results: @escaping (ViewerSidebarStatusFilterMenu) -> Results
    ) {
        self._searchText = searchText
        self._selectedView = selectedView
        self._statusFilter = statusFilter
        self.isLoading = isLoading
        self.isRefreshing = isRefreshing
        self.error = error
        self.emptyMessage = emptyMessage
        self.isRecordEnabled = isRecordEnabled
        self.onRecord = onRecord
        self.onRefresh = onRefresh
        self.onRebuildSearchIndex = onRebuildSearchIndex
        self.onSettings = onSettings
        self.selectedRowID = selectedRowID
        self.onMove = onMove
        self.results = results
    }

    private static var smartViewOrder: [LibrarySmartView] { [
        .all, .unfinishedActions, .recentlyProcessed, .failedJobs, .queuedInterrupted, .peopleThisMonth,
    ] }

    var body: some View {
        VStack(spacing: 0) {
            brandMark
                .padding(.leading, 24)
                .padding(.trailing, 18)
                .padding(.top, 14)
                .padding(.bottom, 15)

            searchField
                .padding(.leading, 24)
                .padding(.trailing, 18)

            smartViewNavigation
                .padding(.leading, 24)
                .padding(.trailing, 18)
                .padding(.top, 14)
                .padding(.bottom, 14)

            Rectangle()
                .fill(palette.divider.color)
                .frame(height: 1)
                .padding(.leading, 24)
                .padding(.trailing, 18)

            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let error {
                        errorNotice(error)
                    }
                    results(ViewerSidebarStatusFilterMenu(status: $statusFilter))
                    if isLoading, error == nil {
                        loadingNotice
                    } else if error == nil, let emptyMessage {
                        LibrarySidebarNote(text: emptyMessage)
                    }
                }
                .padding(.leading, 24)
                .padding(.trailing, 18)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlayScrollers()
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The list, not the search field, takes focus when the window opens,
            // so ↑/↓ move through recordings like a Finder or Mail list.
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onMoveCommand { direction in
                switch direction {
                case .up: onMove(-1)
                case .down: onMove(1)
                default: break
                }
            }
            .accessibilityLabel("Recordings")
            .onChange(of: selectedRowID) { _, id in
                // A click or arrow selects a row: keep it visible and keep the keys here.
                guard let id else { return }
                proxy.scrollTo(id)
                listFocused = true
            }
            }

            recordButton
                .padding(.leading, 24)
                .padding(.trailing, 18)
                .padding(.top, 9)

            utilities
                .padding(.leading, 24)
                .padding(.trailing, 18)
                .padding(.top, 7)
                .padding(.bottom, 11)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .defaultFocus($listFocused, true)
        .background {
            LinearGradient(
                colors: [palette.sidebarTop.color, palette.sidebarBottom.color],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private var brandMark: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(LinearGradient(
                    colors: palette.brandStops.map(\.color),
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .accessibilityHidden(true)
            Text("dBrief")
                .uiFont(.system(size: 21, weight: .semibold))
                .tracking(typography.readingFont == .openDyslexic ? 0 : -0.6)
                .foregroundStyle(palette.heading.color)
            Spacer(minLength: 0)
        }
        .frame(height: 32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("dBrief")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(palette.secondary.color)
                .accessibilityHidden(true)
            TextField("Search recordings…", text: $searchText)
                .textFieldStyle(.plain)
                .uiFont(.system(size: 13))
                .foregroundStyle(palette.text.color)
                .focused($searchFocused)
                .onExitCommand { searchText = ""; listFocused = true }
                .accessibilityLabel("Search recordings and transcripts")
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondary.color)
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, searchText.isEmpty ? 10 : 6)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.surface.color)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(searchFocused ? palette.primary.color : palette.divider.color,
                                      lineWidth: searchFocused ? 1.5 : 1)
                }
        }
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = true }
    }

    private var loadingNotice: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading recordings…")
                .uiFont(.system(size: 12))
                .foregroundStyle(palette.secondary.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var smartViewNavigation: some View {
        VStack(spacing: 3) {
            ForEach(Self.smartViewOrder, id: \.self) { view in
                let isSelected = selectedView == view
                Button {
                    selectedView = view
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: symbol(for: view))
                            .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                            .frame(width: 17)
                            .accessibilityHidden(true)
                        Text(view.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .uiFont(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? palette.accentText.color : palette.heading.color)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                }
                .buttonStyle(LibrarySidebarRowStyle(isSelected: isSelected))
                .accessibilityLabel(view.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("library-view-\(view.rawValue)")
            }
        }
    }

    private func symbol(for view: LibrarySmartView) -> String {
        switch view {
        case .all: "list.bullet"
        case .unfinishedActions: "checkmark.circle"
        case .recentlyProcessed: "clock.arrow.circlepath"
        case .failedJobs: "exclamationmark.triangle"
        case .queuedInterrupted: "tray.full"
        case .peopleThisMonth: "person.2"
        }
    }

    private func errorNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label {
                Text("Library unavailable").foregroundStyle(palette.heading.color)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .uiFont(.system(size: 12, weight: .semibold))
            Text(message)
                .uiFont(.system(size: 11))
                .foregroundStyle(palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry", action: onRefresh)
                .uiFont(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.accentText.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(palette.surface.color, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(palette.divider.color, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }

    private var recordButton: some View {
        Button(action: onRecord) {
            HStack(spacing: 9) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityHidden(true)
                Text("Record meeting")
                    .uiFont(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ViewerBrandButtonStyle(height: 40))
        .disabled(!isRecordEnabled)
        .opacity(isRecordEnabled ? 1 : 0.5)
        .help(isRecordEnabled ? "Start a new recording" : "Already recording")
        .accessibilityLabel("Record meeting")
        .accessibilityValue(isRecordEnabled ? "Ready" : "Already recording")
    }

    private var utilities: some View {
        HStack(spacing: 4) {
            SidebarUtilityButton(symbol: "arrow.clockwise", label: "Refresh recordings",
                                 isBusy: isRefreshing, action: onRefresh)
            SidebarUtilityMenu(symbol: "ellipsis", label: "Library options") {
                Button("Rebuild Search Index", systemImage: "arrow.clockwise", action: onRebuildSearchIndex)
                    .disabled(isRefreshing)
            }
            Spacer(minLength: 8)
            SidebarUtilityButton(symbol: "gearshape", label: "Open Settings", action: onSettings)
        }
    }
}

/// Reusable status filter control so the results header remains in the browser
/// while the complete sidebar can be rendered independently for visual review.
struct ViewerSidebarStatusFilterMenu: View {
    @Binding private var status: LibraryRecordingStatus?
    @Environment(\.viewerPalette) private var palette

    init(status: Binding<LibraryRecordingStatus?>) {
        self._status = status
    }

    var body: some View {
        Menu {
            Picker("Recording status", selection: $status) {
                Text("Any status").tag(nil as LibraryRecordingStatus?)
                ForEach(LibraryRecordingStatus.allCases, id: \.self) { value in
                    Text(value.title).tag(Optional(value))
                }
            }
        } label: {
            Image(systemName: status == nil
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(status == nil ? palette.secondary.color : palette.accentText.color)
                .frame(width: 30, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.button)
        .buttonStyle(.typographyBorderless)
        .menuIndicator(.hidden)
        .accessibilityLabel("Filter by recording status")
        .accessibilityValue(status?.title ?? "Any status")
        .help("Status: \(status?.title ?? "Any status")")
    }
}

private struct SidebarUtilityButton: View {
    let symbol: String
    let label: String
    var isBusy = false
    let action: () -> Void

    @Environment(\.viewerPalette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.secondary.color)
                    .opacity(isBusy ? 0 : 1)
                if isBusy { ProgressView().controlSize(.small) }
            }
            .frame(width: 30, height: 30)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .background(hovering && !isBusy ? palette.selected.color : .clear, in: RoundedRectangle(cornerRadius: 7))
        .onHover { hovering = $0 }
        .help(isBusy ? "Refreshing…" : label)
        .accessibilityLabel(label)
        .accessibilityValue(isBusy ? "In progress" : "")
    }
}

private struct SidebarUtilityMenu<Content: View>: View {
    let symbol: String
    let label: String
    @ViewBuilder let content: () -> Content

    @Environment(\.viewerPalette) private var palette
    @State private var hovering = false

    var body: some View {
        Menu { content() } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.secondary.color)
                .frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.button)
        .buttonStyle(.typographyBorderless)
        .menuIndicator(.hidden)
        .background(hovering ? palette.selected.color : .clear, in: RoundedRectangle(cornerRadius: 7))
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
