@preconcurrency import AVFoundation
import CoreGraphics
@preconcurrency import ScreenCaptureKit
import os

private let log = Logger.audio

@MainActor
@Observable
final class AudioCaptureManager {
    private(set) var isCapturing = false
    private(set) var duration: TimeInterval = 0
    private(set) var peakLevel: Float = 0

    private var systemCapture: SystemAudioCapture?
    private var mixer: AudioMixer?
    private var fileWriter: AudioFileWriter?
    private var micOnlyEngine: AVAudioEngine?
    /// Dedicated AEC-enabled engine used in mixed mode. Kept separate from
    /// `mixer.engine` because `setVoiceProcessingEnabled(true)` reconfigures the
    /// whole engine into a VoIP I/O unit, which is incompatible with our
    /// dual-player mixer graph.
    private var micEngine: AVAudioEngine?
    private var timer: Timer?
    private var startTime: Date?
    private var pauseAccumulator: TimeInterval = 0
    private var pauseStartTime: Date?

    private(set) var hasSystemAudioPermission = false
    private(set) var hasMicrophonePermission = false

    /// The actual file URL being written to.
    var actualFileURL: URL? { fileWriter?.actualFileURL }

    func checkPermissions() async {
        hasMicrophonePermission = await MicrophoneCapture.requestAccess()

        // Use CGPreflightScreenCaptureAccess to silently check without triggering the permission dialog.
        hasSystemAudioPermission = CGPreflightScreenCaptureAccess()
        if !hasSystemAudioPermission {
            log.warning("Screen recording permission not granted")
        }
    }

    func startRecording(
        to fileURL: URL,
        inputDeviceUID: String? = nil
    ) async throws {
        guard !isCapturing else { return }

        if !hasMicrophonePermission {
            hasMicrophonePermission = await MicrophoneCapture.requestAccess()
        }

        hasSystemAudioPermission = CGPreflightScreenCaptureAccess()

        guard hasMicrophonePermission || hasSystemAudioPermission else {
            throw AudioCaptureError.noMicrophoneAccess
        }

        log.info("Starting recording to \(fileURL.lastPathComponent, privacy: .public)")

        let writer = AudioFileWriter(fileURL: fileURL)
        log.info("File writer created successfully")
        self.fileWriter = writer

        if hasSystemAudioPermission {
            // Full mode: system audio + mic through AudioMixer
            try await startMixedMode(writer: writer, inputDeviceUID: inputDeviceUID)
        } else {
            // Mic-only mode: simple AVAudioEngine input tap
            try startMicOnlyMode(writer: writer, inputDeviceUID: inputDeviceUID)
        }

        isCapturing = true
        startTime = Date()
        pauseAccumulator = 0
        startTimer()
        log.info("Recording started")
    }

    func stopRecording() async {
        guard isCapturing else { return }

        stopTimer()

        // Stop system audio capture
        if let systemCapture {
            try? await systemCapture.stop()
            self.systemCapture = nil
        }

        // Stop dedicated mic engine (mixed mode)
        if let micEngine {
            micEngine.inputNode.removeTap(onBus: 0)
            micEngine.stop()
            self.micEngine = nil
        }

        // Stop mic-only mode
        if let micOnlyEngine {
            micOnlyEngine.inputNode.removeTap(onBus: 0)
            micOnlyEngine.stop()
            self.micOnlyEngine = nil
        }

        // Drain: let queued buffers play through to the file writer
        if mixer != nil {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        // Stop mixer and close file
        if let mixer {
            mixer.stop()
            self.mixer = nil
        }

        fileWriter?.close()
        fileWriter = nil

        isCapturing = false
        peakLevel = 0
        log.info("Recording stopped")
    }

    func pauseRecording() {
        guard isCapturing else { return }
        mixer?.pause()
        micEngine?.pause()
        micOnlyEngine?.pause()
        pauseStartTime = Date()
        stopTimer()
    }

    func resumeRecording() throws {
        guard isCapturing else { return }
        if let pauseStart = pauseStartTime {
            pauseAccumulator += Date().timeIntervalSince(pauseStart)
            pauseStartTime = nil
        }
        try mixer?.resume()
        if let micEngine {
            try micEngine.start()
        }
        if let micOnlyEngine {
            try micOnlyEngine.start()
        }
        startTimer()
    }

    // MARK: - Mixed Mode (system audio + mic)

    private func startMixedMode(writer: AudioFileWriter, inputDeviceUID: String?) async throws {
        let mixer = AudioMixer()
        self.mixer = mixer

        // Set up system audio capture
        let filter = try await SystemAudioCapture.createContentFilter()
        let capture = try SystemAudioCapture(filter: filter)
        capture.audioBufferHandler = { [weak mixer] sampleBuffer in
            mixer?.scheduleSystemAudio(sampleBuffer)
        }
        self.systemCapture = capture

        // Build the mic on its own engine so we can enable voice-processing (AEC)
        // without forcing the whole mixer graph into a VoIP I/O configuration.
        // The AEC'd mic buffers are then scheduled onto the mixer's micPlayer,
        // keeping the existing systemAudio + mic summing intact.
        var micFormat: AVAudioFormat?
        if hasMicrophonePermission {
            let micEngine = AVAudioEngine()
            self.micEngine = micEngine
            do {
                try AudioInputDeviceManager.applyInputDevice(uid: inputDeviceUID, to: micEngine)
            } catch {
                log.warning("Failed to set input device on mic engine: \(error.localizedDescription, privacy: .public)")
            }
            let inputNode = micEngine.inputNode
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                log.info("Voice processing (AEC) enabled on dedicated mic engine")
            } catch {
                log.warning("Voice processing unavailable — acoustic echo may occur: \(error.localizedDescription, privacy: .public)")
            }
            let inputFormat = inputNode.outputFormat(forBus: 0)
            if inputFormat.sampleRate > 0 {
                micFormat = inputFormat
            }
        }

        log.info("[AudioCaptureManager] Mic format: \(micFormat.map { "\($0.sampleRate)Hz \($0.channelCount)ch interleaved=\($0.isInterleaved)" } ?? "nil", privacy: .public)")
        try mixer.setUp(systemAudioFormat: nil, micFormat: micFormat)

        // Tap the AEC'd mic buffers from the dedicated engine and feed them into
        // the mixer's micPlayer node.
        if let micEngine, let micFormat {
            let micHandler = Self.makeMicTapHandler(mixer: mixer)
            micEngine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat, block: micHandler)
            log.info("Mic tap installed on dedicated mic engine (AEC)")
        }

