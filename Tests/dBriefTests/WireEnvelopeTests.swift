import Testing
import Foundation
@testable import dBriefWire

@Suite struct WireEnvelopeTests {
    @Test func requestRoundTrips() throws {
        let req = RequestEnvelope(
            id: UUID(),
            request: .transcribe(path: "/tmp/a.m4a", initialPrompt: "hi",
                                 config: .default, safeMode: false)
        )
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(RequestEnvelope.self, from: data)
        #expect(decoded.id == req.id)
        if case let .transcribe(path, prompt, _, safe) = decoded.request {
            #expect(path == "/tmp/a.m4a")
            #expect(prompt == "hi")
            #expect(safe == false)
        } else { Issue.record("wrong request case") }
    }

    @Test func eventRoundTripsResultAndError() throws {
        let id = UUID()
        let result = EventEnvelope(id: id, channel: .plugin,
            event: .transcriptionResult(TranscriptionResult(text: "x")))
        let rDecoded = try JSONDecoder().decode(
            EventEnvelope.self, from: try JSONEncoder().encode(result))
        if case let .transcriptionResult(tr) = rDecoded.event {
            #expect(tr.text == "x")
        } else { Issue.record("wrong event case") }

        let err = EventEnvelope(id: id, channel: .plugin,
            event: .error(WireError(kind: .insufficientMemory,
                                    message: "need 4 GB", model: "Large", requiredGB: "4.0")))
        let eDecoded = try JSONDecoder().decode(
            EventEnvelope.self, from: try JSONEncoder().encode(err))
        if case let .error(w) = eDecoded.event {
            #expect(w.kind == .insufficientMemory)
            #expect(w.requiredGB == "4.0")
        } else { Issue.record("wrong event case") }
    }
}
