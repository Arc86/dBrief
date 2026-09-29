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

struct ViewerWindowConfiguration: NSViewRepresentable {
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
            // Only when first attached: later SwiftUI updates re-run
            // `configureWindow()`, and must not undo a resize handle's temporary
            // suppression of background dragging.
            window?.isMovableByWindowBackground = true
        }

        func configureWindow() {
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = color
        }
    }
}

/// The viewer window is draggable by its background, so a drag that starts on a
/// resize handle would move the window while also resizing the panel. AppKit's
/// hit-test returns the SwiftUI hosting view (not a background view) over the
/// handle, so a view-level opt-out cannot work. Instead the window's background
/// dragging is switched off while the pointer is over a handle, then restored.
struct WindowDragBlocker: NSViewRepresentable {
    var suppressed: Bool

    final class BlockerView: NSView {
        /// The window's original value while this view has suppressed dragging.
        private var restoreValue: Bool?

        func apply(suppressed: Bool) {
            guard let window else { return }
            if suppressed {
                guard restoreValue == nil else { return }
                restoreValue = window.isMovableByWindowBackground
                window.isMovableByWindowBackground = false
            } else {
                releaseSuppression(on: window)
            }
        }

        func releaseSuppression(on window: NSWindow) {
            guard let value = restoreValue else { return }
            window.isMovableByWindowBackground = value
            restoreValue = nil
        }
    }

    func makeNSView(context: Context) -> BlockerView { BlockerView() }
    func updateNSView(_ view: BlockerView, context: Context) { view.apply(suppressed: suppressed) }

    static func dismantleNSView(_ view: BlockerView, coordinator: ()) {
        if let window = view.window { view.releaseSuppression(on: window) }
    }
}

private struct PreventsWindowDrag: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(WindowDragBlocker(suppressed: hovering))
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Keeps a drag that starts on this view (e.g. a divider) from moving a
    /// background-draggable window.
    func preventsWindowDrag() -> some View {
        modifier(PreventsWindowDrag())
    }
}
