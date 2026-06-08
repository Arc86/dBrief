import Carbon
import os

private let log = Logger.hotkey

/// Registers a user-configurable global keyboard shortcut to toggle recording.
@MainActor
final class GlobalHotkeyService {
    private var eventHandler: EventHandlerRef?
    private var hotkeyRef: EventHotKeyRef?
    private var onToggle: (() -> Void)?

    /// Installs the event handler and registers the given shortcut.
    func register(hotkey: RecordHotkey, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // Install handler
        let handlerResult = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let service = Unmanaged<GlobalHotkeyService>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    service.onToggle?()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        guard handlerResult == noErr else {
            log.error("Failed to install hotkey handler: \(handlerResult)")
            return
        }

        apply(hotkey)
    }

    /// Re-registers with a new shortcut, e.g. after the user changes it in Settings.
    func update(hotkey: RecordHotkey) {
        guard eventHandler != nil else { return }
        apply(hotkey)
    }

    /// (Re)registers just the hot key, leaving the installed handler in place.
    private func apply(_ hotkey: RecordHotkey) {
        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            self.hotkeyRef = nil
        }

        let hotkeyID = EventHotKeyID(signature: OSType(0x5652_4543), id: 1) // "VREC"

        let registerResult = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.carbonModifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        if registerResult == noErr {
            log.info("Global hotkey \(hotkey.displayString, privacy: .public) registered")
        } else {
            log.error("Failed to register hotkey \(hotkey.displayString, privacy: .public): \(registerResult)")
        }
    }

    func unregister() {
        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            self.hotkeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        onToggle = nil
    }
}
