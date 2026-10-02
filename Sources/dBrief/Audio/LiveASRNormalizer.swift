import AVFoundation
import dBriefWire

/// Confined to one registered source consumer. Conversion capacity is separate
/// from evidence coordinates; output carries a scoped ownership receipt only.
final class LiveASRNormalizer {
    enum Failure: Error { case invalidReceipt, discontinuity, invalidOutput }
    struct Batch {
        let samples: [Float]
        let reservation: LiveCaptureIngress.NormalizedReservation
    }
    private(set) var scope: LiveLaneScope
    let ingress: LiveCaptureIngress
    private let converterOwner = UUID()
    private var conversion: LiveAudioConversion?
    private var rawEpoch: UUID?
    private var sourceFormat: AVAudioFormat?
    private var nextFrame: Int64?
    private var finished = false

    init(scope: LiveLaneScope, ingress: LiveCaptureIngress) throws {
        guard let target = AVAudioFormat(standardFormatWithSampleRate: 16000,channels: 1),
              ingress.claimConverter(scope: scope,owner: converterOwner) else { throw Failure.invalidReceipt }
        self.scope = scope; self.ingress = ingress
        conversion = LiveAudioConversion(targetFormat: target)
    }

    func convert(_ input: LiveAudioBuffer) throws -> Batch? {
        guard !finished else { throw AudioConversionError.alreadyFinished }
        guard let ticket = input.ingress, ticket.owner === ingress, ticket.source == scope.source else { throw Failure.invalidReceipt }
        do {
            guard let metadata = input.metadata, let frames = metadata.emittedFrames, frames.isValid,
                  frames.frameCount == Int64(input.buffer.frameLength), frames.sampleRate == input.buffer.format.sampleRate,
                  let bytes = input.buffer.liveAllocationBytes(compact: false),
                  let maximum = ingress.maximumOutput(ticket,scope: scope,metadata: metadata,
                    frames: Int(input.buffer.frameLength),rate: input.buffer.format.sampleRate,bytes: bytes,
                    format: input.buffer.format,converterOwner: converterOwner) else { throw Failure.invalidReceipt }
            guard rawEpoch == nil || rawEpoch == metadata.sourceEpoch,
                  sourceFormat == nil || sourceFormat == input.buffer.format,
                  nextFrame == nil || nextFrame == frames.startFrame else { throw Failure.discontinuity }
            rawEpoch = metadata.sourceEpoch; sourceFormat = input.buffer.format
            let output = try conversion?.convertChecked(input.buffer,maximumOutputFrames: maximum)
            let samples = try Self.samples(output.map { [$0] } ?? [])
            guard let reservation = ingress.normalize(ticket,scope: scope,emittedSamples: samples.count) else { throw Failure.invalidReceipt }
            nextFrame = frames.startFrame + frames.frameCount
            return samples.isEmpty ? nil : Batch(samples: samples,reservation: reservation)
        } catch {
            ticket.discard(reason: .unavailable)
            cancel(reason: error as? Failure == .discontinuity ? .deviceInterruption : .unavailable)
            throw error
        }
    }

    func finish() throws -> Batch? {
        guard !finished else { return nil }
        defer { cancel(reason: .unavailable) }
        guard let rawEpoch else { return nil }
        guard let maximum = ingress.maximumTailOutput(scope: scope,sourceEpoch: rawEpoch) else { throw Failure.invalidReceipt }
        let samples = try Self.samples(conversion?.finishBounded(maximumOutputFrames: maximum) ?? [])
        guard let reservation = ingress.normalizeTail(scope: scope,sourceEpoch: rawEpoch,emittedSamples: samples.count) else {
            throw Failure.invalidReceipt
        }
        retire(discardingTail: false,reason: .stopped)
        return samples.isEmpty ? nil : Batch(samples: samples,reservation: reservation)
    }

    func cancel(reason: LiveGapReason = .stopped) { retire(discardingTail: true,reason: reason) }

    private func retire(discardingTail: Bool, reason: LiveGapReason) {
        guard !finished else { return }
        finished = true
        conversion = nil
        if discardingTail, let rawEpoch {
            // Abandonment lacks a proven raw subrange. Neither conservative
            // held capacity nor converter input stamps establish exact audio.
            ingress.recordConverterLoss(source: scope.source,sourceEpoch: rawEpoch,owner: converterOwner,reason: reason)
        }
        _ = ingress.retireConverter(source: scope.source,sourceEpoch: rawEpoch,owner: converterOwner)
    }
    func rebind(to scope: LiveLaneScope) -> Bool {
        guard !finished, scope.identity == self.scope.identity, scope.source == self.scope.source,
              ingress.ownsConverter(scope: scope,owner: converterOwner) else { return false }
        self.scope = scope; return true
    }
    deinit { cancel() }

    private static func samples(_ buffers: [AVAudioPCMBuffer]) throws -> [Float] {
        var result: [Float] = []
        for buffer in buffers {
            guard buffer.format.commonFormat == .pcmFormatFloat32, buffer.format.channelCount == 1,
                  buffer.format.sampleRate == 16000, let channel = buffer.floatChannelData?[0] else { throw Failure.invalidOutput }
            result.append(contentsOf: UnsafeBufferPointer(start: channel,count: Int(buffer.frameLength)))
        }
        guard result.allSatisfy({ $0.isFinite }) else { throw Failure.invalidOutput }
        return result
    }
}
