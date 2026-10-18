import AppKit

/// The one confirmation for actions that throw work away, so every such action asks
/// the same way: a warning alert whose destructive button names the action.
@MainActor enum DestructiveConfirmation {
    static func confirm(_ title: String, message: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }
}
