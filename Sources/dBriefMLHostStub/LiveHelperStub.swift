import Foundation
import dBriefWire

/// Deterministic, model-free scenarios for the dedicated connection.
struct LiveHelperStub {
    private struct Lane { let epoch: LiveEpoch; var end: Int64 = 0; var settled: Int64 = 0; var packet: UInt64 = 0; var event: UInt64 = 0; var segment: UInt64 = 0; var closed = false }
    let mode: String
    private var begin: LiveSessionBegin?
    private var streamID: UUID?
    private var lanes: [LiveSource: Lane] = [:]
    private var barrierCount = 0
    private var delayedBarrier: (UUID, LiveFinishBarrier)?
    private var awaitingRetiredReply: UUID?
    private var optionalPrepared = false, optionalRetired = false
    private var optionalContext = UUID(), optionalSequence: UInt64 = 0, optionalOrigin: Int64 = 0
    private var optionalAcknowledged = false, optionalRowsSent = false, optionalRetirePending = false
    private var captureAttributionMode: Bool { mode.hasPrefix("live-capture-attribution") }
    private mutating func captureOptionalProgress() {
        guard captureAttributionMode, let lane = lanes[.system], optionalPrepared else { return }
        if optionalRetirePending, let flag = ProcessInfo.processInfo.environment["STUB_FLAG_2"],
           FileManager.default.fileExists(atPath: flag), !optionalRetired {
            optionalRetired = true; optionalEvent(.retired(contextID: optionalContext,receiptID: UUID(),reason: .pressure))
        }
        guard optionalAcknowledged, !optionalRowsSent, !optionalRetired, lane.end >= optionalOrigin + 320 else { return }
        optionalRowsSent = true
        let rows = (0..<2).map { i in
            let first = Int64(i * 160), last = first + 160
            let samples = LiveSampleRange(start: optionalOrigin + first,end: optionalOrigin + last)
            let meeting = lane.epoch.meetingOriginNanoseconds.map { LiveMeetingRange(startNanoseconds: $0 + samples.start * 62_500,endNanoseconds: $0 + samples.end * 62_500) }
            return try! LiveDiarizationRow(streamSamples: .init(start: first,end: last),samples: samples,meeting: meeting,activity: [Float](repeating: 0.7,count: 8))
        }
        optionalEvent(.posterior(contextID: optionalContext,rows: rows))
    }
    private var optionalPrepareAttempts = 0
    init(mode: String) { self.mode = mode }
    private mutating func event(_ source: LiveSource, _ payload: LiveLaneEvent.Payload, send: (EventEnvelope) -> Void) {
        guard let begin, let id = streamID, let lane = lanes[source] else { return }
        lanes[source]?.event += 1
        send(.init(id: id,channel: .live,event: .live(.event(.lane(.init(scope: .init(identity: begin.identity,source: source,epochID: lane.epoch.id),sequence: lane.event,payload: payload))))))
    }
    private func optionalEnvelope(_ envelope: EventEnvelope) {
        guard let body = try? JSONEncoder().encode(envelope), let framed = try? LiveOutputDemultiplexer.tag(body) else { exit(7) }
        FileHandle.standardOutput.write(framed)
    }
    private mutating func optionalEvent(_ payload: LiveDiarizationEvent.Payload, epochID: UUID? = nil) {
        guard let begin, let frozen = begin.diarization, let id = streamID, let lane = lanes[.system] else { return }
        let owner = mode == "live-duplex-foreign" ? UUID() : frozen.ownerID
        let event = LiveDiarizationEvent(scope: .init(identity: begin.identity, source: .system, epochID: mode == "live-duplex-foreign-epoch" ? UUID() : (epochID ?? lane.epoch.id)),
            ownerID: owner, sequence: mode == "live-duplex-bad-sequence" ? optionalSequence + 1 : optionalSequence, payload: payload)
        optionalSequence += 1
        optionalEnvelope(.init(id: id, channel: .live, event: .live(.event(.diarization(event)))))
    }
    private mutating func optionalControl(_ control: LiveDiarizationControl, id: UUID) {
        func reply(_ result: LiveSessionReply) {
            if mode != "live-duplex-no-reply" { optionalEnvelope(.init(id: id, channel: .live, event: .live(.reply(result)))) }
        }
        guard let begin, let frozen = begin.diarization, control.identity == begin.identity, control.ownerID == frozen.ownerID else { reply(.rejected(.staleScope)); return }
        switch control.payload {
        case .prepare(let epoch):
            optionalPrepareAttempts += 1
            if let flag = ProcessInfo.processInfo.environment["STUB_FLAG_1"] { try? Data(String(optionalPrepareAttempts).utf8).write(to: URL(fileURLWithPath: flag)) }
            guard !optionalPrepared, let lane = lanes[.system], lane.epoch.id == epoch else { reply(.rejected(.staleScope)); return }
            optionalPrepared = true; optionalOrigin = lane.end; reply(.accepted)
            if mode == "live-duplex-bad-body" {
                FileHandle.standardOutput.write(try! LiveOutputDemultiplexer.tag(Data(repeating: 0x42, count: 508))); return
            }
            optionalEvent(.preparing); optionalEvent(.ready(originSample: optionalOrigin, contextID: optionalContext))
        case .acknowledge(let context):
            guard optionalPrepared, !optionalRetired, context == optionalContext else { reply(.rejected(.staleScope)); return }
            reply(.accepted)
            if captureAttributionMode { optionalAcknowledged = true; captureOptionalProgress(); return }
            let start = lanes[.system]!.epoch.meetingOriginNanoseconds
            let batches = mode == "live-duplex-event-overflow" ? 5 : 1
            for batch in 0..<batches {
                var rows: [LiveDiarizationRow] = []
                for i in (batch * 2)..<(batch * 2 + 2) {
                    let streamStart = Int64(i * 160), streamEnd = Int64((i + 1) * 160)
                    let samples = LiveSampleRange(start: optionalOrigin + streamStart, end: optionalOrigin + streamEnd)
                    let meeting: LiveMeetingRange?
                    if let start {
                        meeting = .init(startNanoseconds: start + samples.start * 62_500, endNanoseconds: start + samples.end * 62_500)
                    } else { meeting = nil }
                    rows.append(try! .init(streamSamples: .init(start: streamStart, end: streamEnd), samples: samples,
                        meeting: meeting, activity: [Float](repeating: 0.7, count: 8)))
                }
                optionalEvent(.posterior(contextID: context, rows: rows))
            }
        case .acknowledgePosterior(let context, let sequence):
            reply(context == optionalContext && sequence == 2 ? .accepted : .rejected(.outOfOrder))
        case .retire:
            guard optionalPrepared else { reply(.rejected(.staleScope)); return }; reply(.accepted)
            if mode == "live-capture-attribution-held-retirement" { optionalRetirePending = true; captureOptionalProgress(); return }
            if mode == "live-duplex-no-reply" { return }
            if mode == "live-duplex-held-retirement", let flag = ProcessInfo.processInfo.environment["STUB_FLAG_2"],
               !FileManager.default.fileExists(atPath: flag) { return }
            if !optionalRetired {
                optionalRetired = true; optionalEvent(.retired(contextID: optionalContext, receiptID: UUID(), reason: .pressure))
            }
        }
    }

