@preconcurrency import AVFoundation
import CoreGraphics
@preconcurrency import ScreenCaptureKit
import os

private let log = Logger(subsystem: "com.voicerecorder.app", category: "audio")

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
    private var timer: Timer?
    private var startTime: Date?
    private var pauseAccumulator: TimeInterval = 0
    private var pauseStartTime: Date?

    private(set) var hasSystemAudioPermission = false
    private(set) var hasMicrophonePermission = false

    /// The actual file URL being written to (may differ from requested URL if AAC fallback to WAV).
    var actualFileURL: URL? { fileWriter?.actualFileURL }

    func checkPermissions() async {
        hasMicrophonePermission = await MicrophoneCapture.requestAccess()

        // Use CGPreflightScreenCaptureAccess to silently check without triggering the permission dialog.
        hasSystemAudioPermission = CGPreflightScreenCaptureAccess()
        if !hasSystemAudioPermission {
            log.warning("Screen recording permission not granted")
        }
    }

    func startRecording(to fileURL: URL, sampleRate: Int = 16000, bitRate: Int = 128000) async throws {
        guard !isCapturing else { return }

        guard hasMicrophonePermission || hasSystemAudioPermission else {
            throw AudioCaptureError.noMicrophoneAccess
        }

        log.info("Starting recording to \(fileURL.lastPathComponent, privacy: .public)")

        let writer: AudioFileWriter
        do {
            writer = try AudioFileWriter(fileURL: fileURL, sampleRate: sampleRate, bitRate: bitRate)
            log.info("File writer created successfully")
        } catch {
            log.error("File writer creation failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        self.fileWriter = writer

        if hasSystemAudioPermission {
            // Full mode: system audio + mic through AudioMixer
            try await startMixedMode(writer: writer)
        } else {
            // Mic-only mode: simple AVAudioEngine input tap
            try startMicOnlyMode(writer: writer)
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

        // Stop mixer mode
        if let mixer {
            mixer.engine.inputNode.removeTap(onBus: 0)
            mixer.stop()
            self.mixer = nil
        }

        // Stop mic-only mode
        if let micOnlyEngine {
            micOnlyEngine.inputNode.removeTap(onBus: 0)
            micOnlyEngine.stop()
            self.micOnlyEngine = nil
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
        if let micOnlyEngine {
            try micOnlyEngine.start()
        }
        startTimer()
    }

    // MARK: - Mixed Mode (system audio + mic)

    private func startMixedMode(writer: AudioFileWriter) async throws {
        let mixer = AudioMixer()
        self.mixer = mixer

        // Set up system audio capture
        let filter = try await SystemAudioCapture.createContentFilter()
        let capture = try SystemAudioCapture(filter: filter)
        capture.audioBufferHandler = { [weak mixer] sampleBuffer in
            mixer?.scheduleSystemAudio(sampleBuffer)
        }
        self.systemCapture = capture

        let systemFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!
        try mixer.setUp(systemAudioFormat: systemFormat)

        // Set up mic through the mixer's engine
        if hasMicrophonePermission {
            let inputNode = mixer.engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            if inputFormat.sampleRate > 0 {
                inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: Self.noopTapHandler)
                log.info("Mic tap installed on mixer engine")
            }
        }

        // Tap mixed output — handler created in nonisolated context
        mixer.mixedBufferHandler = Self.makeTapHandler(writer: writer)

        try mixer.start()
        try await capture.start()
        log.info("Mixed mode started (system audio + mic)")
    }

    // MARK: - Mic-Only Mode

    private func startMicOnlyMode(writer: AudioFileWriter) throws {
        let engine = AVAudioEngine()
        self.micOnlyEngine = engine

        let inputNode = engine.inputNode
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
