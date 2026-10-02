import Foundation
import Testing
import dBriefWire

@Suite struct LiveSessionProtocolTests {
    let identity = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
    var scope: LiveLaneScope { .init(identity: identity, source: .microphone, epochID: UUID()) }
    @Test func packetsRoundTripExactLittleEndianSamples() throws {
        let packet = try LiveAudioPacket(scope: scope, sequence: 8, startSample: 123, samples: [1, -0.5, Float.leastNormalMagnitude])
        let reloaded = try JSONDecoder().decode(LiveAudioPacket.self, from: JSONEncoder().encode(packet))
        #expect(reloaded == packet)
        #expect(try reloaded.decodedSamples() == [1, -0.5, Float.leastNormalMagnitude])
        #expect(packet.pcm.prefix(4) == Data([0, 0, 128, 63]))
    }
    @Test func invalidPacketsRejectBeforeAdmission() throws {
        for samples: [Float] in [[], [.nan], [.infinity], Array(repeating: 0, count: 3201)] {
            #expect(throws: LiveProtocolError.invalidPacket) { try LiveAudioPacket(scope: scope, sequence: 0, startSample: 0, samples: samples) }
        }
        for packet in [LiveAudioPacket(scope: scope, sequence: 0, startSample: -1, sampleCount: 1, pcm: Data(count: 4)),
            .init(scope: scope, sequence: .max, startSample: 0, sampleCount: 1, pcm: Data(count: 4)),
            .init(scope: scope, sequence: 0, startSample: .max, sampleCount: 1, pcm: Data(count: 4)),
            .init(scope: scope, sequence: 0, startSample: 0, sampleCount: 2, pcm: Data(count: 4))] {
            #expect(throws: LiveProtocolError.invalidPacket) { try packet.decodedSamples() }
        }
    }
    @Test func configurationAndLaneScopeAreBounded() {
        for tier in [560,1120,2240] {
            let config = LiveASRConfiguration(language: .nl, chunkMs: tier, modelDirectory: "/private/models")
            #expect(config.isValid && config.pendingSampleLimit >= config.chunkSamples + 3200)
            let epoch = LiveEpoch(id: UUID(), source: .system, engineRevision: "nemotron", language: "nl", meetingOriginNanoseconds: nil)
            #expect(LiveSessionBegin(identity: identity, configuration: config, epochs: [epoch]).isValid)
            #expect(!LiveSessionBegin(identity: identity, configuration: config, epochs: [epoch,epoch]).isValid)
            #expect(!LiveSessionBegin(identity: identity, configuration: config, epochs: []).isValid)
        }
        #expect(!LiveASRConfiguration(language: .auto, chunkMs: .max, modelDirectory: "/private/models").isValid)
        #expect(!LiveASRConfiguration(language: .en, modelDirectory: "relative").isValid)
    }
    @Test func liveReaderRejectsOversizedPrefixWithoutRetainingPayload() throws {
        var reader = LiveFrameReader()
        #expect(throws: LiveProtocolError.oversizedFrame) { try reader.feed(Data([0,1,0,1])) }
        #expect(reader.bufferedBytes <= 4)
    }
    @Test func readerHandlesFragmentationAndMultipleMaximumFrames() throws {
        var reader = LiveFrameReader(), frames: [Data] = []
        let value = Data(repeating: 42, count: LiveFrameReader.maximumFrameBytes)
        let batch = FrameCodec.encode(value) + FrameCodec.encode(value)
        for byte in batch.prefix(3) { frames += try reader.feed(Data([byte])) }
        frames += try reader.feed(batch.dropFirst(3))
        #expect(frames == [value,value] && reader.bufferedBytes == 0)
    }
}
