import Darwin
import Foundation
import dBriefWire

/// Live output has no unbounded event drain. A blocked pipe can stop this role;
/// the parent retains its independent timer and force terminates this process.
private final class LiveStdoutWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var sessionRequestID: UUID?
    init(_ handle: FileHandle) { self.handle = handle; _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) }
    func claimSession(_ id: UUID) { lock.withLock { if sessionRequestID == nil { sessionRequestID = id } } }
    private func write(_ envelope: EventEnvelope) {
        guard let data = try? JSONEncoder().encode(envelope), data.count <= LiveFrameReader.maximumFrameBytes else { exit(1) }
        do { try handle.write(contentsOf: FrameCodec.encode(data)) } catch { exit(1) }
    }
    func event(_ event: LiveSessionEvent) {
        lock.withLock { if let id = sessionRequestID { write(.init(id: id,channel: .live,event: .live(.event(event)))) } }
    }
    func reply(_ id: UUID, _ reply: LiveSessionReply, terminal: Bool = true) {
        lock.withLock {
            write(.init(id: id,channel: .live,event: .live(.reply(reply))))
            if terminal { write(.init(id: id,channel: .live,event: .finished)) }
        }
    }
}

enum LiveRequestLoop {
    static func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) async {
        let writer = LiveStdoutWriter(output)
        let helper = LiveASROrchestrator(loader: { configuration in
            let config = try NemotronDecoderConfiguration(language: .init(rawValue: configuration.language.rawValue)!,chunkMs: configuration.chunkMs)
            return try await NemotronDecoderFactory.load(from: URL(fileURLWithPath: configuration.modelDirectory),configuration: config)
        },emit: writer.event)
        var reader = LiveFrameReader(), identity: LiveSessionIdentity?
        do {
            while let data = try LiveFrameReader.readChunk(from: input) {
                for frame in try reader.feed(data) {
                    let envelope = try JSONDecoder().decode(RequestEnvelope.self,from: frame)
                    guard case .live(let request) = envelope.request else { writer.reply(envelope.id,.rejected(.unsupportedRole)); continue }
                    if case .begin(let begin) = request {
                        guard begin.isValid else { writer.reply(envelope.id,.rejected(.invalidConfiguration)); continue }
                        writer.claimSession(envelope.id)
                        let reply = await helper.handle(request,requestID: envelope.id)
                        if reply == .accepted { identity = begin.identity }
                        writer.reply(envelope.id,reply,terminal: reply != .accepted)
                    } else {
                        writer.reply(envelope.id,await helper.handle(request,requestID: envelope.id))
                    }
                }
            }
        } catch { exit(1) } // Framing/SDK errors never become arbitrary diagnostic text.
        if let identity { _ = await helper.handle(.cancel(identity),requestID: UUID()) }
    }
}
