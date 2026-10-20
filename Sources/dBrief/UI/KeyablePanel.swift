import AppKit

/// A borderless floating panel that can still take keyboard focus. A plain borderless
/// `NSPanel` refuses key status, so its Return/Esc shortcuts never fire and Tab and
/// VoiceOver can't operate its buttons. A mouse click doesn't make it key
/// (`becomesKeyOnlyIfNeeded`), so clicking a button doesn't take typing away from the
/// app in front.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    convenience init(size: NSSize, title: String) {
        self.init(contentRect: NSRect(origin: .zero, size: size),
                  styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered,
                  defer: true)
        self.title = title
        becomesKeyOnlyIfNeeded = true
        setAccessibilityLabel(title)
    }

    /// True when the user drives the Mac from the keyboard or with VoiceOver, so a
    /// panel that appears on its own should take focus.
    static var assistiveFocusPreferred: Bool {
        NSWorkspace.shared.isVoiceOverEnabled || NSApp.isFullKeyboardAccessEnabled
    }
}
