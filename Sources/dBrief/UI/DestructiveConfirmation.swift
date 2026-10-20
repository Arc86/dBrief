import AppKit

/// The one confirmation for actions that throw work away, so every such action asks
/// the same way: a warning alert whose destructive button names the action.
@MainActor enum DestructiveConfirmation {
    static func confirm(_ title: LocalizedStringResource, message: LocalizedStringResource,
                        button: LocalizedStringResource) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: title)
        alert.informativeText = String(localized: message)
        alert.addButton(withTitle: String(localized: button))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }
}
