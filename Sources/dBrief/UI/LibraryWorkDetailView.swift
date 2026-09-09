import SwiftUI
import AppKit

/// Selecting a cached row only shows context. Processing and recovery require
/// an explicit action, whose durable identity is revalidated by the manager.
struct LibraryWorkDetailView: View {
    let item: LibraryWorkItem
    let disabled: Bool
    let action: @MainActor () async throws -> Void
    @State private var actionTask: Task<Void, Never>?
    @State private var error: String?

    private var actionTitle: String {
        switch item.target {
        case .queue: "Process Now"
        case .recovery: "Resume Processing"
        case .delivery: "Review Deliveries"
        case .capture: "Recover Audio"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(item.title).font(.title).textSelection(.enabled)
                LabeledContent("Status", value: item.status)
                LabeledContent("Date", value: item.date.formatted(date: .abbreviated, time: .shortened))
                if !item.associatedApp.isEmpty {
                    LabeledContent("Application", value: item.associatedApp)
                }
                if let audio = item.audioURL {
                    Text(audio.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
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
                    .buttonStyle(.borderedProminent)
                    .disabled(disabled || actionTask != nil)
                    if actionTask != nil { ProgressView().controlSize(.small) }
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
