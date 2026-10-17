import SwiftUI
import AppKit

/// One set of actions for a saved recording, used by the library row's and the menu
/// panel row's context menus. The panel tiles and the viewer use the same labels and
/// the same `RecordingManager.eligibility` rules.
struct RecordingContextMenu: View {
    let recording: Recording
    let hasTranscript: Bool
    let open: () -> Void
    var onDeleted: () -> Void = {}
    @Environment(RecordingManager.self) private var manager
    @Environment(AppState.self) private var appState

    private var url: URL { recording.finalizedAudioURL ?? recording.fileURL }
    private var title: String { recording.generatedTitle ?? recording.meetingTitleDraft }

    var body: some View {
        Button("Open") { open() }
        // Summary and action items, or the transcript when there is no analysis.
        Button("Copy Notes") {
            Task { if let text = await RecordingNotesText.load(for: url) { _ = await RecordingClipboard.copy(text, from: url) } }
        }
        .disabled(!hasTranscript)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Divider()
        ReprocessingMenu(recording: recording, hasTranscript: hasTranscript, presentationStyle: .window)
        Button("Integrations…") { Task { await manager.reviewIntegrationDeliveries(for: url) } }
            .disabled(appState.processingJob != nil || manager.reviewingIntegrationDeliveries)
        Divider()
        Button("Delete Recording…", role: .destructive) {
            Task {
                if await RecordingDeletion.confirmAndDelete(url, title: title, manager: manager, appState: appState) {
                    onDeleted()
                }
            }
        }
        .disabled(manager.eligibility(for: url, .delete) != nil)
    }
}

/// The delete confirmation and its outcome, shared by the menu panel and the library.
@MainActor enum RecordingDeletion {
    static let message = "This permanently deletes the recording, its transcript and notes in dBrief, and anything queued for it. Markdown notes exported elsewhere and content already sent to integrations are kept."

    static func confirmAndDelete(_ url: URL, title: String, manager: RecordingManager, appState: AppState) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(title)”?"
        alert.informativeText = message
        alert.addButton(withTitle: "Delete Recording")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            try await manager.deleteRecording(url)
            return true
        } catch let blocked as RecordingBlockedError {
            appState.post(.error, blocked.localizedDescription, source: .library)
        } catch {
            appState.post(.error, "Deletion could not finish. Some files may remain; check storage before retrying.",
                          source: .library, recordingURL: url)
        }
        return false
    }
}
