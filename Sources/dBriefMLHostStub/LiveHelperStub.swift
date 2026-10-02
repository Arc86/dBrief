import Foundation
import dBriefWire

/// Deterministic, model-free scenarios for the dedicated connection.
struct LiveHelperStub {
    private struct Lane { let epoch: LiveEpoch; var end: Int64 = 0; var settled: Int64 = 0; var packet: UInt64 = 0; var event: UInt64 = 0; var segment: UInt64 = 0; var closed = false }
    let mode: String
    private var begin: LiveSessionBegin?
    private var streamID: UUID?
    private var lanes: [LiveSource: Lane] = [:]
    init(mode: String) { self.mode = mode }
    private mutating func event(_ source: LiveSource, _ payload: LiveLaneEvent.Payload, send: (EventEnvelope) -> Void) {
        guard let begin, let id = streamID, let lane = lanes[source] else { return }
        lanes[source]?.event += 1
        send(.init(id: id,channel: .live,event: .live(.event(.lane(.init(scope: .init(identity: begin.identity,source: source,epochID: lane.epoch.id),sequence: lane.event,payload: payload))))))
    }
    mutating func handle(_ envelope: RequestEnvelope, send: (EventEnvelope) -> Void) {
        func reply(_ reply: LiveSessionReply, terminal: Bool = true) {
            send(.init(id: envelope.id,channel: .live,event: .live(.reply(reply))))
            if terminal { send(.init(id: envelope.id,channel: .live,event: .finished)) }
        }
        guard CommandLine.arguments.contains("--nemotron-live"), case .live(let request) = envelope.request else { reply(.rejected(.unsupportedRole)); return }
        switch request {
        case .begin(let begin):
            guard self.begin == nil, begin.isValid else { reply(.rejected(.invalidConfiguration)); return }
            self.begin = begin; streamID = envelope.id
            reply(.accepted,terminal: false)
            if mode == "live-init-failure" { send(.init(id: envelope.id,channel: .live,event: .live(.event(.failed(begin.identity,.unavailable))))); return }
            if mode == "live-oversized" { FileHandle.standardOutput.write(Data([0,1,0,1])); return }
            for epoch in begin.epochs {
                lanes[epoch.source] = Lane(epoch: epoch)
                if mode == "live-wrong-scope" {
                    send(.init(id: envelope.id,channel: .live,event: .live(.event(.finished(.init(recordingID: UUID(),captureSessionID: begin.identity.captureSessionID)))))); return
                }
                event(epoch.source,.ready(generation: UUID(),originSample: 0),send: send)
            }
            if mode == "live-read-stall" { Thread.sleep(forTimeInterval: 10) }
        case .packet(let packet):
            if mode == "live-crash" { exit(9) }
            guard let begin, packet.scope.identity == begin.identity, var lane = lanes[packet.scope.source], lane.epoch.id == packet.scope.epochID,
                  packet.sequence == lane.packet, packet.startSample == lane.end, (try? packet.decodedSamples()) != nil else { reply(.rejected(.invalidPacket)); return }
            lane.packet += 1; lane.end += Int64(packet.sampleCount); lanes[packet.scope.source] = lane
            reply(.accepted)
            event(packet.scope.source,.admitted(packetSequence: packet.sequence,sampleEnd: lane.end),send: send)
            event(packet.scope.source,.progress(.init(capturedSampleEnd: lane.end,admittedSampleEnd: lane.end,consumedSampleEnd: lane.end,
                queuedSamples: 0,inFlightSamples: 0,heldSamples: 0,creditSamples: Int64(begin.configuration.pendingSampleLimit))),send: send)
            event(packet.scope.source,.partial(.init(epochID: lane.epoch.id,source: packet.scope.source,revision: lane.packet,
                samples: .init(start: lane.settled,end: lane.end),text: "Fixture partial")),send: send)
        case .barrier(let barrier):
            guard let begin, barrier.scope.identity == begin.identity, var lane = lanes[barrier.scope.source], lane.epoch.id == barrier.scope.epochID,
                  barrier.sampleEnd == lane.end, barrier.nextPacketSequence == lane.packet else { reply(.rejected(.outOfOrder)); return }
            reply(.accepted)
            if mode == "live-unresponsive-finish" { return }
            if lane.end > lane.settled {
                event(barrier.scope.source,.committed(.init(id: .init(epochID: lane.epoch.id,index: lane.segment),source: barrier.scope.source,
                    range: .init(samples: .init(start: lane.settled,end: lane.end),meeting: nil),text: "Fixture tail")),send: send)
                lane.segment += 1; lane.settled = lane.end
            }
            // Retain the event counter advanced by event() above.
            lane.event = lanes[barrier.scope.source]!.event; lanes[barrier.scope.source] = lane
            event(barrier.scope.source,.barrierCompleted(requestID: envelope.id,kind: barrier.kind,sampleEnd: lane.end),send: send)
            if barrier.kind == .finish {
                lanes[barrier.scope.source]?.closed = true
                event(barrier.scope.source,.closed(sampleEnd: lane.end),send: send)
                if lanes.values.allSatisfy(\.closed) { send(.init(id: streamID!,channel: .live,event: .live(.event(.finished(begin.identity))))) }
            }
        case .cancel(let identity):
            guard begin?.identity == identity else { reply(.rejected(.staleScope)); return }
            if mode == "live-terminal-before-ack" {
                send(.init(id: streamID!,channel: .live,event: .live(.event(.finished(identity))))); reply(.accepted)
            } else { reply(.accepted); send(.init(id: streamID!,channel: .live,event: .live(.event(.finished(identity))))) }
        case .replaceEpoch(let identity, let old, let epoch):
            guard begin?.identity == identity, lanes[epoch.source]?.epoch.id == old else { reply(.rejected(.staleScope)); return }
            reply(.accepted); lanes[epoch.source] = Lane(epoch: epoch); event(epoch.source,.ready(generation: UUID(),originSample: 0),send: send)
        case .cut(let scope, let next, let end, let reason):
            guard begin?.identity == scope.identity, var lane = lanes[scope.source], lane.epoch.id == scope.epochID, end >= lane.end else { reply(.rejected(.staleScope)); return }
            reply(.accepted)
            if end > lane.settled { event(scope.source,.settled(.init(epochID: lane.epoch.id,source: scope.source,
                range: .init(samples: .init(start: lane.settled,end: end),meeting: nil),kind: .gap(reason))),send: send) }
            lane.event = lanes[scope.source]!.event; lane.end = end; lane.settled = end; lane.packet = next; lanes[scope.source] = lane
            event(scope.source,.needsEpochReplacement,send: send)
        }
    }
}
