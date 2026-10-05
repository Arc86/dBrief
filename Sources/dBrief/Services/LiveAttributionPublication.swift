import Foundation
import dBriefWire

/// Separate sticky optional authority. The sole nested order is optional then
/// recording; no suspension or owner callback is permitted inside these gates.
final class LiveAttributionPublication: Sendable {
    let identity: LiveSessionIdentity
    let ownerID: UUID
    let recording: RecordingDerivativeValidity
    private final class Acknowledgement: @unchecked Sendable {
        private let lock = NSLock()
        private var written = false
        var wasWritten: Bool { lock.withLock { written } }
        func markWritten() { lock.withLock { written = true } }
    }
    private let optional = RecordingDerivativeValidity()
    private let acknowledgement = Acknowledgement()
    var contextWasAcknowledged: Bool { acknowledgement.wasWritten }
    /// Called only after actual successful atomic writer dispatch inside the gates.
    func contextAcknowledgementWasWritten() { acknowledgement.markWritten() }
    init(identity: LiveSessionIdentity, ownerID: UUID, recording: RecordingDerivativeValidity) {
        self.identity = identity; self.ownerID = ownerID; self.recording = recording
    }
    var isActive: Bool { (try? dispatch { true }) == true }
    func seal() { optional.invalidate() }
    func dispatch<T>(_ body: () throws -> T) throws -> T {
        try optional.withValidResult { try recording.withValidResult(body) }
    }
    /// Store mutation already enters recording validity. Enter it exactly once.
    func storeMutation<T>(recording token: RecordingDerivativeValidity, _ body: () throws -> T) throws -> T {
        guard token === recording else { throw CancellationError() }
        return try optional.withValidResult(body)
    }
}
