import Darwin
import Foundation
import dBriefWire

/// Live output has no unbounded event drain. A blocked pipe can stop this role;
/// the parent retains its independent timer and force terminates this process.
final class LiveStdoutWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var sessionRequestID: UUID?
    private let testingBeforeMandatoryWrite: @Sendable () -> Void
    init(_ handle: FileHandle, testingBeforeMandatoryWrite: @escaping @Sendable () -> Void = {}) { self.handle = handle; self.testingBeforeMandatoryWrite = testingBeforeMandatoryWrite; _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) }
    func claimSession(_ id: UUID) { lock.withLock { if sessionRequestID == nil { sessionRequestID = id } } }
    private func write(_ envelope: EventEnvelope) {
        testingBeforeMandatoryWrite()
        guard let data = try? JSONEncoder().encode(envelope), data.count <= LiveFrameReader.maximumFrameBytes else { exit(1) }
        do { try handle.write(contentsOf: FrameCodec.encode(data)) } catch { exit(1) }
    }
    func event(_ event: LiveSessionEvent) {
        lock.withLock { if let id = sessionRequestID { write(.init(id: id,channel: .live,event: .live(.event(event)))) } }
    }
    /// One atomic optional write. A busy lock/full pipe never waits ASR output.
    func optional(_ event: LiveDiarizationEvent) -> Bool {
        optionalEnvelope {
            guard let id = sessionRequestID else { return nil }
            return .init(id: id, channel: .live, event: .live(.event(.diarization(event))))
        }
    }
    /// Optional requests have one independently correlated tagged reply, with
    /// no mandatory .finished frame or blocking writer dependency.
    func optionalReply(_ id: UUID, _ reply: LiveSessionReply) -> Bool {
        optionalEnvelope { .init(id: id, channel: .live, event: .live(.reply(reply))) }
    }
    private func optionalEnvelope(_ make: () -> EventEnvelope?) -> Bool {
        guard lock.try() else { return false }; defer { lock.unlock() }
        guard let envelope = make(), let body = try? JSONEncoder().encode(envelope),
              let framed = try? LiveOutputDemultiplexer.tag(body) else { return false }
        let fd = handle.fileDescriptor; var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFIFO,
              framed.count <= fpathconf(fd, _PC_PIPE_BUF) else { return false }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        while true {
            let n = framed.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n == framed.count { return true }
            if n < 0, errno == EINTR { continue }
            return false // Atomic <=PIPE_BUF nonblocking writes cannot be partial.
        }
    }
    func reply(_ id: UUID, _ reply: LiveSessionReply, terminal: Bool = true) {
        lock.withLock {
            write(.init(id: id,channel: .live,event: .live(.reply(reply))))
            if terminal { write(.init(id: id,channel: .live,event: .finished)) }
        }
    }
}

enum LiveRequestLoop {
    static func loadVAD(_ input: LiveSessionBegin,loader: LiveVADModelFactory.Loader? = nil) async throws -> LiveVADModelFactory {
        guard let configuration = input.vad else { throw LiveProtocolError.invalidConfiguration }
        let work = Task.detached { try LiveVADModelAssets.openReadOnly(configuration) }
        let assets = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        return try await LiveVADModelFactory.load(configuration: configuration,sources: input.epochs.map(\.source),assets: assets,loader: loader)
    }

    /// The actual request-loop dispatch is also exercised without model loads.
    static func dispatch(_ envelope: RequestEnvelope, helper: LiveASROrchestrator,
                         writer: LiveStdoutWriter, identity: inout LiveSessionIdentity?) async {
        guard case .live(let request) = envelope.request else { writer.reply(envelope.id,.rejected(.unsupportedRole)); return }
        if case .begin(let begin) = request {
            guard begin.isValid else { writer.reply(envelope.id,.rejected(.invalidConfiguration)); return }
            writer.claimSession(envelope.id)
            let reply = await helper.handle(request,requestID: envelope.id)
            if reply == .accepted { identity = begin.identity }
            writer.reply(envelope.id,reply,terminal: reply != .accepted)
        } else {
            let reply = await helper.handle(request, requestID: envelope.id)
            if request.isOptionalDiarizationControl { _ = writer.optionalReply(envelope.id, reply) }
            else { writer.reply(envelope.id, reply) }
        }
    }

    static func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) async {
        let writer = LiveStdoutWriter(output)
        let helper = LiveASROrchestrator(loader: { configuration in
            try await LiveASRNativeLoader.load(configuration)
        },vadLoader: { try await loadVAD($0) },diarizationLoader: { try await LiveDiarizationNativeLoader.load($0) },
           diarizationEmit: writer.optional,emit: writer.event)
        var reader = LiveFrameReader(), identity: LiveSessionIdentity?
        do {
            while let data = try LiveFrameReader.readChunk(from: input) {
                for frame in try reader.feed(data) {
                    let envelope = try JSONDecoder().decode(RequestEnvelope.self,from: frame)
                    await dispatch(envelope, helper: helper, writer: writer, identity: &identity)
                }
            }
        } catch { exit(1) } // Framing/SDK errors never become arbitrary diagnostic text.
        if let identity { _ = await helper.handle(.cancel(identity),requestID: UUID()); await helper.joinDiarizationRetirement() }
    }
}
