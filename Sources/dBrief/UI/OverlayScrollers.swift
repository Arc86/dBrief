import AppKit
import SwiftUI

/// Forces the enclosing `NSScrollView` to use thin, auto-hiding **overlay**
/// scrollers — the "appear while scrolling, fade out when idle" style — even when
/// the system "Show scroll bars" preference is set to "Always". SwiftUI's
/// `.scrollIndicators(.automatic)` merely follows that system setting, so custom
/// `ScrollView`s render permanent legacy scrollers when it's on "Always".
///
/// Attach with `.overlayScrollers()` to the *content inside* a `ScrollView` (so
/// the backing view is part of the scroll view's document view and can find its
/// enclosing scroll view).
private struct OverlayScrollerStyler: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        /// Set once the enclosing scroll view has been styled, so the frequent
        /// `updateNSView` passes (one per SwiftUI update of the scroll content)
        /// don't each schedule a main-queue block.
        var applied = false
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        apply(from: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(from: nsView, coordinator: context.coordinator)
    }

    private func apply(from view: NSView, coordinator: Coordinator) {
        guard !coordinator.applied else { return }
        // Runs after attachment so `enclosingScrollView` is resolvable.
        DispatchQueue.main.async {
            guard let scroll = view.enclosingScrollView else { return }
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
            coordinator.applied = true
        }
    }
}

extension View {
    /// Renders this scroll content's scrollers as thin, auto-hiding overlays.
    func overlayScrollers() -> some View {
        background(OverlayScrollerStyler())
    }
}
