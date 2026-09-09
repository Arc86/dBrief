import Foundation

/// Native callbacks may already be queued when their timer/observer is removed.
/// Check the originating source's lifetime on delivery, before touching state.
@MainActor
final class CaptureCallbackLifetime {
    private(set) var isValid = true

    func invalidate() { isValid = false }

    func handler(_ action: @escaping @MainActor () -> Void) -> @Sendable () -> Void {
        { Task { @MainActor in
            guard self.isValid else { return }
            action()
        } }
    }
}
