import Foundation
import Network

/// One-shot HTTP listener for the TickTick OAuth redirect (RFC 8252 loopback).
/// Binds to 127.0.0.1 only, answers the callback request with a short page, and
/// hands its URL to `waitForCallback()`. Not actor-isolated: Network framework
/// calls its handlers on a private queue.
final class TickTickLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.dbrief.ticktick.loopback")
    private let lock = NSLock()
    private var outcome: Result<URL, Error>?
    private var waiter: CheckedContinuation<URL, Error>?

    init(port: UInt16 = TickTickAPI.loopbackPort) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    /// Starts listening and returns the bound port.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    /// Waits for the browser to reach the callback path.
    func waitForCallback() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(with: outcome)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel(with error: Error = CancellationError()) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let waiting = waiter
        waiter = nil
        lock.unlock()
        listener.cancel()
        waiting?.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            guard let url = TickTickAPI.callbackURL(fromRequest: request) else {
                Self.respond(on: connection, status: "404 Not Found", body: "Not found")
                return
            }
            Self.respond(on: connection, status: "200 OK", body: Self.donePage)
            self?.finish(.success(url))
        }
    }

    private static func respond(on connection: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static let donePage = """
    <!doctype html><html><head><meta charset="utf-8"><title>dBrief</title></head>
    <body style="font: 15px -apple-system, sans-serif; padding: 48px; text-align: center">
    <p>TickTick sign-in received. You can close this tab and return to dBrief.</p></body></html>
    """
}

/// Lets exactly one caller through; guards a continuation against double resumes.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}
