import AppKit
import SwiftUI

/// The viewer draws its own themed workspace up to the window edge. Keep the
/// real macOS window buttons and drag behaviour without a separate toolbar row.
struct ViewerWindowChrome: ViewModifier {
    @Environment(\.viewerPalette) private var palette

    func body(content: Content) -> some View {
        content
            .ignoresSafeArea(.container, edges: .top)
            .background(ViewerWindowConfiguration(color: NSColor(palette.canvas.color)))
    }
}

private struct ViewerWindowConfiguration: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> WindowView { WindowView(color: color) }
    func updateNSView(_ view: WindowView, context: Context) {
        view.color = color
        view.configureWindow()
    }

    final class WindowView: NSView {
        var color: NSColor

        init(color: NSColor) {
            self.color = color
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
            window.backgroundColor = color
        }
    }
}
