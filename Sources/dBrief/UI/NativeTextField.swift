import SwiftUI
import AppKit

/// Multi-line NSTextView wrapper for editing prompts in Settings windows.
struct NativeTextView: NSViewRepresentable {
    @Binding var text: String
    /// Renders the text in a monospaced system font (e.g. for CLI commands).
    var monospaced: Bool = false

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.font = monospaced
            ? .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.smallSystemFontSize)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.string = text
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 4, height: 4)
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let textView = nsView.documentView as! NSTextView
        // Don't clobber in-progress typing while a debounced commit is pending:
        // only apply a genuine external change (binding differs from the value
        // we last pushed). Our own debounced writes match `lastPushed`, so they
        // never round-trip back onto the text view mid-edit.
        if text != context.coordinator.lastPushed, textView.string != text {
            textView.string = text
            context.coordinator.lastPushed = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    /// Flush any pending debounced edit when the view is torn down (e.g. the
    /// settings window closes) so it isn't lost.
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.flushPending()
    }

    /// Commits edits to the bound value on a short debounce (and immediately on
    /// end-editing) instead of on every keystroke — the prompt/vocabulary/CLI
    /// bindings persist to UserDefaults in a `didSet`, so a per-character write
    /// re-serialized the whole string (and JSON-encoded the CLI config) on each
    /// keypress.
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        /// The value we last pushed to the binding — lets `updateNSView`
        /// distinguish a genuine external change from our own debounce lag.
        var lastPushed: String
        private var pendingCommit: DispatchWorkItem?
        /// The latest not-yet-committed edit, flushed on end-editing or teardown.
        private var pendingValue: String?

        init(text: Binding<String>) {
            self.text = text
            self.lastPushed = text.wrappedValue
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let current = textView.string
            pendingValue = current
            pendingCommit?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.commit(current) }
            pendingCommit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            pendingCommit?.cancel()
            commit(textView.string)
        }

        /// Commit an outstanding edit immediately (view teardown).
        func flushPending() {
            pendingCommit?.cancel()
            if let pendingValue { commit(pendingValue) }
        }

        private func commit(_ value: String) {
            pendingValue = nil
            lastPushed = value
            if text.wrappedValue != value { text.wrappedValue = value }
        }
    }
}

/// NSTextField wrapper that reliably accepts keyboard input in Settings windows.
struct NativeTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField
        if isSecure {
            field = NSSecureTextField()
        } else {
            field = NSTextField()
        }
        field.placeholderString = placeholder
        field.stringValue = text
        field.delegate = context.coordinator
        field.bezelStyle = .roundedBezel
        field.isBordered = true
        field.isBezeled = true
        field.focusRingType = .exterior
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
