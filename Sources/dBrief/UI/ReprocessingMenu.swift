import SwiftUI

/// Shared entry point for history rows and the transcript viewer toolbar.
struct ReprocessingMenu: View {
    let recording: Recording
    var hasTranscript = true
    @Environment(RecordingManager.self) private var manager
    @State private var showCalendarLink = false
    @Environment(AppSettings.self) private var settings
    @State private var selectedOperation: ReprocessingOperation?
    @State private var canRestore = false
    @State private var isRestoring = false
    @State private var error: String?

    private var locked: Bool { manager.isReprocessing(recording.finalizedAudioURL ?? recording.fileURL) }

    private struct AvailabilityKey: Equatable {
        let revision: Int
        let calendarRevision: Int
        let locked: Bool
        let recovered: Bool
    }

    var body: some View {
        Menu {
            if settings.effectiveCalendarSource != .disabled {
                Button("Link calendar meeting…") { showCalendarLink = true }
                Divider()
            }
            Button(hasTranscript ? "Retranscribe…" : "Transcribe…") { selectedOperation = .transcribe }
            Button("Re-run AI analysis…") { selectedOperation = .analysis }.disabled(!hasTranscript)
            Button("Detect speakers again…") { selectedOperation = .speakers }.disabled(!hasTranscript)
            Divider()
            Button("Restore previous results") { restore() }.disabled(!canRestore)
        } label: {
            Label(hasTranscript ? "Reprocess" : "Transcribe", systemImage: "arrow.trianglehead.2.clockwise")
        }
        .disabled(locked || isRestoring || !manager.reprocessingRecoveryReady)
        .help(locked ? "This recording has a pending attempt in Queue & Recovery" : "Reprocess this recording")
        .task(id: AvailabilityKey(revision: manager.reprocessingResultsRevision, calendarRevision: manager.calendarContextRevision, locked: locked, recovered: manager.reprocessingRecoveryReady)) {
            guard manager.reprocessingRecoveryReady, !locked else { canRestore = false; return }
            let available = await manager.canRestoreReprocessingResults(for: recording)
            guard !Task.isCancelled else { return }
            canRestore = available
            if let metadata = try? await RecordingMetadataStore.shared.load(audioURL: recording.finalizedAudioURL ?? recording.fileURL),
               !Task.isCancelled, !locked {
                recording.calendarEvent = metadata.calendarEvent
                recording.meetingTitleDraft = metadata.meetingTitle
                recording.generatedTitle = metadata.generatedTitle
                recording.participants = PersonName.displayList(metadata.participants + (metadata.calendarEvent == nil ? metadata.calendarAttendees : []))
            }
        }
        .sheet(isPresented: Binding(get: { selectedOperation != nil }, set: { if !$0 { selectedOperation = nil } })) {
            if let operation = selectedOperation { ReprocessingSheet(recording: recording, operation: operation) }
        }
        .sheet(isPresented: $showCalendarLink) {
            CalendarLinkSheet(recording: recording, hasTranscript: hasTranscript)
        }
        .alert("Could not restore results", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func restore() {
        isRestoring = true
        Task {
            defer { isRestoring = false }
            do { try await manager.restoreReprocessingResults(for: recording) }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// Reconciliation must finish before any saved result set is presented.
struct ReprocessingRecoveryView: View {
    @Environment(RecordingManager.self) private var manager
    @Environment(AppState.self) private var appState
    @State private var retrying = false

    var body: some View {
        VStack(spacing: 12) {
            if appState.lastError == nil || retrying {
                ProgressView("Checking saved recording results…")
            } else {
                Label("Recording recovery needs attention", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(appState.lastError ?? "Saved results are not ready to open.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).textSelection(.enabled)
            }
            Button("Retry Recovery") {
                retrying = true
                Task {
                    await manager.recoverReprocessingAttempts()
                    retrying = false
                }
            }
            .disabled(retrying)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
