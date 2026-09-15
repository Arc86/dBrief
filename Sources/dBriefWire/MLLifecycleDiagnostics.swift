import Foundation

/// Bounded, local operational evidence. Callers supply only operation names and
/// compute settings, never audio paths, prompts, transcript text, or raw errors.
/// Use a different filename for the client and helper (each has one writer).
public final class MLLifecycleDiagnostics: @unchecked Sendable {
    public enum Event: String, Codable, Sendable {
        case memoryWarning, memoryCritical
        case operationStarted, operationFinished, operationFailed
        case cleanupRequested, cleanupDeferred, cleanupStarted, cleanupCompleted
        case shutdownRequested, shutdownCompleted
        case transcriptionStarted, helperCrashed, recoveryStarted, recoveryCompleted, recoveryFailed
    }

    private struct Entry: Encodable {
        let date: Date
        let processID: Int32
        let event: Event
        let operation: String?
        let computeUnits: String?
        let workers: Int?
    }

    private let url: URL
    private let maxBytes: Int
    private let lock = NSLock()

    public init(url: URL, maxBytes: Int = 262_144) {
        self.url = url
        self.maxBytes = maxBytes
    }

    public func record(_ event: Event, operation: String? = nil, computeUnits: String? = nil, workers: Int? = nil) {
        lock.withLock {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                var data = try encoder.encode(Entry(date: Date(), processID: ProcessInfo.processInfo.processIdentifier,
                                                    event: event, operation: operation, computeUnits: computeUnits, workers: workers))
                data.append(0x0A)
                let fm = FileManager.default
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                if size > 0, size + data.count > maxBytes {
                    let previous = url.appendingPathExtension("previous")
                    if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
                    try fm.moveItem(at: url, to: previous)
                }
                if !fm.fileExists(atPath: url.path) {
                    guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
                }
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                try file.seekToEnd()
                try file.write(contentsOf: data)
            } catch {
                // Diagnostic I/O must never interrupt inference or cleanup.
            }
        }
    }
}
