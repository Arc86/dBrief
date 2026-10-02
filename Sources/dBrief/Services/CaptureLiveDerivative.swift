import Foundation
import dBriefWire

/// A recording-owned derivative drains registered capture streams after hardware
/// closure. Its model preparation is independent of the audio terminal task.
struct CaptureLiveDerivative: Sendable {
    struct Session: Sendable {
        let identity: LiveSessionIdentity
        var register: @MainActor @Sendable (CaptureLivePreview.Inputs) -> Void
        var beginClosing: @MainActor @Sendable () -> Void
        var hardwareDidClose: @Sendable () async -> Void
        var expire: @MainActor @Sendable () -> Void
        var pause: @MainActor @Sendable () -> Void = {}
        var resume: @MainActor @Sendable () -> Void = {}
        var inputDeviceChanged: @MainActor @Sendable () -> Void = {}
    }
    var make: @MainActor @Sendable (CaptureCoordinator.Request, CaptureSessionStore.Session) -> Session?
    static let disabled = Self(make: { _, _ in nil })
}
