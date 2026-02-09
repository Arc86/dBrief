import Carbon
import os

private let log = Logger(subsystem: "com.dbrief.app", category: "hotkey")

/// Registers a global keyboard shortcut (⌘⇧R) to toggle recording.
@MainActor
final class GlobalHotkeyService {
    private var eventHandler: EventHandlerRef?
    private var hotkeyRef: EventHotKeyRef?
    private var onToggle: (() -> Void)?

    func register(onToggle: @escaping () -> Void) {
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

        // Register ⌘⇧R
        let hotkeyID = EventHotKeyID(signature: OSType(0x5652_4543), id: 1) // "VREC"
        let modifiers = UInt32(cmdKey | shiftKey)
        let keyCode = UInt32(kVK_ANSI_R)

        let registerResult = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        if registerResult == noErr {
            log.info("Global hotkey ⌘⇧R registered")
        } else {
            log.error("Failed to register hotkey: \(registerResult)")
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
