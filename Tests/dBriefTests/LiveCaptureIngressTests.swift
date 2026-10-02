import AVFoundation
import CoreMedia
import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite struct LiveCaptureIngressTests {
    @Test func discardedRawCreditCannotFreeAllocationBytesBeforeItsLastReceiptDies() throws {
        let f = Fixture(), pool = LiveCaptureIngress(input: f.input(),rawByteLimit: 64)
        var ticket = f.reserve(pool,count: 16)
        try #require(ticket != nil)
        var alias = ticket
        ticket?.discard(reason: .overload)
        #expect(pool.statistics(.microphone).pendingSamples == 4096)
        #expect(pool.statistics(.microphone).rawBytes == 64)
        #expect(pool.takeLosses(.microphone).count == 1)
        ticket = nil
        withExtendedLifetime(alias) { #expect(pool.statistics(.microphone).rawBytes == 64) }
        alias = nil
        #expect(pool.statistics(.microphone).rawBytes == 0)
        #expect(pool.takeLosses(.microphone).isEmpty)
    }
    @Test func microphoneAndSystemWritesSurviveLiveRawBudgetOverload() async throws {
        for source in [LiveSource.microphone,.system] {
            let identity = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
            let epoch = LiveEpoch(id: UUID(),source: source,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
            let budget = LiveCaptureIngress(input: .init(identity: identity,configuration: .init(language: .auto,modelDirectory: "/fixture"),epochs: [epoch]),rawByteLimit: 64)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ingress-writer-\(UUID()).caf")
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = AudioTrackWriter(url: url,role: source == .microphone ? .mic : .system)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000,channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 16))
            buffer.frameLength = 16
            for index in 0..<16 { buffer.floatChannelData![0][index] = 0.25 }
            let (stream,output) = AsyncStream<LiveAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
            if source == .microphone {
                let sink = MicCaptureSink(writer: writer,liveSink: output,liveIngress: budget)
                sink.receive(buffer); sink.receive(buffer); sink.finish()
            } else {
                let sink = SystemCaptureSink(writer: writer,liveSink: output,liveIngress: budget)
                sink.receive(buffer,presentationTime: .zero)
                sink.receive(buffer,presentationTime: CMTime(value: 16,timescale: 16000))
            }
            output.finish(); writer.close()
            var count = 0
            for await item in stream {
                count += 1
                #expect(item.ingress?.owner === budget)
            }
            #expect(count == 1)
            #expect(try AVAudioFile(forReading: url).length == 32)
            #expect(writer.diagnostics.framesWritten == 32 && writer.diagnostics.writeErrors == 0)
            #expect(budget.takeLosses(source).contains { $0.frames?.startFrame == 16 && $0.frames?.frameCount == 16 && $0.reason == .overload })
        }
    }

    private struct Fixture {
        let identity = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
        let rawEpoch = UUID()
        let epoch = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        func input(_ tier: Int = 1120) -> LiveSessionBegin {
            .init(identity: identity,configuration: .init(language: .auto,chunkMs: tier,modelDirectory: "/fixture"),epochs: [epoch])
        }
        var scope: LiveLaneScope { .init(identity: identity,source: epoch.source,epochID: epoch.id) }
        func metadata(_ start: Int = 0, count: Int, rate: Double = 16000) -> LiveAudioMetadata {
            .init(sourceEpoch: rawEpoch,role: .mic,timestamp: .unavailable,
                emittedFrames: .init(startFrame: Int64(start),frameCount: Int64(count),sampleRate: rate),writeOutcome: .failed,converter: nil)
        }
        func reserve(_ budget: LiveCaptureIngress, count: Int, start: Int = 0, rate: Double = 16000) -> LiveCaptureIngress.RawReservation? {
            budget.reserveRaw(source: .microphone,metadata: metadata(start,count: count,rate: rate),frames: count,rate: rate,bytes: count * 4)
        }
    }

    @Test(arguments: [560,1120,2240]) func rawAndAppNativeOwnershipShareOneFiniteBudget(tier: Int) throws {
        let f = Fixture(), budget = LiveCaptureIngress(input: f.input(tier)), limit = f.input(tier).configuration.pendingSampleLimit
        let count = limit - 4096
        let raw = try #require(f.reserve(budget,count: count))
        #expect(budget.statistics(.microphone).pendingSamples == limit)
        let normalized = try #require(budget.normalize(raw,scope: f.scope,emittedSamples: count))
        #expect(budget.statistics(.microphone).pendingSamples == limit)
        #expect(budget.schedule(normalized,start: 0,count: count))
        #expect(budget.markDispatched(scope: f.scope,end: Int64(count)))
        #expect(budget.statistics(.microphone).nativeSamples == count)
        #expect(f.reserve(budget,count: 1,start: count) == nil)
        #expect(f.reserve(budget,count: 1,start: count + 1) == nil)
        #expect(budget.consume(scope: f.scope,end: 100))
        let next = try #require(f.reserve(budget,count: 100,start: count + 2))
        withExtendedLifetime(next) { #expect(budget.statistics(.microphone).pendingSamples == limit) }
        #expect(!budget.consume(scope: f.scope,end: Int64(count + 1)))
    }

    @Test func lossLatchOutlivesEvidenceDrainAndOldRawDisposalCannotCutAcceptedReplacement() throws {
        let f = Fixture(), pool = LiveCaptureIngress(input: f.input())
        var old = f.reserve(pool,count: 100)
        try #require(old != nil)
        pool.recordLoss(source: .microphone,metadata: f.metadata(100,count: 100),reason: .unavailable)
        #expect(pool.takeLosses(.microphone).count == 1)
        #expect(pool.continuityLoss(scope: f.scope) == .unavailable)
        let next = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        #expect(pool.replaceEpoch(old: f.scope,new: next))
        let scope = LiveLaneScope(identity: f.identity,source: .microphone,epochID: next.id)
        old?.discard(reason: .overload); old = nil
        #expect(pool.continuityLoss(scope: scope) == nil)
        let raw = try #require(f.reserve(pool,count: 100,start: 200))
        let normalized = try #require(pool.normalize(raw,scope: scope,emittedSamples: 100))
        pool.recordLoss(source: .microphone,metadata: f.metadata(300,count: 100),reason: .unavailable)
        #expect(!pool.schedule(normalized,start: 0,count: 100))
        #expect(pool.statistics(.microphone).nativeSamples == 0)
        #expect(normalized.contains(100))
    }

    @Test func cutsFreeOnlyUndispatchedInputUntilTheMatchingNativeReplacementReceipt() throws {
        let f = Fixture(), budget = LiveCaptureIngress(input: f.input())
        let raw = try #require(f.reserve(budget,count: 200))
        let normalized = try #require(budget.normalize(raw,scope: f.scope,emittedSamples: 200))
        #expect(budget.schedule(normalized,start: 0,count: 100))
        #expect(budget.markDispatched(scope: f.scope,end: 100))
        #expect(budget.schedule(normalized,start: 100,count: 100))
        budget.discardUndispatched(scope: f.scope)
        #expect(budget.statistics(.microphone).nativeSamples == 100)
        let other = LiveLaneScope(identity: f.identity,source: .microphone,epochID: UUID())
        let next = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        #expect(!budget.replaceEpoch(old: other,new: next))
        #expect(budget.statistics(.microphone).nativeSamples == 100)
        #expect(budget.replaceEpoch(old: f.scope,new: next))
        #expect(budget.statistics(.microphone).nativeSamples == 0)
        #expect(!budget.consume(scope: f.scope,end: 100))
    }

    @Test func droppedRawOwnershipRecordsOnlyItsActualFrameInterval() throws {
        let f = Fixture(), budget = LiveCaptureIngress(input: f.input())
        do {
            let raw = try #require(f.reserve(budget,count: 4410,start: 4410,rate: 44100))
            withExtendedLifetime(raw) { #expect(budget.statistics(.microphone).rawBytes == 17640) }
        }
        #expect(budget.statistics(.microphone).rawBytes == 0)
        let losses = budget.takeLosses(.microphone)
        #expect(losses.count == 1)
        #expect(losses.first?.sourceEpoch == f.rawEpoch)
        #expect(losses.first?.frames == .init(startFrame: 4410,frameCount: 4410,sampleRate: 44100))
        #expect(losses.first?.reason == .overload)
        #expect(budget.takeLosses(.microphone).isEmpty)
    }

    @Test func unclaimedNormalizedDestructionCannotReleaseNativeHeldAudio() throws {
        let f = Fixture(), budget = LiveCaptureIngress(input: f.input())
        do {
            let raw = try #require(f.reserve(budget,count: 1000))
            let normalized = try #require(budget.normalize(raw,scope: f.scope,emittedSamples: 1000))
            #expect(budget.schedule(normalized,start: 0,count: 400))
            #expect(budget.markDispatched(scope: f.scope,end: 400))
        }
        #expect(budget.statistics(.microphone).pendingSamples == 4096 + 400)
        #expect(budget.statistics(.microphone).nativeSamples == 400)
        budget.retireInput()
        #expect(f.reserve(budget,count: 1) == nil)
        #expect(budget.statistics(.microphone).nativeSamples == 400)
        budget.confirmNativeRetired()
        #expect(budget.statistics(.microphone).nativeSamples == 0)
    }

    @Test func fractionalResamplingCapacityDoesNotAccumulatePerBufferRounding() throws {
        let f = Fixture(), budget = LiveCaptureIngress(input: f.input())
        var end: Int64 = 0
        for index in 0..<1000 {
            let raw = try #require(f.reserve(budget,count: 4096,start: index * 4096,rate: 44100))
            let total = (Int64(index + 1) * 4096 * 16000) / 44100
            let count = Int(total - end)
            let normalized = try #require(budget.normalize(raw,scope: f.scope,emittedSamples: count))
            #expect(budget.schedule(normalized,start: end,count: count))
            end = total
            #expect(budget.markDispatched(scope: f.scope,end: end))
            #expect(budget.consume(scope: f.scope,end: end))
        }
        #expect(budget.statistics(.microphone).pendingSamples <= 4097)
    }

    @Test func byteAndReceiptBoundsRemainIndependentOfSampleCapacity() throws {
        let f = Fixture(), budget = LiveCaptureIngress(input: f.input(),rawByteLimit: 64)
        #expect(f.reserve(budget,count: 17) == nil)
        let raw = try #require(f.reserve(budget,count: 16))
        #expect(f.reserve(budget,count: 1) == nil)
        withExtendedLifetime(raw) { #expect(budget.statistics(.microphone).rawBytes == 64) }
        budget.closeInput()
        #expect(f.reserve(budget,count: 1) == nil)
        #expect(budget.takeLosses(.microphone).allSatisfy { $0.frames?.isValid == true })
    }
}
