import SwiftUI
import AppKit

/// Two-pane transcript browser: a sidebar listing every recording and a detail
/// pane showing the selected recording's transcript (or chat). Mirrors the
/// spin-off project's `MainWindowView` layout.
struct TranscriptBrowserView: View {
    @Environment(AppContext.self) private var context
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.calmAppearance) private var calm

    @State private var searchText = ""

    /// Whether the meeting-list sidebar is shown. Persisted so the choice
    /// survives relaunch.
    @AppStorage("transcriptSidebarOpen") private var sidebarOpen = true

    /// Whether the "Earlier" group is collapsed. Persisted across relaunches.
    @AppStorage("transcriptSidebarEarlierCollapsed") private var earlierCollapsed = false

    @State private var items: [RecordingBrowserItem] = []
    @State private var selection: URL?
    /// Stable `Recording` for the current selection. Built once per selection
    /// (not per render) so the detail view's identity and state — including its
    /// chat session — survive while chatting or playing back.
    @State private var detailRecording: Recording?

    private var selectedItem: RecordingBrowserItem? {
        guard let selection else { return nil }
        return items.first { $0.url == selection }
    }

    /// The in-progress recording (recording or processing), pinned at the top of
    /// the sidebar so it can be viewed live. `nil` when idle.
    private var liveRecording: Recording? {
        guard appState.recordingState != .idle else { return nil }
        return appState.currentRecording
    }

    var body: some View {
        // Native collapsible + resizable sidebar (system component) hosting the
        // redesigned meeting list. The neon ambient lives on the detail side; the
        // sidebar uses the standard vibrant sidebar material (the navigation glass
        // layer). `sidebarOpen` maps to the split view's column visibility so the
        // native sidebar toggle + the persisted open/closed state stay in sync.
        NavigationSplitView(columnVisibility: Binding(
            get: { sidebarOpen ? .all : .detailOnly },
            set: { newValue in sidebarOpen = (newValue != .detailOnly) }
        )) {
            sidebar
                .scrollContentBackground(.hidden)
                .navigationSplitViewColumnWidth(min: 220, ideal: 256, max: 360)
        } detail: {
            mainPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { TranscriptDesignTokens.ambientBackground(scheme: colorScheme, calm: calm) }
        }
        .navigationTitle("dBrief")
        .frame(minWidth: 760, minHeight: 480)
        .toolbar {
            // Refresh + Settings sit at the leading edge, right next to the native
            // sidebar-collapse toggle.
            ToolbarItemGroup(placement: .navigation) {
                Button { reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")

                Button { openWindow(id: "settings") } label: {
                    Image(systemName: "gearshape")
                }
                .help("Open Settings (⌘,)")
            }
        }
        .onAppear {
            reload()
            applyPendingSelection()
            applyPendingLiveSelection()
            rebuildDetailRecording()
        }
        .onChange(of: selection) { _, _ in
            rebuildDetailRecording()
        }
        .onChange(of: appState.pendingTranscriptSelectionURL) { _, _ in
            applyPendingSelection()
        }
        .onChange(of: appState.pendingLiveTranscriptSelection) { _, _ in
            applyPendingLiveSelection()
        }
        .onChange(of: appState.recordingState) { _, newState in
            // Reload once a recording finishes so it appears as a normal entry.
            if newState == .idle { reload() }
            rebuildDetailRecording()
        }
    }

    // MARK: - Shell panes

    @ViewBuilder
    private var mainPane: some View {
        if let recording = detailRecording {
            TranscriptDetailView(
                recording: recording,
                onDeleted: { handleDeleted(recording.fileURL) }
            )
            .id(recording.fileURL)
        } else {
            ContentUnavailableView(
                "Select a Recording",
                systemImage: "text.bubble",
                description: Text("Choose a recording to view its transcript."))
        }
    }

    // MARK: - Sidebar

    /// Items matching the search box (by title), unfiltered when empty.
    private var filteredItems: [RecordingBrowserItem] {
        guard !searchText.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    private var thisWeekItems: [RecordingBrowserItem] {
        let cal = Calendar.current
        return filteredItems.filter { cal.isDate($0.date, equalTo: Date(), toGranularity: .weekOfYear) }
    }

    private var earlierItems: [RecordingBrowserItem] {
        let cal = Calendar.current
        return filteredItems.filter { !cal.isDate($0.date, equalTo: Date(), toGranularity: .weekOfYear) }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 10)

            if items.isEmpty && liveRecording == nil {
                Spacer()
                ContentUnavailableView(
                    "No Recordings",
                    systemImage: "waveform.slash",
                    description: Text("Recordings you capture will appear here."))
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if let live = liveRecording {
                            sectionLabel("In Progress")
                            LiveSidebarRow(
                                recording: live,
                                recordingState: appState.recordingState,
                                isSelected: selection == live.fileURL,
                                onTap: { selection = live.fileURL })
                        }
                        if !thisWeekItems.isEmpty {
                            sectionLabel("This week", count: thisWeekItems.count)
                            ForEach(thisWeekItems) { row(for: $0) }
                        }
                        if !earlierItems.isEmpty {
                            sectionLabel("Earlier", count: earlierItems.count,
                                         collapsed: earlierCollapsed) {
                                withAnimation(.easeInOut(duration: 0.18)) { earlierCollapsed.toggle() }
                            }
                            if !earlierCollapsed {
                                ForEach(earlierItems) { row(for: $0) }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .overlayScrollers()
                }
            }

            recordButton
                .padding(12)
        }
    }

    private func row(for item: RecordingBrowserItem) -> some View {
        SidebarRecordingRow(
            item: item,
            isSelected: selection == item.url,
            onTap: { selection = item.url })
    }

    /// Section header for the meeting list. Passing `collapsed`/`onToggle` makes it
    /// a tappable, collapsible header with a chevron (used by "Earlier").
    private func sectionLabel(_ text: String,
                              count: Int? = nil,
                              collapsed: Bool? = nil,
                              onToggle: (() -> Void)? = nil) -> some View {
        let content = HStack(spacing: 7) {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .bold).monospaced())
                .tracking(1.2)
                .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: colorScheme).opacity(0.55))
            if let count {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(TranscriptDesignTokens.chipFill(scheme: colorScheme)))
            }
            Spacer(minLength: 4)
            if let collapsed {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())

        return Group {
            if let onToggle {
                Button(action: onToggle) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(TranscriptDesignTokens.secondaryText(scheme: colorScheme))
            TextField("Search meetings", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(TranscriptDesignTokens.chipFill(scheme: colorScheme))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(TranscriptDesignTokens.chipBorder(scheme: colorScheme), lineWidth: 1))
        }
    }

    private var recordButton: some View {
        Button {
            appState.lastError = nil
            Task { try? await recordingManager.startRecording() }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text("Record meeting")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(TranscriptDesignTokens.brandFill(calm: calm), in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: calm ? .clear : Color(hex: "8b4dff").opacity(0.5), radius: calm ? 0 : 14, x: 0, y: calm ? 0 : 8)
        }
        .buttonStyle(.plain)
        .disabled(!appState.isIdle)
        .opacity(appState.isIdle ? 1 : 0.5)
        .help(appState.isIdle ? "Start a new recording" : "Already recording")
    }

    // MARK: - Helpers

    private func reload() {
        // Scan the recordings folder + decode metadata sidecars off the main
        // actor; the previously-loaded `items` stay visible until the new list
        // arrives (no flash to empty). Runs on appear and when a recording
        // finishes, so it must never block the UI.
        let folder = appSettings.effectiveRecordingFolderURL
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                RecordingBrowserStore.load(in: folder)
            }.value
            items = loaded
            if let selection, !items.contains(where: { $0.url == selection }) {
                self.selection = nil
            }
        }
    }

    private func rebuildDetailRecording() {
        // Selecting the pinned live entry shows the live `currentRecording` directly.
        if let live = liveRecording, selection == live.fileURL {
            if detailRecording?.fileURL != live.fileURL { detailRecording = live }
            return
        }
        if let item = selectedItem {
            if detailRecording?.fileURL != item.url {
                detailRecording = makeRecording(from: item)
            }
        } else {
            detailRecording = nil
        }
    }

    private func applyPendingSelection() {
        guard let pending = appState.pendingTranscriptSelectionURL else { return }
        if !items.contains(where: { $0.url == pending }) { reload() }
        selection = pending
        appState.pendingTranscriptSelectionURL = nil
    }

    private func applyPendingLiveSelection() {
        guard appState.pendingLiveTranscriptSelection else { return }
        if let live = liveRecording { selection = live.fileURL }
        appState.pendingLiveTranscriptSelection = false
    }

    private func handleDeleted(_ url: URL) {
        items.removeAll { $0.url == url }
        if selection == url { selection = nil }
        if detailRecording?.fileURL == url { detailRecording = nil }
    }

    private func makeRecording(from item: RecordingBrowserItem) -> Recording {
        let recording = Recording(
            date: item.date,
            fileURL: item.url,
            duration: item.duration,
            fileSize: item.size,
            meetingTitleDraft: item.title,
            finalizedAudioURL: item.url
        )
        // Carry the persisted AI title so the detail view's navigation title
        // reflects it after post-processing (not the stale filename). See #71.
        recording.generatedTitle = item.generatedTitle
        return recording
    }
}

