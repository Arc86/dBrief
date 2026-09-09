import AVFoundation
import Foundation

/// Supplies one chunk to a synchronous AVAudioConverter operation, then reports
/// temporary starvation so the same converter can accept the next streaming chunk.
///
/// `@unchecked Sendable`: the lock protects the single buffer handoff. The buffer
/// is borrowed read-only; callers must keep its storage unchanged until conversion
/// returns. Mic taps convert before returning their reused buffer to the engine;
/// live transcription converts its exclusively owned copy. This holder does not
/// make AVAudioConverter itself safe for concurrent conversion calls.
final class AudioConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
