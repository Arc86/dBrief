@preconcurrency import AVFoundation

final class MicrophoneCapture: @unchecked Sendable {
    private let engine: AVAudioEngine
    private let busIndex: AVAudioNodeBus = 0

    private var _bufferHandler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private let lock = NSLock()

    var bufferHandler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)? {
        get { lock.withLock { _bufferHandler } }
        set { lock.withLock { _bufferHandler = newValue } }
    }

    init(engine: AVAudioEngine) {
        self.engine = engine
    }

    func start() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: busIndex)

        guard inputFormat.sampleRate > 0 else {
            throw AudioCaptureError.noMicrophoneAccess
        }

        inputNode.installTap(onBus: busIndex, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            guard let self else { return }
            self.bufferHandler?(buffer, time)
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: busIndex)
    }

    static func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