        // Tap mixed output — handler created in nonisolated context
        mixer.mixedBufferHandler = Self.makeTapHandler(writer: writer)

        try mixer.start()
        if let micEngine {
            try micEngine.start()
        }
        try await capture.start()
        log.info("Mixed mode started (system audio + mic)")
    }

    // MARK: - Mic-Only Mode

    private func startMicOnlyMode(writer: AudioFileWriter, inputDeviceUID: String?) throws {
        let engine = AVAudioEngine()
        self.micOnlyEngine = engine

        do {
            try AudioInputDeviceManager.applyInputDevice(uid: inputDeviceUID, to: engine)
        } catch {
            log.warning("Failed to set input device: \(error.localizedDescription, privacy: .public)")
        }

        let inputNode = engine.inputNode
        // Voice processing is safe in mic-only mode: there's no mixer graph to
        // fight the VoIP I/O unit, so the -10875 format-mismatch doesn't occur.
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            log.info("Voice processing (AEC) enabled on mic input")
        } catch {
            log.warning("Voice processing unavailable — acoustic echo may occur: \(error.localizedDescription, privacy: .public)")
        }
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw AudioCaptureError.noMicrophoneAccess
        }

        log.info("Mic format: \(inputFormat.sampleRate, privacy: .public)Hz, \(inputFormat.channelCount, privacy: .public)ch")

        // The tap handler MUST be created in a nonisolated context. Closures created
        // inside @MainActor methods inherit MainActor isolation, causing a runtime
        // assertion crash when AVAudioEngine calls them on the real-time audio thread.
        let handler = Self.makeTapHandler(writer: writer)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: handler)

        try engine.start()
        log.info("Mic-only mode started")
    }

    /// Creates a tap handler in a nonisolated context so it doesn't inherit @MainActor.
    private nonisolated static func makeTapHandler(
        writer: AudioFileWriter
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        return { buffer, _ in
            do {
                try writer.write(buffer)
            } catch {
                log.error("Write error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// No-op tap handler (nonisolated to avoid inheriting @MainActor).
    private nonisolated static let noopTapHandler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { _, _ in }

    /// Tap handler for mic input in mixed mode (nonisolated to avoid @MainActor assertions).
    private nonisolated static func makeMicTapHandler(
        mixer: AudioMixer
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        return { buffer, _ in
            if let copy = Self.copyBuffer(buffer) {
                mixer.scheduleMicBuffer(copy)
            }
        }
    }

    private nonisolated static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameCapacity) else {
            return nil
        }
        copy.frameLength = buffer.frameLength

        let channels = Int(format.channelCount)
        let frames = Int(buffer.frameLength)

        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            let bytes = frames * MemoryLayout<Float>.size
            for channel in 0..<channels {
                memcpy(dst[channel], src[channel], bytes)
            }
            return copy
        }

        if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            let bytes = frames * MemoryLayout<Int16>.size
            for channel in 0..<channels {
                memcpy(dst[channel], src[channel], bytes)
            }
            return copy
        }

        return nil
    }

    // MARK: - Private

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startTime = self.startTime else { return }
                self.duration = Date().timeIntervalSince(startTime) - self.pauseAccumulator
                self.peakLevel = self.fileWriter?.lastPeakLevel ?? 0
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

}
