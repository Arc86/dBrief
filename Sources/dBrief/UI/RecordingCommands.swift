import AppKit
import SwiftUI
import WebKit

/// What the recording open in the library offers the menu bar and the Space key.
/// Published by `TranscriptDetailView`; a `nil` action means "not available now".
struct RecordingViewerActions {
    var mode: ViewerDocumentMode
    var availableModes: [ViewerDocumentMode]
    var selectMode: (ViewerDocumentMode) -> Void
    var copy: (() -> Void)?
    var isPlaying: Bool
    var togglePlayback: (() -> Void)?
    var assistantOpen: Bool
    var toggleAssistant: (() -> Void)?
    /// `nil` while the recording is locked by a pending reprocessing attempt.
    var reprocess: ((ReprocessingOperation) -> Void)?
    var hasTranscript: Bool
    var revealInFinder: (() -> Void)?
    var delete: (() -> Void)?
}

enum TextInputFocus {
    /// True while typing goes to an editable text view (field editors included)
    /// or the summary's web editor. SwiftUI key handlers run before these, so
    /// single-key shortcuts must step aside for them.
    @MainActor static var isActive: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let textView = responder as? NSTextView { return textView.isEditable }
        var view = responder as? NSView
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }
}

private struct RecordingViewerActionsKey: FocusedValueKey {
    typealias Value = RecordingViewerActions
}

extension FocusedValues {
    var recordingViewer: RecordingViewerActions? {
        get { self[RecordingViewerActionsKey.self] }
        set { self[RecordingViewerActionsKey.self] = newValue }
    }
}

/// View ▸ Summary…Meeting Insights (⌘1–⌘4) and the Recording menu.
struct RecordingCommands: Commands {
    @FocusedValue(\.recordingViewer) private var viewer

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            ForEach(Array(ViewerDocumentMode.allCases.enumerated()), id: \.element) { index, mode in
                Button(mode.displayName) { viewer?.selectMode(mode) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled(viewer?.availableModes.contains(mode) != true)
            }
            Divider()
        }

        CommandMenu("Recording") {
            // Space is handled by the library window, so typing a space never plays.
            Button(viewer?.isPlaying == true ? "Pause" : "Play") { viewer?.togglePlayback?() }
                .disabled(viewer?.togglePlayback == nil)
            Divider()
            Button("Copy \(viewer?.mode.displayName ?? "")") { viewer?.copy?() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(viewer?.copy == nil)
            Button(viewer?.assistantOpen == true ? "Hide dBrief AI" : "Ask dBrief AI") {
                viewer?.toggleAssistant?()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(viewer?.toggleAssistant == nil)
            Divider()
            Button(viewer?.hasTranscript == false ? "Transcribe…" : "Retranscribe…") {
                viewer?.reprocess?(.transcribe)
            }
            .disabled(viewer?.reprocess == nil)
            Button("Re-run AI Analysis…") { viewer?.reprocess?(.analysis) }
                .disabled(viewer?.reprocess == nil || viewer?.hasTranscript != true)
            Button("Detect Speakers Again…") { viewer?.reprocess?(.speakers) }
                .disabled(viewer?.reprocess == nil || viewer?.hasTranscript != true)
            Divider()
            Button("Show in Finder") { viewer?.revealInFinder?() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(viewer?.revealInFinder == nil)
            Divider()
            Button("Delete Recording…") {
                // ⌘⌫ keeps its text meaning (delete to line start) in a text field.
                if TextInputFocus.isActive {
                    (NSApp.keyWindow?.firstResponder as? NSTextView)?.deleteToBeginningOfLine(nil)
                } else {
                    viewer?.delete?()
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(viewer?.delete == nil)
        }
    }
}
