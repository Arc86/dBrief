import AVFoundation
import CoreMedia
import OSLog
@preconcurrency import ScreenCaptureKit

final class SystemAudioCapture: NSObject, @unchecked Sendable {
    private let stream: SCStream
    private let delegate: StreamDelegate

    struct Configuration: Sendable {
        var sampleRate: Double = 48000
        var channelCount: Int = 2
    }

    init(filter: SCContentFilter, configuration: Configuration = Configuration()) throws {
        let streamConfig = SCStreamConfiguration()
        // Minimal video config (required by ScreenCaptureKit)
        streamConfig.width = 2
        streamConfig.height = 2
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        streamConfig.capturesAudio = true
        streamConfig.sampleRate = Int(configuration.sampleRate)
        streamConfig.channelCount = configuration.channelCount

        self.delegate = StreamDelegate()
        self.stream = SCStream(filter: filter, configuration: streamConfig, delegate: delegate)
        super.init()
    }

    var audioBufferHandler: (@Sendable (CMSampleBuffer) -> Void)? {
        get { delegate.audioBufferHandler }
        set { delegate.audioBufferHandler = newValue }
    }

    var unexpectedStopHandler: (@Sendable (DurabilityDiagnosticFailure) -> Void)? {
        get { delegate.unexpectedStopHandler }
        set { delegate.unexpectedStopHandler = newValue }
    }

    var unexpectedStopFailure: DurabilityDiagnosticFailure? {
        delegate.unexpectedStopFailure
    }

    func start() async throws {
        try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()
    }

    func stop() async throws {
        try await stream.stopCapture()
    }

    static func createContentFilter() async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayFound
        }
        return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
    }
}

private final class StreamDelegate: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var _audioBufferHandler: (@Sendable (CMSampleBuffer) -> Void)?
    private var _unexpectedStopHandler: (@Sendable (DurabilityDiagnosticFailure) -> Void)?
    private var _unexpectedStopFailure: DurabilityDiagnosticFailure?

    var audioBufferHandler: (@Sendable (CMSampleBuffer) -> Void)? {
        get { lock.withLock { _audioBufferHandler } }
        set { lock.withLock { _audioBufferHandler = newValue } }
    }

    var unexpectedStopHandler: (@Sendable (DurabilityDiagnosticFailure) -> Void)? {
        get { lock.withLock { _unexpectedStopHandler } }
        set { lock.withLock { _unexpectedStopHandler = newValue } }
    }


    var unexpectedStopFailure: DurabilityDiagnosticFailure? {
        lock.withLock { _unexpectedStopFailure }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        audioBufferHandler?(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let failure = DurabilityDiagnosticFailure(error: error)
        lock.withLock { _unexpectedStopFailure = failure }
        Logger.audio.error(
            "System audio stream stopped unexpectedly: domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public)"
        )
        unexpectedStopHandler?(failure)
    }
}

enum AudioCaptureError: Error, LocalizedError {
    case noDisplayFound
    case noMicrophoneAccess
    case noScreenCaptureAccess
    case engineStartFailed(Error)
    case fileWriterFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noDisplayFound: "No display found for audio capture."
        case .noMicrophoneAccess: "Microphone access was denied."
        case .noScreenCaptureAccess: "Screen recording permission is required for system audio capture."
        case .engineStartFailed(let error): "Audio engine failed to start: \(error.localizedDescription)"
        case .fileWriterFailed(let error): "Audio file writer failed: \(error.localizedDescription)"
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

        // Two-step: ask for required size first, then allocate exactly that much.
        // Using the manually-calculated size can under-allocate when the
        // alignment flag forces padding, causing kCMSampleBufferError_ArrayTooSmall.
        var requiredSize: Int = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard requiredSize > 0 else { return nil }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }
        let bufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferListPointer,
            bufferListSize: requiredSize,
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
