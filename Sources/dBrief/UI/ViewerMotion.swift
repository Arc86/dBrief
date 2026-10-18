import SwiftUI

/// Short, restrained transitions for the transcript viewer. Call sites opt in
/// to these animations so playback, streaming, and resize gestures stay direct.
enum ViewerMotion {
    static let panel = Animation.easeOut(duration: 0.16)
    static let document = Animation.easeOut(duration: 0.12)
    static let popover = Animation.easeOut(duration: 0.14)
}

/// Fades controls inside a native SwiftUI popover while leaving the system
/// popover presentation and dismissal behavior untouched.
struct ViewerPopoverContent<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .opacity(isVisible ? 1 : 0)
            .onAppear {
                guard !reduceMotion else {
                    isVisible = true
                    return
                }
                isVisible = false
                withAnimation(ViewerMotion.popover) {
                    isVisible = true
                }
            }
            .onDisappear {
                isVisible = false
            }
    }
}
