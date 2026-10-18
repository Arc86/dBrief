import SwiftUI

enum ReprocessingMenuPresentationStyle: Equatable {
    case sheet
    case window
}

/// Shared entry point for history rows and the transcript viewer toolbar.
struct ReprocessingMenu: View {
    let recording: Recording
    var hasTranscript = true
    var label: String? = nil
    var presentationStyle: ReprocessingMenuPresentationStyle = .sheet
    /// Icon-over-label tile, for the menu panel's action grid.
    var stacksLabel = false
    @Environment(RecordingManager.self) private var manager
    @Environment(AppState.self) private var appState
    @State private var showCalendarLink = false
    @Environment(AppSettings.self) private var settings
    @State private var selectedOperation: ReprocessingOperation?
    /// An unfinished run the sheet discards when Start is pressed.
    @State private var discardingRunID: UUID?
    @State private var canRestore = false
    @State private var isRestoring = false
    @State private var error: String?

    private var audio: URL { recording.finalizedAudioURL ?? recording.fileURL }
    private var block: RecordingBlock? { manager.eligibility(for: audio, .reprocess) }
    private var locked: Bool { block != nil }

    private struct AvailabilityKey: Equatable {
        let revision: Int
        let calendarRevision: Int
        let locked: Bool
        let recovered: Bool
    }

    var body: some View {
        Menu {
            if let block, !block.resolutions.isEmpty {
                // Explain the block and offer the way out instead of failing on Start.
                Text(block.message)
                Divider()
                ForEach(block.resolutions, id: \.self) { resolution in
                    switch resolution {
                    case .showInQueue(let id):
                        Button("Show in Queue & Recovery") { appState.showInQueue(id) }
                    case .discardRunAndRetranscribe(let id):
                        Button(hasTranscript ? "Discard Run and Retranscribe…" : "Discard Run and Transcribe…") {
                            present(.transcribe, discardingRun: id)
                        }
                    }
                }
            } else {
                operations
            }
        } label: {
            let title = label ?? (hasTranscript ? String(localized: "Reprocess") : String(localized: "Transcribe"))
            if stacksLabel {
                RecordingListTileLabel(title: title, systemImage: "arrow.trianglehead.2.clockwise")
            } else {
                Label(title, systemImage: "arrow.trianglehead.2.clockwise")
            }
        }
        .disabled(isRestoring || (block.map { $0.resolutions.isEmpty } ?? false))
        .help(block?.message ?? "Reprocess this recording")
        .task(id: AvailabilityKey(revision: manager.reprocessingResultsRevision, calendarRevision: manager.calendarContextRevision, locked: locked, recovered: manager.reprocessingRecoveryReady)) {
            guard manager.reprocessingRecoveryReady, !locked else { canRestore = false; return }
            let available = await manager.canRestoreReprocessingResults(for: recording)
            guard !Task.isCancelled else { return }
            canRestore = available
            if let metadata = try? await RecordingMetadataStore.shared.load(audioURL: recording.finalizedAudioURL ?? recording.fileURL),
               !Task.isCancelled, !locked {
                recording.calendarEvent = metadata.calendarEvent
                recording.meetingTitleDraft = RecordingFinalizer.readableMeetingTitle(metadata.meetingTitle)
                recording.generatedTitle = metadata.generatedTitle
                recording.participants = PersonName.displayList(metadata.participants + (metadata.calendarEvent == nil ? metadata.calendarAttendees : []))
            }
        }
        .sheet(isPresented: Binding(get: { selectedOperation != nil }, set: { if !$0 { selectedOperation = nil } })) {
            if let operation = selectedOperation {
                ReprocessingSheet(recording: recording, operation: operation, discardingRunID: discardingRunID)
            }
        }
        .sheet(isPresented: $showCalendarLink) {
            CalendarLinkSheet(recording: recording, hasTranscript: hasTranscript)
        }
        .alert("Could not restore results", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    @ViewBuilder
    private var operations: some View {
        if settings.effectiveCalendarSource != .disabled {
            Button("Link Calendar Meeting…") { presentCalendarLink() }
                .disabled(manager.eligibility(for: audio, .linkCalendar) != nil)
            Divider()
        }
        Button(hasTranscript ? "Retranscribe…" : "Transcribe…") { present(.transcribe) }
        Button("Re-run AI Analysis…") { present(.analysis) }.disabled(!hasTranscript)
        Button("Detect Speakers Again…") { present(.speakers) }.disabled(!hasTranscript)
        Divider()
        Button("Restore Previous Results") { restore() }.disabled(!canRestore)
    }

    private func present(_ operation: ReprocessingOperation, discardingRun runID: UUID? = nil) {
        if presentationStyle == .window {
            RecordingActionWindowController.shared.showReprocessing(
                recording: recording,
                operation: operation,
                discardingRunID: runID
            )
        } else {
            discardingRunID = runID
            selectedOperation = operation
        }
    }

    private func presentCalendarLink() {
        if presentationStyle == .window {
            RecordingActionWindowController.shared.showCalendarLink(
                recording: recording,
                hasTranscript: hasTranscript
            )
        } else {
            showCalendarLink = true
        }
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
    @State private var retrying = false

    var body: some View {
        VStack(spacing: 12) {
            if manager.reprocessingRecoveryError == nil || retrying {
                ProgressView("Checking saved recording results…")
            } else {
                Label("Recording recovery needs attention", systemImage: "exclamationmark.triangle")
                    .uiFont(.headline)
                Text(manager.reprocessingRecoveryError ?? "Saved results are not ready to open.")
                    .uiFont(.callout).foregroundStyle(.secondary)
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
