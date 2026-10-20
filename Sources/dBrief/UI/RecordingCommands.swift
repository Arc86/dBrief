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
    /// Opens the Focus Reader from the viewer, or leaves it from the reader.
    var focusReader: (() -> Void)? = nil
    /// +1 / −1 step of the Focus Reader's text size; nil elsewhere.
    var changeTextSize: ((Int) -> Void)? = nil
    /// Review and retry this recording's integration deliveries.
    var reviewIntegrations: (() -> Void)? = nil
    /// The speaker of the playing (or first) turn, so renaming and "This is me" work
    /// without reaching the speaker menu inside a transcript row.
    var currentSpeakerName: String? = nil
    var currentSpeakerIsMe: Bool = false
    var renameCurrentSpeaker: (() -> Void)? = nil
    var toggleCurrentSpeakerIsMe: (() -> Void)? = nil
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

/// Capture shortcuts, shared by the menu panel, the floating recording controls and
/// the Recording menu. ⌘P and ⌘. are left to Print and Cancel.
enum CaptureShortcut {
    static let pauseResume = KeyboardShortcut("p", modifiers: [.command, .option])
    static let stop = KeyboardShortcut(".", modifiers: [.command, .option])
}

/// View ▸ Summary…Meeting Insights (⌘1–⌘4) and the Recording menu.
struct RecordingCommands: Commands {
    let appState: AppState
    let recordingManager: RecordingManager
    @FocusedValue(\.recordingViewer) private var viewer

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            ForEach(Array(ViewerDocumentMode.allCases.enumerated()), id: \.element) { index, mode in
                Button(mode.displayName) { viewer?.selectMode(mode) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled(viewer?.availableModes.contains(mode) != true)
            }
            Button("Focus Reader") { viewer?.focusReader?() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(viewer?.focusReader == nil)
            Button("Larger Text") { viewer?.changeTextSize?(1) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(viewer?.changeTextSize == nil)
            Button("Smaller Text") { viewer?.changeTextSize?(-1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(viewer?.changeTextSize == nil)
            Divider()
        }

        CommandMenu("Recording") {
            // Capture, so pausing and stopping work from the keyboard while dBrief is active.
            if appState.isRecording || appState.isPaused {
                Button(appState.isPaused ? "Resume Recording" : "Pause Recording") {
                    if appState.isPaused { recordingManager.requestResume() } else { recordingManager.pauseRecording() }
                }
                .keyboardShortcut(CaptureShortcut.pauseResume)
                Button("Stop Recording") { Task { await recordingManager.stopRecording() } }
                    .keyboardShortcut(CaptureShortcut.stop)
            } else {
                Button("Start Recording") { Task { await recordingManager.requestRecording() } }
                    .disabled(!appState.isIdle)
            }
            Divider()
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
            Button(viewer?.currentSpeakerName.map { "Rename “\($0)”…" } ?? "Rename Speaker…") {
                viewer?.renameCurrentSpeaker?()
            }
            .disabled(viewer?.renameCurrentSpeaker == nil)
            Button(viewer?.currentSpeakerIsMe == true ? "Clear “This Is Me”"
                   : viewer?.currentSpeakerName.map { "“\($0)” Is Me" } ?? "This Is Me") {
                viewer?.toggleCurrentSpeakerIsMe?()
            }
            .disabled(viewer?.toggleCurrentSpeakerIsMe == nil)
            Divider()
            Button("Integrations…") { viewer?.reviewIntegrations?() }
                .disabled(viewer?.reviewIntegrations == nil)
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
