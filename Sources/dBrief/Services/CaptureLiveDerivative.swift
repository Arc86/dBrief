import Foundation
import dBriefWire

/// A recording-owned derivative drains registered capture streams after hardware
/// closure. Its model preparation is independent of the audio terminal task.
struct CaptureLiveDerivative: Sendable {
    struct Session: Sendable {
        let identity: LiveSessionIdentity
        let ingress: LiveCaptureIngress?
        let registerPrepared: (@MainActor @Sendable (CaptureLivePreview.Inputs) -> Bool)?
        var register: @MainActor @Sendable (CaptureLivePreview.Inputs) -> Void
        var beginClosing: @MainActor @Sendable () -> Void
        var hardwareDidClose: @Sendable () async -> Void
        var expire: @MainActor @Sendable () -> Void
        var pause: @MainActor @Sendable () -> Void = {}
        var resume: @MainActor @Sendable () -> Void = {}
        var inputDeviceChanged: @MainActor @Sendable () -> Void = {}

        init(identity: LiveSessionIdentity,
             register: @escaping @MainActor @Sendable (CaptureLivePreview.Inputs) -> Void,
             beginClosing: @escaping @MainActor @Sendable () -> Void,
             hardwareDidClose: @escaping @Sendable () async -> Void,
             expire: @escaping @MainActor @Sendable () -> Void,
             pause: @escaping @MainActor @Sendable () -> Void = {},
             resume: @escaping @MainActor @Sendable () -> Void = {},
             inputDeviceChanged: @escaping @MainActor @Sendable () -> Void = {},
             ingress: LiveCaptureIngress? = nil,
             registerPrepared: (@MainActor @Sendable (CaptureLivePreview.Inputs) -> Bool)? = nil) {
            self.identity = identity; self.ingress = ingress; self.registerPrepared = registerPrepared
            self.register = register; self.beginClosing = beginClosing; self.hardwareDidClose = hardwareDidClose
            self.expire = expire; self.pause = pause; self.resume = resume; self.inputDeviceChanged = inputDeviceChanged
        }
    }
    struct Prepared: Sendable {
        let ingress: LiveCaptureIngress
        let session: Session
    }
    var prepare: @MainActor @Sendable (CaptureCoordinator.Request) -> Prepared? = { _ in nil }
    var make: @MainActor @Sendable (CaptureCoordinator.Request, CaptureSessionStore.Session) -> Session?
    static let disabled = Self(make: { _, _ in nil })
}