    mutating func handle(_ envelope: RequestEnvelope, send: (EventEnvelope) -> Void) {
        func reply(_ reply: LiveSessionReply, terminal: Bool = true) {
            send(.init(id: envelope.id,channel: .live,event: .live(.reply(reply))))
            if terminal { send(.init(id: envelope.id,channel: .live,event: .finished)) }
        }
        guard CommandLine.arguments.contains("--nemotron-live"), case .live(let request) = envelope.request else { reply(.rejected(.unsupportedRole)); return }
        switch request {
        case .diarizationControl(let control):
            optionalControl(control, id: envelope.id)
        case .prepareDiarization, .acknowledgeDiarization, .acknowledgeDiarizationPosterior, .retireDiarization:
            optionalEnvelope(.init(id: envelope.id, channel: .live, event: .live(.reply(.rejected(.unavailable)))))
        case .begin(let begin):
            guard self.begin == nil, begin.isValid else { reply(.rejected(.invalidConfiguration)); return }
            guard begin.vad == nil else { reply(.rejected(.unavailable)); return }
            self.begin = begin; streamID = envelope.id
            reply(.accepted,terminal: false)
            if mode == "live-optional-flood" {
                // Test-only malformed optional JSON must be stripped before the
                // mandatory raw handoff/decoder, even while ingest is held.
                let frame = try! LiveOutputDemultiplexer.tag(Data(repeating: 0x42, count: 508))
                for _ in 0..<512 { FileHandle.standardOutput.write(frame) }
                if let flag = ProcessInfo.processInfo.environment["STUB_FLAG_1"] { try? Data().write(to: URL(fileURLWithPath: flag)) }
            }
            if mode == "live-init-failure" { send(.init(id: envelope.id,channel: .live,event: .live(.event(.failed(begin.identity,.unavailable))))); return }
            if mode == "live-oversized" { FileHandle.standardOutput.write(Data([0,1,0,1])); return }
            for epoch in begin.epochs {
                lanes[epoch.source] = Lane(epoch: epoch)
                if mode == "live-wrong-scope" {
                    send(.init(id: envelope.id,channel: .live,event: .live(.event(.finished(.init(recordingID: UUID(),captureSessionID: begin.identity.captureSessionID)))))); return
                }
                event(epoch.source,.ready(generation: UUID(),originSample: 0),send: send)
                if mode == "live-unsolicited-barrier" {
                    event(epoch.source,.barrierCompleted(requestID: UUID(),kind: .pause,sampleEnd: 0),send: send)
                }
            }
            if mode == "live-duplex-input-stall" {
                if let flag = ProcessInfo.processInfo.environment["STUB_FLAG_2"] { try? Data().write(to: URL(fileURLWithPath: flag)) }
                Thread.sleep(forTimeInterval: 10)
            }
            if mode == "live-read-stall" { Thread.sleep(forTimeInterval: 10) }
        case .packet(let packet):
            if mode == "live-crash" { exit(9) }
            guard let begin, packet.scope.identity == begin.identity, var lane = lanes[packet.scope.source], lane.epoch.id == packet.scope.epochID,
                  packet.sequence == lane.packet, packet.startSample == lane.end, (try? packet.decodedSamples()) != nil else { reply(.rejected(.invalidPacket)); return }
            lane.packet += 1; lane.end += Int64(packet.sampleCount); lanes[packet.scope.source] = lane
            if packet.scope.source == .system { captureOptionalProgress() }
            reply(.accepted)
            event(packet.scope.source,.admitted(packetSequence: packet.sequence,sampleEnd: lane.end),send: send)
            event(packet.scope.source,.progress(.init(capturedSampleEnd: lane.end,admittedSampleEnd: lane.end,consumedSampleEnd: lane.end,
                queuedSamples: 0,inFlightSamples: 0,heldSamples: 0,creditSamples: Int64(begin.configuration.pendingSampleLimit))),send: send)
            event(packet.scope.source,.partial(.init(epochID: lane.epoch.id,source: packet.scope.source,revision: lane.packet,
                samples: .init(start: lane.settled,end: lane.end),text: "Fixture partial")),send: send)
        case .barrier(let barrier):
            guard let begin, barrier.scope.identity == begin.identity, var lane = lanes[barrier.scope.source], lane.epoch.id == barrier.scope.epochID,
                  barrier.sampleEnd == lane.end, barrier.nextPacketSequence == lane.packet else { reply(.rejected(.outOfOrder)); return }
            barrierCount += 1
            if mode == "live-terminal-admission-gate", barrierCount == 1 {
                delayedBarrier = (envelope.id,barrier)
                event(barrier.scope.source,.progress(.init(capturedSampleEnd: 0,admittedSampleEnd: 0,consumedSampleEnd: 0,queuedSamples: 0,inFlightSamples: 0,heldSamples: 0,creditSamples: Int64(begin.configuration.pendingSampleLimit))),send: send)
                return
            }
            if mode.hasPrefix("live-retire-before-old-reply-"), barrierCount == 1 {
                awaitingRetiredReply = envelope.id
                event(barrier.scope.source,.barrierCompleted(requestID: envelope.id,kind: barrier.kind,sampleEnd: lane.end),send: send)
                event(.system,.progress(.init(capturedSampleEnd: 0,admittedSampleEnd: 0,consumedSampleEnd: 0,queuedSamples: 0,inFlightSamples: 0,heldSamples: 0,creditSamples: Int64(begin.configuration.pendingSampleLimit))),send: send)
                return
            }
            if mode == "live-reject-first-barrier", barrierCount == 1 { reply(.rejected(.unavailable)); return }
            if ["live-late-barrier-after-cut","live-retired-epoch-frames","live-old-id-new-epoch"].contains(mode), barrierCount == 1 {
                delayedBarrier = (envelope.id,barrier); reply(.accepted); return
            }
            if mode == "live-completion-after-rejection" {
                reply(.rejected(.unavailable))
                event(barrier.scope.source,.barrierCompleted(requestID: envelope.id,kind: barrier.kind,sampleEnd: lane.end),send: send)
                return
            }
            let completionFirst = ["live-barrier-before-reply","live-rejected-after-completion","live-needs-before-barrier-reply","live-barrier-buffer-overflow","live-evidence-after-held-terminal","live-double-terminal-before-reply"].contains(mode)
            if !completionFirst { reply(.accepted) }
            if mode == "live-double-terminal-before-reply" {
                send(.init(id: streamID!,channel: .live,event: .live(.event(.finished(begin.identity)))))
                send(.init(id: streamID!,channel: .live,event: .live(.event(.failed(begin.identity,.unavailable)))))
                reply(.accepted); return
            }
            if mode == "live-unresponsive-finish" { return }
            if lane.end > lane.settled {
                event(barrier.scope.source,.committed(.init(id: .init(epochID: lane.epoch.id,index: lane.segment),source: barrier.scope.source,
                    range: .init(samples: .init(start: lane.settled,end: lane.end),meeting: nil),text: "Fixture tail",
                    diarizerContextID: captureAttributionMode && barrier.scope.source == .system && optionalAcknowledged && lane.settled >= optionalOrigin ? optionalContext : nil)),send: send)
                lane.segment += 1; lane.settled = lane.end
            }
            // Retain the event counter advanced by event() above.
            lane.event = lanes[barrier.scope.source]!.event; lanes[barrier.scope.source] = lane
            if mode == "live-needs-before-barrier-reply" { event(barrier.scope.source,.needsEpochReplacement,send: send) }
            let ackID = mode == "live-wrong-barrier-id" ? UUID() : envelope.id
            let ackKind = mode == "live-wrong-barrier-kind" ? LiveFinishBarrier.Kind.utterance : barrier.kind
            let ackEnd = mode == "live-wrong-barrier-end" ? lane.end + 1 : lane.end
            event(barrier.scope.source,.barrierCompleted(requestID: ackID,kind: ackKind,sampleEnd: ackEnd),send: send)
            if mode == "live-duplicate-barrier" {
                event(barrier.scope.source,.barrierCompleted(requestID: envelope.id,kind: barrier.kind,sampleEnd: lane.end),send: send)
            }
            if mode == "live-barrier-buffer-overflow" {
                for _ in 0..<16 { event(barrier.scope.source,.ready(generation: UUID(),originSample: lane.end),send: send) }
            }
            if mode == "live-evidence-after-held-terminal" {
                send(.init(id: streamID!,channel: .live,event: .live(.event(.finished(begin.identity)))))
                event(barrier.scope.source,.ready(generation: UUID(),originSample: lane.end),send: send)
            }
            if barrier.kind == .finish {
                lanes[barrier.scope.source]?.closed = true
                event(barrier.scope.source,.closed(sampleEnd: lane.end),send: send)
                if lanes.values.allSatisfy(\.closed) { send(.init(id: streamID!,channel: .live,event: .live(.event(.finished(begin.identity))))) }
            }
            if completionFirst { reply(mode == "live-rejected-after-completion" ? .rejected(.unavailable) : .accepted) }
        case .cancel(let identity):
            guard begin?.identity == identity else { reply(.rejected(.staleScope)); return }
            if mode == "live-duplex-malformed" {
                let frame = try! LiveOutputDemultiplexer.tag(Data(repeating: 0x42, count: 508))
                for _ in 0..<512 { FileHandle.standardOutput.write(frame) }
            }
            if mode == "live-terminal-admission-gate", let (id,barrier) = delayedBarrier {
                delayedBarrier = nil
                event(barrier.scope.source,.barrierCompleted(requestID: id,kind: barrier.kind,sampleEnd: barrier.sampleEnd),send: send)
                send(.init(id: streamID!,channel: .live,event: .live(.event(.finished(identity)))))
                // This preexisting command reply proves terminal ingestion to
                // the caller while the earlier barrier reply is still held.
                reply(.accepted)
                if let path = ProcessInfo.processInfo.environment["STUB_FLAG_1"] {
                    for _ in 0..<2000 {
                        if FileManager.default.fileExists(atPath: path) { break }
                        Thread.sleep(forTimeInterval: 0.005)
                    }
                }
                send(.init(id: id,channel: .live,event: .live(.reply(.accepted))))
                send(.init(id: id,channel: .live,event: .finished))
                return
            }
            if mode == "live-terminal-before-ack" {
                send(.init(id: streamID!,channel: .live,event: .live(.event(.finished(identity))))); reply(.accepted)
            } else { reply(.accepted); send(.init(id: streamID!,channel: .live,event: .live(.event(.finished(identity))))) }
        case .replaceEpoch(let identity, let old, let epoch):
            guard begin?.identity == identity, lanes[epoch.source]?.epoch.id == old else { reply(.rejected(.staleScope)); return }
            if mode == "live-duplex-reject-before-open" { reply(.rejected(.unavailable)); return }
            let oldLane = lanes[epoch.source]!
            if optionalPrepared, mode == "live-duplex-retire-on-replacement" || mode == "live-duplex-reject-replacement" {
                optionalEvent(.retired(contextID: optionalContext, receiptID: UUID(), reason: .pressure), epochID: epoch.id)
                optionalRetired = true
                if let flag = ProcessInfo.processInfo.environment["STUB_FLAG_2"] { try? Data().write(to: URL(fileURLWithPath: flag)) }
                if mode == "live-duplex-reject-replacement" { reply(.rejected(.unavailable)); return }
            }
            reply(.accepted); lanes[epoch.source] = Lane(epoch: epoch); event(epoch.source,.ready(generation: UUID(),originSample: 0),send: send)
            if let id = awaitingRetiredReply {
                awaitingRetiredReply = nil
                let value = mode.hasSuffix("accepted") ? LiveSessionReply.accepted : .rejected(.unavailable)
                send(.init(id: id,channel: .live,event: .live(.reply(value))))
                send(.init(id: id,channel: .live,event: .finished))
            }
            if let (id,barrier) = delayedBarrier {
                delayedBarrier = nil
                if mode == "live-old-id-new-epoch" {
                    event(epoch.source,.barrierCompleted(requestID: id,kind: barrier.kind,sampleEnd: barrier.sampleEnd),send: send)
                } else if mode == "live-retired-epoch-frames", let streamID {
                    for (offset,payload) in [LiveLaneEvent.Payload.barrierCompleted(requestID: id,kind: barrier.kind,sampleEnd: barrier.sampleEnd), .ready(generation: UUID(),originSample: barrier.sampleEnd)].enumerated() {
                        send(.init(id: streamID,channel: .live,event: .live(.event(.lane(.init(scope: barrier.scope,sequence: oldLane.event + UInt64(offset),payload: payload))))))
                    }
                }
            }
        case .cut(let scope, let next, let end, let reason):
            guard begin?.identity == scope.identity, var lane = lanes[scope.source], lane.epoch.id == scope.epochID, end >= lane.end else { reply(.rejected(.staleScope)); return }
            reply(.accepted)
            if end > lane.settled { event(scope.source,.settled(.init(epochID: lane.epoch.id,source: scope.source,
                range: .init(samples: .init(start: lane.settled,end: end),meeting: nil),kind: .gap(reason))),send: send) }
            lane.event = lanes[scope.source]!.event; lane.end = end; lane.settled = end; lane.packet = next; lanes[scope.source] = lane
            event(scope.source,.needsEpochReplacement,send: send)
            if mode == "live-late-barrier-after-cut", let (id,barrier) = delayedBarrier {
                delayedBarrier = nil
                event(scope.source,.barrierCompleted(requestID: id,kind: barrier.kind,sampleEnd: barrier.sampleEnd),send: send)
            }
        }
    }
}
