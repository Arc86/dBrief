import SwiftUI

/// Short, restrained transitions for the transcript viewer. Call sites opt in
/// to these animations so playback, streaming, and resize gestures stay direct.
enum ViewerMotion {
    static let panel = Animation.easeInOut(duration: 0.26)
    static let document = Animation.easeInOut(duration: 0.20)
    static let popover = Animation.easeInOut(duration: 0.22)
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