/// `23 Jun` short date used in the sidebar captions.
private let sidebarDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "d MMM"
    return f
}()

private let sidebarStatusGreen = Color(hex: "28c840")

/// Selectable meeting row matching the redesign: title + mono caption, a gradient
/// fill + coral→violet bar when selected, a hover tint otherwise.
private struct SidebarRecordingRow: View {
    let item: RecordingBrowserItem
    let isSelected: Bool
    let onTap: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.calmAppearance) private var calm
    @State private var hovering = false

    private var doneColor: Color {
        scheme == .dark ? Color(hex: "54e6ff") : Color.secondary
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected
                        ? TranscriptDesignTokens.bodyText(scheme: scheme)
                        : TranscriptDesignTokens.bodyText(scheme: scheme).opacity(0.85))
                    .lineLimit(1)
                caption
            }
            .padding(.vertical, 10)
            .padding(.leading, isSelected ? 14 : 12)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { background }
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(TranscriptDesignTokens.accentBarFill(calm: calm))
                        .frame(width: 3)
                        .padding(.vertical, 10)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var caption: some View {
        HStack(spacing: 7) {
            Text(captionText)
            if item.statusText == "Done" {
                if isSelected {
                    Circle().fill(Color.secondary.opacity(0.5)).frame(width: 3, height: 3)
                    Text("Done").foregroundStyle(doneColor)
                } else {
                    Circle().fill(sidebarStatusGreen).frame(width: 5, height: 5)
                }
            }
        }
        .font(.system(size: 11).monospaced())
        .foregroundStyle(TranscriptDesignTokens.secondaryText(scheme: scheme))
    }

    private var captionText: String {
        let date = sidebarDateFormatter.string(from: item.date)
        return item.formattedDuration.isEmpty ? date : "\(date) · \(item.formattedDuration)"
    }

    @ViewBuilder
    private var background: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 10)
                .fill(TranscriptDesignTokens.sidebarActiveFill(scheme: scheme, calm: calm))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(TranscriptDesignTokens.sidebarActiveBorder(scheme: scheme), lineWidth: 1))
        } else if hovering {
            RoundedRectangle(cornerRadius: 10)
                .fill(TranscriptDesignTokens.sidebarHoverFill(scheme: scheme))
        }
    }
}

