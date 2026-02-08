@preconcurrency import AVFoundation
import CoreMedia

final class AudioMixer: @unchecked Sendable {
    let engine: AVAudioEngine
    private let systemAudioPlayer: AVAudioPlayerNode
    private let lock = NSLock()
    private var isSetUp = false
    private var hasSystemAudio = false

    private nonisolated(unsafe) var _mixedBufferHandler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var mixedBufferHandler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)? {
        get { lock.withLock { _mixedBufferHandler } }
        set { lock.withLock { _mixedBufferHandler = newValue } }
    }

    init() {
        self.engine = AVAudioEngine()
        self.systemAudioPlayer = AVAudioPlayerNode()
    }

    /// Set up for mixed mode (mic + system audio)
    func setUp(systemAudioFormat: AVAudioFormat) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isSetUp else { return }

        engine.attach(systemAudioPlayer)
        engine.connect(systemAudioPlayer, to: engine.mainMixerNode, format: systemAudioFormat)
        hasSystemAudio = true

        installMixerTap()
        isSetUp = true
    }

    /// Set up for mic-only mode (no system audio)
    func setUpMicOnly() {
        lock.lock()
        defer { lock.unlock() }
        guard !isSetUp else { return }

        hasSystemAudio = false
        installMixerTap()
        isSetUp = true
    }

    func start() throws {
        try engine.start()
        if hasSystemAudio {
            systemAudioPlayer.play()
        }
    }

    func stop() {
        if hasSystemAudio {
            systemAudioPlayer.stop()
        }
        engine.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        lock.withLock {
            isSetUp = false
            hasSystemAudio = false
        }
    }

    func pause() {
        engine.pause()
        if hasSystemAudio {
            systemAudioPlayer.pause()
        }
    }

    func resume() throws {
        try engine.start()
        if hasSystemAudio {
            systemAudioPlayer.play()
        }
    }

    /// Feed system audio CMSampleBuffer into the mixer via the player node
    func scheduleSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard hasSystemAudio else { return }
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else { return }
        systemAudioPlayer.scheduleBuffer(pcmBuffer)
    }

    private func installMixerTap() {
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: mixerFormat) { [weak self] buffer, time in
            guard let self else { return }
            self.mixedBufferHandler?(buffer, time)
        }
    }
}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer

extension CMSampleBuffer {
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = formatDescription,
              var asbd = formatDescription.audioStreamBasicDescription
        else { return nil }

        guard let audioFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }

        guard let blockBuffer = dataBuffer else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(self)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        let dataLength = blockBuffer.dataLength
        guard dataLength > 0 else { return nil }

        try? blockBuffer.withUnsafeMutableBytes { rawBufferPointer in
            guard let baseAddress = rawBufferPointer.baseAddress else { return }
            let audioBufferList = pcmBuffer.mutableAudioBufferList
            let bufferCount = Int(audioBufferList.pointee.mNumberBuffers)
            for i in 0..<bufferCount {
                let audioBuffer = audioBufferList.pointee.mBuffers
                if i == 0 {
                    memcpy(audioBuffer.mData, baseAddress, min(Int(audioBuffer.mDataByteSize), dataLength))
                }
            }
        }

        return pcmBuffer
    }
}
