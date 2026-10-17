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

    @MainActor
    final class Coordinator: NSObject {
        /// The styled scroll view, once resolved. Weak: SwiftUI owns it.
        weak var scrollView: NSScrollView?
        /// Set once the main-queue lookup is scheduled, so the frequent
        /// `updateNSView` passes don't each schedule another block.
        var lookupScheduled = false

        override init() {
            super.init()
            // AppKit resets every scroll view to `NSScroller.preferredScrollerStyle`
            // when that preference changes. With "Show scroll bars: Automatically",
            // it flips whenever a Bluetooth mouse connects or drops off (sleep, wake,
            // switching hosts), which left legacy scrollers stuck on screen until the
            // view was rebuilt. Selector-based observers are removed automatically.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(preferredStyleChanged),
                name: NSScroller.preferredScrollerStyleDidChangeNotification,
                object: nil
            )
        }

        @objc private func preferredStyleChanged() {
            // Re-apply after AppKit's own handler has reset the style.
            DispatchQueue.main.async { [weak self] in self?.enforce() }
        }

        /// Cheap when already styled: two property reads.
        func enforce() {
            guard let scroll = scrollView else { return }
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
        }
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
        if coordinator.scrollView != nil {
            coordinator.enforce()
            return
        }
        guard !coordinator.lookupScheduled else { return }
        coordinator.lookupScheduled = true
        // Runs after attachment so `enclosingScrollView` is resolvable.
        DispatchQueue.main.async {
            coordinator.lookupScheduled = false
            guard let scroll = view.enclosingScrollView else { return }
            coordinator.scrollView = scroll
            coordinator.enforce()
        }
    }
}

extension View {
    /// Renders this scroll content's scrollers as thin, auto-hiding overlays.
    func overlayScrollers() -> some View {
        background(OverlayScrollerStyler())
    }
}
