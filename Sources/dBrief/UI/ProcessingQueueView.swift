import SwiftUI

/// Shares section, row, status, and action chrome with Recent Recordings.
struct ProcessingQueueView: View {
    @Environment(RecordingManager.self) private var manager
    @Environment(AppState.self) private var appState
    @Binding var expanded: Bool
    @State private var expandedItem: Item?

    private enum Item: Equatable {
        case queued(URL)
        case recovery(UUID)
        case reprocessing(UUID)
    }

    private var editing: Bool { manager.reprocessingAdmissionBusy || !manager.reprocessingRecoveryReady || manager.queueMutationInProgress || manager.queuePauseWriteInProgress || manager.queueEnqueueInProgress || manager.recoveryMaintenanceInProgress || manager.processingCancellationInProgress || manager.reviewingIntegrationDeliveries }
    private var hasPendingWork: Bool { !manager.pendingQueueItems.isEmpty || !manager.recoveryQueueEntries.isEmpty || !manager.reprocessingAttempts.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RecordingListSectionHeader(title: "Queue & Recovery", subtitle: RecordingListPresentation.queueSummary(
                pending: manager.pendingQueueItems.count + visibleReprocessing.filter { $0.status == .queued }.count, recovery: manager.recoveryQueueEntries.count + visibleReprocessing.filter { $0.status != .queued }.count,
                paused: manager.queuePaused, processing: appState.processingJob != nil,
                hasError: manager.queueLoadError != nil), expanded: $expanded) {
                if manager.queueLoadError != nil || !manager.recoveryQueueEntries.isEmpty || visibleReprocessing.contains(where: { $0.status != .queued }) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange).accessibilityLabel("Queue needs attention")
                }
                RecordingListIconButton(title: "Refresh queue and recovery", systemImage: "arrow.clockwise") {
                    Task { await manager.refreshWorkQueue() }
                }
                .disabled(editing)
            }

            if expanded {
                if !manager.reprocessingRecoveryReady { ReprocessingRecoveryView() }
                if let job = appState.processingJob {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform").foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(job.recording.meetingTitleDraft).font(.callout).lineLimit(1)
                            RecordingListStatus(title: "Processing", systemImage: "arrow.triangle.2.circlepath")
                        }
                        Spacer(minLength: 0)
                        RecordingListAction(title: "Stop", systemImage: "stop") {
                            Task { await manager.cancelProcessing() }
                        }
                        .disabled(editing)
                        .help("Stop processing; saved progress remains available for recovery")
                    }
                    .padding(6)
                }

                if !hasPendingWork && appState.processingJob == nil && manager.queueLoadError == nil {
                    RecordingListEmptyState(title: "No pending work", message: "Queue a recording for later to add it here.", systemImage: "tray")
                } else if hasPendingWork {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(manager.pendingQueueItems.enumerated()), id: \.element.audioURL) { index, entry in
                                queuedRow(index: index, audioURL: entry.audioURL, item: entry.item, available: entry.fileSize != nil)
                            }
                            ForEach(visibleReprocessing) { attempt in
                                reprocessingRow(attempt)
                            }
                            if !manager.recoveryQueueEntries.isEmpty {
                                if !manager.pendingQueueItems.isEmpty { Divider().padding(.vertical, 4) }
                                Text("Needs attention").font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary).padding(.horizontal, 6)
                                ForEach(manager.recoveryQueueEntries) { entry in
                                    recoveryRow(entry)
                                }
                            }
                        }
                    }
                    // MenuBarExtra sizes to minimum content height. A max-only
                    // frame lets this lazy scroll view collapse to zero, hiding
                    // recovery rows while the header still counts them. Match
                    // Recent Recordings' bounded, explicitly sized viewport.
                    .frame(height: 200)
                }

                if let error = manager.queueLoadError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                if hasPendingWork {
                    Text("Removing keeps the recording. Deferred items wait for Process Queue; automatic items may run first.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if expanded || !manager.pendingQueueItems.isEmpty {
                HStack {
                    Button(manager.queuePaused ? "Resume Automatic Queue" : "Pause Queue") {
                        Task {
                            if await manager.setQueuePaused(!manager.queuePaused), !manager.queuePaused {
                                await manager.drainQueueIfNeeded()
                                await manager.drainReprocessingQueue()
                            }
                        }
                    }
                    .help("Pause prevents the next job from starting; the current job can finish. This setting survives a restart.")
                    Spacer(minLength: 4)
                    if !manager.pendingQueueItems.isEmpty || visibleReprocessing.contains(where: { $0.status == .queued }) {
                        Button("Process Queue") { Task { await manager.startProcessingQueue() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(manager.queueLoadError != nil)
                    }
                }
                .disabled(editing)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .task { await manager.refreshWorkQueue() }
        .onChange(of: appState.processingJob?.id) { _, _ in Task { await manager.refreshWorkQueue() } }
        .onChange(of: appState.queuedCount) { _, _ in Task { await manager.refreshWorkQueue() } }
    }

    private var visibleReprocessing: [ReprocessingStore.Attempt] {
        manager.reprocessingAttempts.filter { $0.id != appState.processingJob?.reprocessingAttemptID }
    }

    private func reprocessingRow(_ attempt: ReprocessingStore.Attempt) -> some View {
        let key = Item.reprocessing(attempt.id)
        let request = try? JSONDecoder().decode(ReprocessingRequest.self, from: attempt.configuration)
        return RecordingListRow(title: request?.title ?? attempt.audioURL.deletingPathExtension().lastPathComponent,
            expanded: expandedItem == key, toggle: { expandedItem = expandedItem == key ? nil : key }) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
            } metadata: {
                Text("\(request?.options.operation.title ?? "Reprocessing") · \(attempt.status == .queued ? "Queued" : "Needs attention")")
                    .font(.caption).foregroundStyle(.secondary)
            } actions: {
                VStack(alignment: .leading, spacing: 6) {
                    if let message = attempt.message { Text(message).font(.caption).fixedSize(horizontal: false, vertical: true) }
                    HStack {
                        RecordingListAction(title: "Resume", systemImage: "play") {
                            Task { await manager.resumeReprocessing(attempt.id) }
                        }.disabled(appState.processingJob != nil || editing)
                        RecordingListAction(title: "Discard attempt", systemImage: "minus.circle") {
                            Task { await manager.discardReprocessing(attempt.id) }
                        }.disabled(editing)
                    }
                }
            }
    }

    private func queuedRow(index: Int, audioURL: URL, item: QueueItem, available: Bool) -> some View {
        let title = RecordingListPresentation.title(filenameStem: audioURL.deletingPathExtension().lastPathComponent)
        let key = Item.queued(audioURL)
        return RecordingListRow(title: title, expanded: expandedItem == key, toggle: {
            expandedItem = expandedItem == key ? nil : key
        }) {
            Text("\(index + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityLabel("Queue position \(index + 1)")
        } metadata: {
            HStack(spacing: 6) {
                RecordingListStatus(title: available ? "Queued" : "Audio unavailable",
                    systemImage: available ? "clock" : "exclamationmark.triangle", tint: .orange)
                if available { Text(item.autoQueued ? "· Automatic" : "· Deferred") }
            }
        } actions: {
            FlowLayout(spacing: 6) {
                RecordingListAction(title: "Process now", systemImage: "play") {
                    Task { await manager.drainQueueIfNeeded(preferredAudioURL: audioURL, expectedID: item.id) }
                }
                .disabled(!available || appState.processingJob != nil || manager.queueLoadError != nil)
                .help("Process this recording now, even if the queue is paused")
                RecordingListAction(title: "Move to first", systemImage: "arrow.up.to.line") {
                    Task { await manager.moveQueuedItem(audioURL, by: -index) }
                }
                .disabled(index == 0)
                RecordingListAction(title: "Move up", systemImage: "arrow.up") {
                    Task { await manager.moveQueuedItem(audioURL, by: -1) }
                }
                .disabled(index == 0)
                RecordingListAction(title: "Move down", systemImage: "arrow.down") {
                    Task { await manager.moveQueuedItem(audioURL, by: 1) }
                }
                .disabled(index == manager.pendingQueueItems.count - 1)
                RecordingListAction(title: "Remove", systemImage: "minus.circle") {
                    Task { await manager.removeQueuedItem(audioURL) }
                }
                .help("Remove from the queue without deleting the recording")
            }
            .disabled(editing)
        }
    }

    private func recoveryRow(_ entry: RecoveryQueueEntry) -> some View {
        let key = Item.recovery(entry.id)
        return RecordingListRow(title: entry.title, expanded: expandedItem == key, toggle: {
            expandedItem = expandedItem == key ? nil : key
        }) {
            Image(systemName: entry.isDelivery ? "paperplane" : "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } metadata: {
            Text(entry.status).lineLimit(1)
        } actions: {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.status + " · " + entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 6) {
                    RecordingListAction(title: entry.isDelivery ? "Integrations…" : "Resume",
                        systemImage: entry.isDelivery ? "paperplane" : "play") {
                        Task {
                            if entry.isDelivery, let url = entry.audioURL {
                                await manager.reviewIntegrationDeliveries(for: url, batchID: entry.id)
                            } else { await manager.resumeRecoveryItem(entry.id) }
                            await manager.refreshWorkQueue()
                        }
                    }
                    RecordingListAction(title: "Dismiss", systemImage: "minus.circle") {
                        Task { await manager.dismissRecoveryItem(entry.id) }
                    }
                    .help("Hide this recovery run; keep its recording and saved progress")
                }
                .disabled(editing || appState.processingJob != nil)
            }
        }
    }
}
