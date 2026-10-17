import Foundation

/// Routes each request to a per-test responder chosen by its credential (the
/// bearer token, or the Basic value for the token endpoint), so parallel tests
/// never share responders.
final class TickTickStubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case status(Int, String)
        case failure(URLError.Code)
    }
    struct Seen: Sendable, Equatable {
        let method: String
        let path: String
        let body: String
    }
    typealias Responder = @Sendable (Seen) -> Reply

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responders: [String: Responder] = [:]

    static func register(key: String, _ responder: @escaping Responder) {
        lock.withLock { responders[key] = responder }
    }

    static func unregister(key: String) {
        lock.withLock { responders[key] = nil }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TickTickStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        // Also serves the Todoist tests, which share the per-token routing.
        ["ticktick.com", "todoist.com", "notion.com"].contains { request.url?.host?.hasSuffix($0) == true }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let key = authorization.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
        let seen = Seen(method: request.httpMethod ?? "GET", path: request.url?.path ?? "", body: Self.body(of: request))
        guard let responder = Self.lock.withLock({ Self.responders[key] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        switch responder(seen) {
        case .status(let code, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Thread-safe record of what a stub saw.
final class TickTickSeenLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TickTickStubProtocol.Seen] = []

    func append(_ seen: TickTickStubProtocol.Seen) { lock.withLock { items.append(seen) } }
    var all: [TickTickStubProtocol.Seen] { lock.withLock { items } }
    var posts: [TickTickStubProtocol.Seen] { all.filter { $0.method == "POST" } }
}
