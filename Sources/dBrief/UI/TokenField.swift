import SwiftUI
import AppKit

/// NSTokenField wrapper presenting a comma-separated string as removable chips.
/// Backed by a plain `String` (comma-joined) so it drops in wherever a vocabulary
/// string is persisted, without changing the underlying model.
struct TokenField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.tokenStyle = .rounded
        field.objectValue = Self.tokens(from: text)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSTokenField, context: Context) {
        let current = (nsView.objectValue as? [String]) ?? []
        let desired = Self.tokens(from: text)
        if current != desired {
            nsView.objectValue = desired
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Splits the stored string into trimmed, non-empty tokens.
    static func tokens(from text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    final class Coordinator: NSObject, NSTokenFieldDelegate {
        let parent: TokenField
        init(_ parent: TokenField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTokenField else { return }
            let tokens = (field.objectValue as? [String]) ?? []
            parent.text = tokens.joined(separator: ", ")
        }

        // No autocomplete pop-up — vocabulary terms are user-defined.
        func tokenField(
            _ tokenField: NSTokenField,
            completionsForSubstring substring: String,
            indexOfToken tokenIndex: Int,
            indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?
        ) -> [Any]? {
            []
        }
    }
}
