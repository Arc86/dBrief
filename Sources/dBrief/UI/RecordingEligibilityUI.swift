import SwiftUI

extension View {
    /// Disables a recording action that `RecordingManager.eligibility` blocks, and says
    /// why in its help tag instead of failing after the click.
    func recordingBlock(_ block: RecordingBlock?, help: LocalizedStringResource) -> some View {
        disabled(block != nil).help(block?.message ?? String(localized: help))
    }
}

extension AppState {
    /// Opens the menu panel on Queue & Recovery, where blocked work is resolved.
    @MainActor func showInQueue(_ id: UUID) {
        queueFocusRequest = id
        MenuBarPanel.show()
    }
}
