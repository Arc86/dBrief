import SwiftUI
import AppKit

/// Two-pane transcript browser: a sidebar listing every recording and a detail
/// pane showing the selected recording's transcript (or chat). Mirrors the
/// spin-off project's `MainWindowView` layout.
struct TranscriptBrowserView: View {
    @Environment(AppContext.self) private var context
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.openWindow) private var openWindow

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
        NavigationSplitView {
            sidebar
                .navigationTitle("dBrief")
                .frame(minWidth: 240)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            openWindow(id: "settings")
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .help("Open Settings (⌘,)")

                        Button {
                            reload()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh")
                    }
                }
        } detail: {
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
        .frame(minWidth: 760, minHeight: 480)
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

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        if items.isEmpty && liveRecording == nil {
            ContentUnavailableView(
                "No Recordings",
                systemImage: "waveform.slash",
                description: Text("Recordings you capture will appear here."))
        } else {
            List(selection: $selection) {
                if let live = liveRecording {
                    Section("In Progress") {
                        LiveBrowserRow(recording: live, recordingState: appState.recordingState)
                            .tag(live.fileURL)
                    }
                }
                if !items.isEmpty {
                    Section(liveRecording == nil ? "" : "Recordings") {
                        ForEach(items) { item in
                            RecordingBrowserRow(item: item)
                                .tag(item.url)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func reload() {
        items = RecordingBrowserStore.load(in: appSettings.effectiveRecordingFolderURL)
        if let selection, !items.contains(where: { $0.url == selection }) {
            self.selection = nil
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
        Recording(
            fileURL: item.url,
            duration: item.duration,
            fileSize: item.size,
            meetingTitleDraft: item.title,
            finalizedAudioURL: item.url
        )
    }
}

/// Pinned sidebar row for the in-progress recording — a pulsing status dot plus
/// "Recording…" / "Processing…" caption.
private struct LiveBrowserRow: View {
    let recording: Recording
    let recordingState: AppState.RecordingState

    private var statusText: String {
        recordingState == .processing ? "Processing…" : "Recording…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(recording.generatedTitle ?? recording.meetingTitleDraft)
                .font(.body)
                .lineLimit(1)
            HStack(spacing: 6) {
                Circle()
                    .fill(recordingState == .processing ? Color.orange : Color.red)
                    .frame(width: 7, height: 7)
                Text(statusText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Sidebar row: title plus a `date · duration · status` caption (dB2 style).
private struct RecordingBrowserRow: View {
    let item: RecordingBrowserItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
                .font(.body)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(item.date, style: .date)
                if !item.formattedDuration.isEmpty {
                    Text("·")
                    Text(item.formattedDuration)
                }
                if !item.statusText.isEmpty {
                    Text("·")
                    Text(item.statusText)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
