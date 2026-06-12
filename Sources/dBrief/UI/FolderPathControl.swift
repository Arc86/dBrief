import AppKit
import SwiftUI

/// Native folder-path display backed by `NSPathControl`.
///
/// Shows a folder URL the way Finder/System Settings do — truncating the middle
/// components so the meaningful leaf folder stays visible — and reveals the folder
/// in Finder on double-click. Changing the folder stays on the adjacent "Choose…"
/// button so the security-scoped-bookmark write path in `AppSettings` is preserved.
struct FolderPathControl: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSPathControl {
        let control = NSPathControl()
        control.pathStyle = .standard
        control.isEditable = false
        control.focusRingType = .none
        control.controlSize = .small
        control.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        control.backgroundColor = .clear

        // Reveal the folder in Finder on double-click.
        control.target = context.coordinator
        control.doubleAction = #selector(Coordinator.revealInFinder(_:))

        // Truncate rather than force the row to grow with long paths.
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        control.url = url
        return control
    }

    func updateNSView(_ control: NSPathControl, context: Context) {
        context.coordinator.url = url
        if control.url != url {
            control.url = url
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        @objc func revealInFinder(_ sender: NSPathControl) {
            // Prefer the clicked component's URL; fall back to the whole path.
            let target = sender.clickedPathItem?.url ?? url
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }
}