/// Pinned in-progress row — pulsing red/orange dot plus "Recording…/Processing…".
private struct LiveSidebarRow: View {
    let recording: Recording
    let recordingState: AppState.RecordingState
    let isSelected: Bool
    let onTap: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.calmAppearance) private var calm
    @State private var hovering = false
    @State private var pulse = false

    private var statusText: String {
        recordingState == .processing ? "Processing…" : "Recording…"
    }
    private var dotColor: Color {
        recordingState == .processing ? .orange : .red
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                Text(recording.generatedTitle ?? recording.meetingTitleDraft)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: scheme))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(dotColor).frame(width: 6, height: 6)
                        .opacity(pulse ? 1 : 0.4)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                    Text(statusText)
                }
                .font(.system(size: 11).monospaced())
                .foregroundStyle(TranscriptDesignTokens.secondaryText(scheme: scheme))
            }
            .padding(.vertical, 10)
            .padding(.leading, isSelected ? 14 : 12)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(TranscriptDesignTokens.sidebarActiveFill(scheme: scheme, calm: calm))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(TranscriptDesignTokens.sidebarActiveBorder(scheme: scheme), lineWidth: 1))
                } else if hovering {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(TranscriptDesignTokens.sidebarHoverFill(scheme: scheme))
                }
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(TranscriptDesignTokens.accentBarFill(calm: calm))
                        .frame(width: 3)
                        .padding(.vertical, 10)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onAppear { pulse = true }
    }
}
