import Foundation

/// One URLSession request, including its redirect chain. Writes are chained so
/// cancellation cannot race a suspended redirect callback and lose its token.
actor PrivacyHTTPTrace {
    typealias FileUpload = @Sendable (URLRequest, URL) async throws -> (Data, URLResponse)
    private let context: PrivacyTrace.Context
    private let textQueryItems: Set<String>
    private let modelQueryItem: String?
    private var bodyData: Set<PrivacyOperation.DataCategory>
    private var operation: PrivacyOperation
    private var token: PrivacyTrace.Token?
    private var pending: Task<Void, Never>?
    private var completed = false

    init(operation: PrivacyOperation, context: PrivacyTrace.Context, textQueryItems: Set<String> = [],
         textInBody: Bool = true, modelQueryItem: String? = nil) {
        self.operation = operation
        self.context = context
        self.textQueryItems = textQueryItems
        self.modelQueryItem = modelQueryItem
        self.bodyData = operation.data
        if !textInBody { self.bodyData.remove(.text) }
    }

    func start() async {
        token = await PrivacyTrace.begin(operation, in: context)
    }

    func redirect(to request: URLRequest) async {
        let previous = pending
        let next = Task {
            await previous?.value
            await self.recordRedirect(to: request)
        }
        pending = next
        await next.value
    }

    private func recordRedirect(to request: URLRequest) async {
        guard !completed else { return }
        await PrivacyTrace.finish(token, outcome: .redirected)
        guard let url = request.url else {
            token = nil
            await context.store.noteGap(at: context.receiptURL)
            return
        }
        let method = (request.httpMethod ?? "GET").uppercased()
        let retainsBody = method != "GET" && method != "HEAD"
        if !retainsBody { bodyData = [] }
        var data = bodyData.union([.metadata])
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if items.contains(where: { textQueryItems.contains($0.name) && !($0.value ?? "").isEmpty }) {
            data.insert(.text)
        }
        let sameHost = url.host?.lowercased() == operation.destination.hostname
        let model: String?
        if let modelQueryItem { model = items.first(where: { $0.name == modelQueryItem })?.value }
        else { model = retainsBody ? operation.destination.model : nil }
        operation = PrivacyOperation(stage: operation.stage, data: data,
            destination: .remote(url: url,
                provider: sameHost ? operation.destination.provider : .custom,
                model: model),
            responseFormat: retainsBody ? operation.responseFormat : nil)
        token = await PrivacyTrace.begin(operation, in: context)
    }

    func finish(response: URLResponse) async {
        let previous = pending
        let next = Task {
            await previous?.value
            await self.recordCompletion(response: response)
        }
        pending = next
        await next.value
    }

    private func recordCompletion(response: URLResponse) async {
        guard !completed else { return }
        completed = true
        if response.url?.host?.lowercased() != operation.destination.hostname {
            // An injected/custom transport that follows redirects without our
            // delegate cannot establish the destinations of the missing hops.
            await context.store.noteGap(at: context.receiptURL)
            // The final host's response cannot complete the original host's
            // attempt. Leave its outcome uncertain instead of inventing success.
            return
        }
        let succeeded = (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
        await PrivacyTrace.finish(token, outcome: succeeded ? .succeeded : .failed)
    }

    func finish(error: Error) async {
        let outcome: PrivacyAttempt.Outcome = error is CancellationError || (error as? URLError)?.code == .cancelled
            ? .cancelled : .failed
        let previous = pending
        let next = Task {
            await previous?.value
            await self.recordFailure(outcome)
        }
        pending = next
        await next.value
    }

    private func recordFailure(_ outcome: PrivacyAttempt.Outcome) async {
        guard !completed else { return }
        completed = true
        await PrivacyTrace.finish(token, outcome: outcome)
    }

    /// Called only after local body preparation/preflight. The default transport
    /// retains URLSession's ordinary redirect policy while observing each hop.
    static func upload(_ request: URLRequest, fromFile file: URL, operation: PrivacyOperation,
                       textQueryItems: Set<String> = [], textInBody: Bool = true, modelQueryItem: String? = nil,
                       session: URLSession = .shared, using upload: FileUpload? = nil) async throws -> (Data, URLResponse) {
        try await perform(operation: operation, textQueryItems: textQueryItems, textInBody: textInBody,
                          modelQueryItem: modelQueryItem) { delegate in
            if let upload { return try await upload(request, file) }
            return try await session.upload(for: request, fromFile: file, delegate: delegate)
        }
    }

    static func data(for request: URLRequest, operation: PrivacyOperation,
                     session: URLSession = .shared) async throws -> (Data, URLResponse) {
        try await perform(operation: operation) { delegate in
            try await session.data(for: request, delegate: delegate)
        }
    }

    /// Streaming completion is recorded by the consumer after reading the body,
    /// not when headers arrive. A broken/cancelled stream cannot become success.
    static func bytes(for request: URLRequest, operation: PrivacyOperation,
                      session: URLSession = .shared) async throws -> (URLSession.AsyncBytes, URLResponse, PrivacyHTTPTrace?) {
        try Task.checkCancellation()
        let trace: PrivacyHTTPTrace?
        if let context = PrivacyTrace.context {
            let scoped = PrivacyHTTPTrace(operation: operation, context: context)
            await scoped.start()
            trace = scoped
        } else { trace = nil }
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request,
                delegate: trace.map { PrivacyHTTPTaskDelegate(trace: $0) })
            return (bytes, response, trace)
        } catch {
            await trace?.finish(error: error)
            throw error
        }
    }

    private static func perform(operation: PrivacyOperation, textQueryItems: Set<String> = [],
                                textInBody: Bool = true, modelQueryItem: String? = nil,
                                send: @Sendable (PrivacyHTTPTaskDelegate?) async throws -> (Data, URLResponse)) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        guard let context = PrivacyTrace.context else { return try await send(nil) }
        let trace = PrivacyHTTPTrace(operation: operation, context: context, textQueryItems: textQueryItems,
                                     textInBody: textInBody, modelQueryItem: modelQueryItem)
        await trace.start()
        do {
            try Task.checkCancellation()
            let result = try await send(PrivacyHTTPTaskDelegate(trace: trace))
            await trace.finish(response: result.1)
            return result
        } catch {
            await trace.finish(error: error)
            throw error
        }
    }
}

private final class PrivacyHTTPTaskDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let trace: PrivacyHTTPTrace
    init(trace: PrivacyHTTPTrace) { self.trace = trace }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        Task {
            await trace.redirect(to: request)
            completionHandler(request)
        }
    }
}
