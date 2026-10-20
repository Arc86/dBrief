import SwiftUI
import AppKit

/// Selecting a cached row only shows context. Processing and recovery require
/// an explicit action, whose durable identity is revalidated by the manager.
struct LibraryWorkDetailView: View {
    let item: LibraryWorkItem
    /// Why the action can't start now; shown under the disabled button.
    let disabledReason: String?
    /// "Remove from List" / "Remove from Queue", as in the menu panel's Queue & Recovery.
    var remove: (@MainActor () async -> Void)? = nil
    var openRecording: (() -> Void)? = nil
    let action: @MainActor () async throws -> Void
    @State private var actionTask: Task<Void, Never>?
    @State private var error: String?

    private var actionTitle: String {
        switch item.target {
        case .queue: String(localized: "Process Now")
        case .recovery: String(localized: "Resume Processing")
        case .delivery: String(localized: "Review Deliveries")
        case .capture: String(localized: "Recover Audio")
        case .reprocess: String(localized: "Resume Reprocess")
        }
    }

    var body: some View {
        content.announcing(error, priority: .high)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(item.displayTitle).uiFont(.title).textSelection(.enabled)
                LabeledContent("Status", value: item.displayStatus)
                LabeledContent("Date", value: item.date.formatted(date: .abbreviated, time: .shortened))
                if !item.associatedApp.isEmpty {
                    LabeledContent("Application", value: item.associatedApp)
                }
                if let audio = item.audioURL {
                    Text(audio.path).uiFont(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([audio]) }
                }
                Text(item.target == .delivery
                     ? "Review saved delivery outcomes before choosing which destinations to retry."
                     : "Review this work, then continue when you are ready.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button(actionTitle) {
                        error = nil
                        actionTask = Task { @MainActor in
                            defer { actionTask = nil }
                            do { try await action() }
                            catch is CancellationError { }
                            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                        }
                    }
                    .buttonStyle(.typographyProminent)
                    .disabled(disabledReason != nil || actionTask != nil)
                    if let openRecording {
                        Button("Open Recording", action: openRecording)
                    }
                    if let remove {
                        Button(item.target == .queue ? "Remove from Queue"
                               : item.target == .reprocess ? "Discard Attempt" : "Remove from List") {
                            actionTask = Task { @MainActor in
                                defer { actionTask = nil }
                                await remove()
                            }
                        }
                        .disabled(actionTask != nil)
                        .help(item.target == .queue ? "Remove from the queue without deleting the recording"
                              : item.target == .reprocess ? "Discards this reprocess. The recording's current results stay."
                              : "Hides this run. The recording and its current results stay; the unfinished run can't be resumed afterwards.")
                    }
                    if actionTask != nil { ProgressView().controlSize(.small) }
                }
                if let disabledReason, actionTask == nil {
                    Text(disabledReason).uiFont(.callout).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear { actionTask?.cancel() }
    }
}
