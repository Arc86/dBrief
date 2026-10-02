import AVFoundation
import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite struct LiveCaptureSourceMailboxTests {
    private struct Fixture {
        let input: LiveSessionBegin
        let rawEpoch = UUID()
        init() {
            let identity = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
            input = .init(identity: identity,configuration: .init(language: .auto,modelDirectory: "/fixture"),epochs: [
                .init(id: UUID(),source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)])
        }
        func buffer(_ pool: LiveCaptureIngress, start: Int) throws -> LiveAudioBuffer {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000,channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 16)); buffer.frameLength = 16
            for i in 0..<16 { buffer.floatChannelData![0][i] = Float(start) }
            let metadata = LiveAudioMetadata(sourceEpoch: rawEpoch,role: .mic,timestamp: .unavailable,
                emittedFrames: .init(startFrame: Int64(start),frameCount: 16,sampleRate: 16000),writeOutcome: .failed,converter: nil)
            let raw = try #require(pool.reserveRaw(source: .microphone,metadata: metadata,frames: 16,rate: 16000,bytes: 64,format: format))
            return .init(buffer,metadata: metadata,ingress: raw)
        }
    }

    @Test func sixtyFourOriginalReceiptsAndOneCoalescedWakeRemainBoundedUntilActualRelease() async throws {
        let f = Fixture(), pool = LiveCaptureIngress(input: f.input)
        let mailbox = try LiveCaptureSourceMailbox(ingress: pool,source: .microphone)
        var items: [LiveAudioBuffer] = []
        mailbox.wake()
        for index in 0..<64 {
            let item = try f.buffer(pool,start: index*16); items.append(item)
            #expect(mailbox.offer(item))
            mailbox.wake()
        }
        #expect(!mailbox.offer(items[0]))
        let scope = LiveLaneScope(identity: f.input.identity,source: .microphone,epochID: f.input.epochs[0].id)
        #expect(pool.continuityLoss(scope: scope) == nil)
        mailbox.finish()
        #expect(!mailbox.offer(items[0]))
        #expect(pool.isPendingRaw(try #require(items[0].ingress)))
        #expect(pool.continuityLoss(scope: scope) == nil)
        var wakes = 0, receipts: [UUID] = []
        for await event in mailbox.events {
            switch event {
            case .wake: wakes += 1; mailbox.consumedWake()
            case .audio(let item):
                let raw = try #require(item.ingress)
                receipts.append(raw.id); raw.discard(reason: .stopped); mailbox.completedAudio(raw.id)
            }
        }
        #expect(wakes == 1 && receipts == items.compactMap { $0.ingress?.id })
        #expect(pool.statistics(.microphone).rawBytes == 4096)
        items.removeAll()
        #expect(pool.statistics(.microphone).rawBytes == 0)
    }

    @Test func foreignAndClosedOffersCannotAffectAnotherCaptureAndIdleWakeNeedsNoAudio() async throws {
        let f = Fixture(), pool = LiveCaptureIngress(input: f.input), other = LiveCaptureIngress(input: f.input)
        let mailbox = try LiveCaptureSourceMailbox(ingress: pool,source: .microphone)
        let foreign = try f.buffer(other,start: 0)
        #expect(!mailbox.offer(foreign))
        #expect(other.statistics(.microphone).pendingSamples == 4112 && other.takeLosses(.microphone).isEmpty)
        mailbox.wake(); mailbox.wake(); mailbox.finish(); mailbox.wake()
        var wakes = 0, audio = 0
        for await event in mailbox.events {
            switch event { case .wake: wakes += 1; case .audio: audio += 1 }
        }
        #expect(wakes == 1 && audio == 0)
        let late = try f.buffer(pool,start: 0)
        #expect(!mailbox.offer(late))
        #expect(pool.takeLosses(.microphone).contains { $0.reason == .stopped })
        #expect(pool.statistics(.microphone).rawBytes == 64)
    }
}
