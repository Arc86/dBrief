import AppKit
import SwiftUI

/// AppKit owns the open menu and its item lifetimes. Building SwiftUI ForEach
/// button closures inside the live recording view crashed in executor checking
/// while its observation-driven body was refreshed during device switching.
struct MicrophoneInputMenu: NSViewRepresentable {
    let selectedUID: String
    let enabled: Bool
    let select: @MainActor (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.setAccessibilityLabel("Microphone input")
        let menu = NSMenu()
        menu.delegate = context.coordinator
        button.menu = menu
        context.coordinator.rebuild(menu)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        button.contentTintColor = enabled ? .systemGreen : .secondaryLabelColor
    }

    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
        var parent: MicrophoneInputMenu
        init(parent: MicrophoneInputMenu) { self.parent = parent }

        func menuNeedsUpdate(_ menu: NSMenu) { rebuild(menu) }

        func rebuild(_ menu: NSMenu) {
            menu.removeAllItems()
            let title = NSMenuItem(title: "Mic", action: nil, keyEquivalent: "")
            title.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
            menu.addItem(title)
            add("System Default", uid: "", to: menu)
            menu.addItem(.separator())
            for device in AudioInputDeviceManager.availableInputDevices() {
                add(device.displayName, uid: device.uid, to: menu)
            }
        }

        private func add(_ title: String, uid: String, to menu: NSMenu) {
            let item = NSMenuItem(title: title, action: #selector(chosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = uid
            item.state = uid == parent.selectedUID ? .on : .off
            menu.addItem(item)
        }

        @objc private func chosen(_ item: NSMenuItem) {
            guard let uid = item.representedObject as? String else { return }
            parent.select(uid.isEmpty ? nil : uid)
        }
    }
}
