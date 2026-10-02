import Darwin
import Foundation
import Testing
import dBriefWire

@Suite struct LiveHelperRoleTests {
    @Test func helpIsAvailableWithoutSupportPathsOrModels() throws {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: ".build/debug/dBriefMLHost")
        process.arguments = ["--nemotron-live","--help"]
        process.standardOutput = output; process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: data,as: UTF8.self).contains("no implicit download"))
    }

    @Test func realLiveRoleRejectsSmallOrdinaryRequestBeforeAnyModelPreparation() throws {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: ".build/debug/dBriefMLHost")
        process.arguments = ["--nemotron-live","--support-base","/private/tmp"]
        process.standardInput = input; process.standardOutput = output; process.standardError = Pipe()
        try process.run()
        defer { if process.isRunning { _ = kill(process.processIdentifier,SIGKILL) }; try? input.fileHandleForWriting.close(); process.waitUntilExit() }
        let id = UUID(), envelope = RequestEnvelope(id: id,request: .chatStream(systemPrompt: "Fixture",userMessage: "Fixture"))
        try input.fileHandleForWriting.write(contentsOf: FrameCodec.encode(JSONEncoder().encode(envelope)))
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor,events: Int16(POLLIN),revents: 0)
        // The full suite can delay dyld/framework startup. This checks a small
        // open-pipe reply, not a native startup-latency qualification.
        guard poll(&descriptor,1,5000) > 0 else { Issue.record("Small request blocked until EOF or a full buffer"); return }
        var reader = LiveFrameReader(), replies: [EventEnvelope] = []
        for _ in 0..<2 {
            guard let chunk = try LiveFrameReader.readChunk(from: output.fileHandleForReading) else { break }
            replies += try reader.feed(chunk).map { try JSONDecoder().decode(EventEnvelope.self,from: $0) }
            if replies.contains(where: { if case .finished = $0.event { true } else { false } }) { break }
            guard poll(&descriptor,1,5000) > 0 else { break }
        }
        #expect(replies.contains { reply in reply.id == id && reply.channel == .live && { if case .live(.reply(.rejected(.unsupportedRole))) = reply.event { true } else { false } }() })
        #expect(replies.contains { reply in reply.id == id && { if case .finished = reply.event { true } else { false } }() })
    }
}
