import AppKit
import Carbon

/// A user-configurable global keyboard shortcut for toggling recording.
///
/// Stores the virtual key code plus Carbon modifier flags so it can be handed
/// directly to `RegisterEventHotKey`, along with a captured display label so we
/// don't need to translate key codes back into characters for the UI.
struct RecordHotkey: Equatable, Sendable, Codable {
    /// Virtual key code (matches both `NSEvent.keyCode` and Carbon `kVK_*`).
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey | shiftKey | optionKey | controlKey`).
    var carbonModifiers: UInt32
    /// Human-readable label for the base key, captured at record time (e.g. "R", "Space").
    var keyLabel: String

    /// Default shortcut: ⌃⌥⌘R. Mnemonic for "Record" and unlikely to collide
    /// with common browser/app shortcuts (unlike the old ⌘⇧R, which is Chrome's
    /// hard-refresh).
    static let `default` = RecordHotkey(
        keyCode: UInt32(kVK_ANSI_R),
        carbonModifiers: UInt32(controlKey | optionKey | cmdKey),
        keyLabel: "R"
    )

    /// Symbolic representation for display, e.g. "⌃⌥⌘R".
    var displayString: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += keyLabel
        return result
    }

    /// True if at least one of Control/Option/Command is held. Shift alone is
    /// not enough — a global hotkey without a "real" modifier would hijack
    /// ordinary typing.
    var hasRequiredModifier: Bool {
        carbonModifiers & UInt32(controlKey | optionKey | cmdKey) != 0
    }

    /// Builds a hotkey from a captured `NSEvent` key-down event. Returns nil if
    /// the event lacks a usable modifier combination.
    static func from(event: NSEvent) -> RecordHotkey? {
        let carbon = carbonModifiers(from: event.modifierFlags)
        let hotkey = RecordHotkey(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: carbon,
            keyLabel: keyLabel(for: event)
        )
        return hotkey.hasRequiredModifier ? hotkey : nil
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    /// Derives a readable label for the base key from an event.
    private static func keyLabel(for event: NSEvent) -> String {
        // Named keys that have no useful printable character.
        if let named = namedKeys[Int(event.keyCode)] { return named }
        let chars = (event.charactersIgnoringModifiers ?? "").uppercased()
        if let first = chars.first, !first.isWhitespace {
            return String(first)
        }
        return "Key \(event.keyCode)"
    }

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space",
        kVK_Return: "↩",
        kVK_Tab: "⇥",
        kVK_Delete: "⌫",
        kVK_Escape: "⎋",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}
