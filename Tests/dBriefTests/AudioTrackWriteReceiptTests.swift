import AVFoundation
import Foundation
import Testing
@testable import dBrief

@Suite struct AudioTrackWriteReceiptTests {
    private func buffer(rate: Double = 16000, frames: UInt32 = 100) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let value = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        value.frameLength = frames
        for i in 0..<Int(frames) { value.floatChannelData![0][i] = 0 }
        return value
    }
    @Test func receiptsMatchSuccessfulFileIntervalsAndDropsDoNotAdvanceThem() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AudioTrackWriter(url: url, role: .mic)
        #expect(try writer.write(buffer()) == .written(startFrame: 0, frameCount: 100, sampleRate: 16000))
        #expect(try writer.write(buffer(rate: 48000)) == .dropped(.formatMismatch))
        #expect(try writer.write(buffer(frames: 50)) == .written(startFrame: 100, frameCount: 50, sampleRate: 16000))
        writer.close()
        #expect(try AVAudioFile(forReading: url).length == 150)
        #expect(writer.diagnostics.framesWritten == 150)
        #expect(writer.diagnostics.droppedBuffers == 1)
    }
    @Test func reopenReceiptUsesCurrentFilePositionRatherThanOldDiagnosticTotals() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reopen-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AudioTrackWriter(url: url, role: .mic)
        try writer.write(buffer())
        writer.close()
        #expect(try writer.write(buffer(frames: 50)) == .written(startFrame: 0, frameCount: 50, sampleRate: 16000))
        writer.close()
        #expect(try AVAudioFile(forReading: url).length == 50)
        #expect(writer.diagnostics.framesWritten == 150)
    }
    @Test func throwingWriteCannotProduceASuccessReceipt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("missing/file.caf")
        let writer = AudioTrackWriter(url: url, role: .mic)
        #expect(throws: (any Error).self) { try writer.write(buffer()) }
        #expect(writer.diagnostics.framesWritten == 0)
        #expect(writer.diagnostics.writeErrors == 1)
    }
    @Test func timestampValidityPreservesRawDomainsWithoutInventingHostTime() {
        #expect(LiveAudioTimestamp.microphone(AVAudioTime(sampleTime: 4800, atRate: 48000)) ==
            .microphone(hostTime: nil, sampleTime: 4800, sampleRate: 48000))
        #expect(LiveAudioTimestamp.microphone(AVAudioTime(hostTime: 42)) ==
            .microphone(hostTime: 42, sampleTime: nil, sampleRate: nil))
        #expect(LiveAudioTimestamp.microphone(nil) == .unavailable)
        #expect(LiveAudioTimestamp.system(CMTime(value: 123, timescale: 1000, flags: .valid, epoch: 7)) ==
            .systemPTS(value: 123, timescale: 1000, epoch: 7))
        #expect(LiveAudioTimestamp.system(.invalid) == .unavailable)
        #expect(LiveAudioTimestamp.system(.positiveInfinity) == .unavailable)
    }

    @Test func concurrentReceiptsAreDisjointAndCoverExactlyTheFile() throws {
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var receipts: [AudioTrackWriteReceipt] = []
            var failures = 0
            func add(_ receipt: AudioTrackWriteReceipt) { lock.withLock { receipts.append(receipt) } }
            func fail() { lock.withLock { failures += 1 } }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("concurrent-receipt-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AudioTrackWriter(url: url, role: .mic), results = Results()
        let immutable = LiveAudioBuffer(try buffer(frames: 100))
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do { results.add(try writer.write(immutable.buffer)) } catch { results.fail() }
        }
        writer.close()
        #expect(results.failures == 0)
        let starts = results.receipts.compactMap { receipt -> Int64? in
            guard case let .written(start, count, rate) = receipt, count == 100, rate == 16000 else { return nil }
            return start
        }.sorted()
        #expect(starts == (0..<16).map { Int64($0 * 100) })
        #expect(try AVAudioFile(forReading: url).length == 1600)
    }
}
