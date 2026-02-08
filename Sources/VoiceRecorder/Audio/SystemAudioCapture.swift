import AVFoundation
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

    var audioBufferHandler: (@Sendable (CMSampleBuffer) -> Void)? {
        get { lock.withLock { _audioBufferHandler } }
        set { lock.withLock { _audioBufferHandler = newValue } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        audioBufferHandler?(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Stream stopped unexpectedly
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
