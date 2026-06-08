import AppKit
import SwiftUI

/// A control for capturing a global keyboard shortcut. Click to arm, then press
/// a modifier + key combination. Escape cancels; the captured combo must
/// include at least one of Control/Option/Command.
struct ShortcutRecorderView: View {
    @Binding var hotkey: RecordHotkey

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if isRecording { stop() } else { start() }
            } label: {
                Text(isRecording ? "Press shortcut…" : hotkey.displayString)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .monospaced()
                    .frame(minWidth: 110)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)

            if isRecording {
                Text(hint ?? "esc to cancel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if hotkey != .default {
                Button("Reset") { hotkey = .default }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        hint = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape cancels recording without changing the shortcut.
            if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stop()
                return nil
            }
            if let captured = RecordHotkey.from(event: event) {
                hotkey = captured
                stop()
            } else {
                hint = "needs ⌃, ⌥, or ⌘"
            }
            return nil // consume the event so it doesn't reach the app
        }
    }

    private func stop() {
        isRecording = false
        hint = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
