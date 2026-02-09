@preconcurrency import AVFoundation
import CoreMedia

final class AudioMixer: @unchecked Sendable {
    let engine: AVAudioEngine
    private let systemAudioPlayer: AVAudioPlayerNode
    private let captureMixer: AVAudioMixerNode
    private let micPlayer: AVAudioPlayerNode
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
        self.captureMixer = AVAudioMixerNode()
        self.micPlayer = AVAudioPlayerNode()
    }

    /// Set up for mixed mode (mic + system audio)
    func setUp(systemAudioFormat: AVAudioFormat? = nil, micFormat: AVAudioFormat? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isSetUp else { return }

        // Avoid feedback loops: we don't need to play audio to the speakers.
        engine.mainMixerNode.outputVolume = 0
        engine.attach(captureMixer)
        engine.attach(systemAudioPlayer)
        engine.attach(micPlayer)
        // Allow AVAudioEngine to perform format conversion if needed.
        // Let the engine handle format conversion for mixed sources.
        engine.connect(systemAudioPlayer, to: captureMixer, format: systemAudioFormat)
        engine.connect(micPlayer, to: captureMixer, format: micFormat)
        engine.connect(captureMixer, to: engine.mainMixerNode, format: nil)
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
        engine.mainMixerNode.outputVolume = 0
        engine.attach(captureMixer)
        engine.attach(micPlayer)
        engine.connect(micPlayer, to: captureMixer, format: nil)
        engine.connect(captureMixer, to: engine.mainMixerNode, format: nil)
        installMixerTap()
        isSetUp = true
    }

    func start() throws {
        try engine.start()
        if hasSystemAudio {
            systemAudioPlayer.play()
        }
        micPlayer.play()
    }

    func stop() {
        if hasSystemAudio {
            systemAudioPlayer.stop()
        }
        micPlayer.stop()
        engine.stop()
        captureMixer.removeTap(onBus: 0)
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
        micPlayer.play()
    }

    /// Feed system audio CMSampleBuffer into the mixer via the player node
    func scheduleSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard hasSystemAudio else { return }
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else { return }
        systemAudioPlayer.scheduleBuffer(pcmBuffer)
    }

    func scheduleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        micPlayer.scheduleBuffer(buffer)
    }

    private func installMixerTap() {
        let mixerFormat = captureMixer.outputFormat(forBus: 0)
        captureMixer.installTap(onBus: 0, bufferSize: 4096, format: mixerFormat) { [weak self] buffer, time in
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

        let frameCount = CMSampleBufferGetNumSamples(self)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        let channelCount = Int(asbd.mChannelsPerFrame)
        let bufferListSize = MemoryLayout<AudioBufferList>.size
            + max(0, channelCount - 1) * MemoryLayout<AudioBuffer>.size
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }
        let bufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferListPointer,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let sourceList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        let destList = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)

        let bufferCount = min(sourceList.count, destList.count)
        for index in 0..<bufferCount {
            let src = sourceList[index]
            let dst = destList[index]
            guard let srcData = src.mData, let dstData = dst.mData else { continue }
            memcpy(dstData, srcData, min(Int(src.mDataByteSize), Int(dst.mDataByteSize)))
        }

        return pcmBuffer
    }
}
