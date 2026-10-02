import AVFoundation
import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite struct LiveASRNormalizerTests {
    private struct Fixture {
        let identity = LiveSessionIdentity(recordingID: UUID(),captureSessionID: UUID())
        let epoch = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        let rawEpoch = UUID()
        var scope: LiveLaneScope { .init(identity: identity,source: .microphone,epochID: epoch.id) }
        func pool() -> LiveCaptureIngress {
            .init(input: .init(identity: identity,configuration: .init(language: .auto,modelDirectory: "/fixture"),epochs: [epoch]))
        }
        func buffer(_ pool: LiveCaptureIngress, rate: Double = 48000, frames: Int = 4800, start: Int = 0,
                    channels: AVAudioChannelCount = 1, rawEpoch: UUID? = nil) throws -> LiveAudioBuffer {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate,channels: channels))
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format,frameCapacity: AVAudioFrameCount(frames)))
            pcm.frameLength = AVAudioFrameCount(frames)
            for channel in 0..<Int(channels) {
                for frame in 0..<frames { pcm.floatChannelData![channel][frame] = 0.25 }
            }
            let metadata = LiveAudioMetadata(sourceEpoch: rawEpoch ?? self.rawEpoch,role: .mic,timestamp: .unavailable,
                emittedFrames: .init(startFrame: Int64(start),frameCount: Int64(frames),sampleRate: rate),writeOutcome: .failed,converter: nil)
            let raw = try #require(pool.reserveRaw(source: .microphone,metadata: metadata,frames: frames,rate: rate,bytes: frames * Int(channels) * 4,format: format))
            return .init(pcm,metadata: metadata,ingress: raw)
        }
    }

    @Test(arguments: [44100.0,48000.0]) func realResamplingAndEofTailUseScopedCreditsWithoutInventingClock(rate: Double) throws {
        let f = Fixture(), pool = f.pool(), normalizer = try LiveASRNormalizer(scope: f.scope,ingress: pool)
        var end: Int64 = 0, samples: [Float] = []
        for index in 0..<10 {
            let item = try f.buffer(pool,rate: rate,frames: Int(rate / 10),start: index * Int(rate / 10))
            if let batch = try normalizer.convert(item) {
                samples += batch.samples
                #expect(batch.samples.allSatisfy { $0.isFinite })
                #expect(pool.schedule(batch.reservation,start: end,count: batch.samples.count))
                end += Int64(batch.samples.count)
                #expect(pool.markDispatched(scope: f.scope,end: end))
                #expect(pool.consume(scope: f.scope,end: end))
            }
        }
        let tail = try #require(try normalizer.finish())
        #expect(tail.samples.count > 0)
        samples += tail.samples
        #expect(samples.count == 16000)
        #expect(pool.statistics(.microphone).converterSamples == 0)
        #expect(pool.statistics(.microphone).pendingSamples == 4096 + tail.samples.count)
        #expect(pool.takeLosses(.microphone).isEmpty)
        #expect(try normalizer.finish() == nil)
        #expect(throws: (any Error).self) { try normalizer.convert(f.buffer(pool,rate: rate,frames: 1,start: Int(rate))) }
    }

    @Test(arguments: ["epoch","format","gap"]) func sourceAndFormatDiscontinuitiesCannotConcatenateOldConverterAudio(change: String) throws {
        let f = Fixture(), pool = f.pool(), normalizer = try LiveASRNormalizer(scope: f.scope,ingress: pool)
        _ = try normalizer.convert(f.buffer(pool))
        let next = try f.buffer(pool,rate: change == "format" ? 44100 : 48000,
            frames: change == "format" ? 4410 : 4800,start: change == "gap" ? 9600 : 4800,rawEpoch: change == "epoch" ? UUID() : nil)
        #expect(throws: LiveASRNormalizer.Failure.discontinuity) { try normalizer.convert(next) }
        normalizer.cancel()
        #expect(pool.statistics(.microphone).converterSamples == 0)
        #expect(try normalizer.finish() == nil)
    }

    @Test func oversizedEofTailAbortsWithoutCollectingUnboundedOutput() throws {
        let f = Fixture(), pool = f.pool(), item = try f.buffer(pool,rate: 8000,frames: 8000)
        let target = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000,channels: 1))
        let conversion = LiveAudioConversion(targetFormat: target)
        _ = try conversion.convertChecked(item.buffer,maximumOutputFrames: 100)
        #expect(throws: AudioConversionError.outputLimit) { try conversion.finishBounded(maximumOutputFrames: 100) }
        #expect(try conversion.finishBounded(maximumOutputFrames: 100).isEmpty)
    }

    @Test func aReceiptCannotNormalizeAnotherBuffersHeaderOrAnotherCapture() throws {
        let f = Fixture(), pool = f.pool(), normalizer = try LiveASRNormalizer(scope: f.scope,ingress: pool)
        let item = try f.buffer(pool)
        let shortened = try #require(AVAudioPCMBuffer(pcmFormat: item.buffer.format,frameCapacity: 10))
        shortened.frameLength = 10
        #expect(throws: (any Error).self) { try normalizer.convert(.init(shortened,metadata: item.metadata,ingress: item.ingress)) }
        let other = Fixture(), otherPool = other.pool()
        #expect(throws: (any Error).self) { try normalizer.convert(other.buffer(otherPool)) }
        normalizer.cancel()
    }

    @Test func stereoInputBecomesFiniteMonoOutput() throws {
        let f = Fixture(), pool = f.pool(), normalizer = try LiveASRNormalizer(scope: f.scope,ingress: pool)
        let item = try f.buffer(pool,rate: 16000,frames: 3200,channels: 2)
        let batch = try #require(try normalizer.convert(item))
        #expect(batch.samples.count == 3200)
        #expect(batch.samples.allSatisfy { $0.isFinite && abs($0 - 0.25) < 0.001 })
        #expect(batch.reservation.scope == f.scope)
        normalizer.cancel()
    }

    @Test func repeatedOldCancellationCannotRetireAFreshConvertersHeldCredit() throws {
        let f = Fixture(), pool = f.pool(), old = try LiveASRNormalizer(scope: f.scope,ingress: pool)
        _ = try old.convert(f.buffer(pool))
        old.cancel()
        let next = try LiveASRNormalizer(scope: f.scope,ingress: pool)
        _ = try next.convert(f.buffer(pool,start: 4800))
        let held = pool.statistics(.microphone).converterSamples
        #expect(held > 0)
        old.cancel()
        #expect(pool.statistics(.microphone).converterSamples == held)
        #expect(try next.finish() != nil)
    }

    @Test func destructiveCancellationRetainsRawUncertaintyForThePreviousConvertersTail() throws {
        let f = Fixture(), pool = f.pool(), normalizer = try LiveASRNormalizer(scope: f.scope,ingress: pool)
        _ = try normalizer.convert(f.buffer(pool))
        #expect(pool.statistics(.microphone).converterSamples > 0)
        normalizer.cancel()
        let losses = pool.takeLosses(.microphone)
        #expect(losses.count == 1)
        #expect(losses.first?.sourceEpoch == f.rawEpoch && losses.first?.frames == nil)
        normalizer.cancel()
        #expect(pool.takeLosses(.microphone).isEmpty)
    }

    @Test func rawReceiptMustMatchChannelAndSampleLayoutEvenWhenByteCountsMatch() throws {
        let f = Fixture(), pool = f.pool(), normalizer = try LiveASRNormalizer(scope: f.scope,ingress: pool)
        let item = try f.buffer(pool,rate: 16000,frames: 3200)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16,sampleRate: 16000,channels: 2,interleaved: true))
        let tampered = try #require(AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 3200))
        tampered.frameLength = 3200
        #expect(tampered.liveAllocationBytes(compact: false) == item.buffer.liveAllocationBytes(compact: false))
        #expect(throws: LiveASRNormalizer.Failure.invalidReceipt) { try normalizer.convert(.init(tampered,metadata: item.metadata,ingress: item.ingress)) }
    }

    @Test func acceptedNativeReplacementCanRebindTheSameConverterAndCreateANewOneAfterRetirement() throws {
        let f = Fixture(), pool = f.pool(), normalizer = try LiveASRNormalizer(scope: f.scope,ingress: pool)
        _ = try normalizer.convert(f.buffer(pool))
        let held = pool.statistics(.microphone).converterSamples
        let epoch = LiveEpoch(id: UUID(),source: .microphone,engineRevision: "fixture",language: "auto",meetingOriginNanoseconds: nil)
        let next = LiveLaneScope(identity: f.identity,source: .microphone,epochID: epoch.id)
        #expect(!normalizer.rebind(to: next))
        #expect(pool.replaceEpoch(old: f.scope,new: epoch))
        #expect(normalizer.rebind(to: next))
        #expect(pool.statistics(.microphone).converterSamples == held)
        let batch = try #require(try normalizer.convert(f.buffer(pool,start: 4800)))
        #expect(batch.reservation.scope == next)
        normalizer.cancel()
        let fresh = try LiveASRNormalizer(scope: next,ingress: pool)
        _ = try fresh.convert(f.buffer(pool,start: 9600))
        #expect(throws: LiveASRNormalizer.Failure.invalidReceipt) { try LiveASRNormalizer(scope: f.scope,ingress: pool) }
        #expect(try fresh.finish() != nil)
    }

    @Test func terminalIngressSealsConverterUncertaintyWithoutReturningItsMemoryCredit() throws {
        let f = Fixture(), pool = f.pool(), normalizer = try LiveASRNormalizer(scope: f.scope,ingress: pool)
        _ = try normalizer.convert(f.buffer(pool))
        let held = pool.statistics(.microphone).converterSamples
        #expect(held > 0)
        pool.retireInput()
        let sealed = pool.takeLosses(.microphone)
        #expect(sealed.count == 1 && sealed.first?.sourceEpoch == f.rawEpoch && sealed.first?.frames == nil)
        #expect(pool.statistics(.microphone).converterSamples == held)
        normalizer.cancel()
        #expect(pool.statistics(.microphone).converterSamples == 0)
        #expect(pool.takeLosses(.microphone).isEmpty)
    }
}
