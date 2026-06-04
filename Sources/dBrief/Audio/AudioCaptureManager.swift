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
    private var micEngine: AVAudioEngine?
    private var systemWriter: AudioTrackWriter?
    private var micWriter: AudioTrackWriter?

    private var timer: Timer?
    private var startTime: Date?
    private var pauseAccumulator: TimeInterval = 0
    private var pauseStartTime: Date?
    private var aecEnabled = true

    private(set) var hasSystemAudioPermission = false
    private(set) var hasMicrophonePermission = false

    /// URLs of the two track files written during the last recording.
    /// Cleared only by the next `startRecording`.
    private(set) var trackURLs: CapturedTracks?

    func checkPermissions() async {
        hasMicrophonePermission = await Self.requestMicAccess()
        hasSystemAudioPermission = CGPreflightScreenCaptureAccess()
        if !hasSystemAudioPermission {
            log.warning("Screen recording permission not granted")
        }
    }

    /// Starts recording. `baseURL` is WITHOUT extension — the manager appends
    /// `_system.caf` and `_mic.caf` internally.
    func startRecording(
        to baseURL: URL,
        inputDeviceUID: String? = nil,
        acousticEchoCancellationEnabled: Bool = true
    ) async throws {
        guard !isCapturing else { return }

        if !hasMicrophonePermission {
            hasMicrophonePermission = await Self.requestMicAccess()
        }
        hasSystemAudioPermission = CGPreflightScreenCaptureAccess()

        guard hasMicrophonePermission || hasSystemAudioPermission else {
            throw AudioCaptureError.noMicrophoneAccess
        }

        let stem = baseURL.deletingPathExtension()
        let systemURL = stem.appendingPathExtension("system.caf")
        let micURL = stem.appendingPathExtension("mic.caf")

        aecEnabled = acousticEchoCancellationEnabled
        trackURLs = CapturedTracks(
            systemURL: hasSystemAudioPermission ? systemURL : nil,
            micURL: hasMicrophonePermission ? micURL : nil
        )

        log.info("Starting recording — system=\(self.hasSystemAudioPermission, privacy: .public) mic=\(self.hasMicrophonePermission, privacy: .public)")

        if hasSystemAudioPermission {
            let writer = AudioTrackWriter(url: systemURL, role: .system)
            self.systemWriter = writer
            try await startSystemPipeline(writer: writer)
        }
        if hasMicrophonePermission {
            let writer = AudioTrackWriter(url: micURL, role: .mic)
            self.micWriter = writer
            try startMicPipeline(writer: writer, inputDeviceUID: inputDeviceUID)
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

        if let systemCapture {
            try? await systemCapture.stop()
            self.systemCapture = nil
        }
        if let micEngine {
            micEngine.inputNode.removeTap(onBus: 0)
            micEngine.stop()
            self.micEngine = nil
        }

        systemWriter?.close(); systemWriter = nil
        micWriter?.close(); micWriter = nil

        isCapturing = false
        peakLevel = 0
        log.info("Recording stopped")
    }

    func pauseRecording() {
        guard isCapturing else { return }
        micEngine?.pause()
        let captureToStop = systemCapture
        self.systemCapture = nil
        Task {
            try? await captureToStop?.stop()
        }
        pauseStartTime = Date()
        stopTimer()
    }

    func resumeRecording() throws {
        guard isCapturing else { return }
        if let pauseStart = pauseStartTime {
            pauseAccumulator += Date().timeIntervalSince(pauseStart)
            pauseStartTime = nil
        }
        if let micEngine {
            try micEngine.start()
        }
        if hasSystemAudioPermission, let systemWriter {
            Task {
                do {
                    try await restartSystemCapture(writer: systemWriter)
                } catch {
                    log.error("Failed to resume system capture: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        startTimer()
    }

    // MARK: - System pipeline

    private func startSystemPipeline(writer: AudioTrackWriter) async throws {
        try await restartSystemCapture(writer: writer)
    }

    private func restartSystemCapture(writer: AudioTrackWriter) async throws {
        let filter = try await SystemAudioCapture.createContentFilter()
        let capture = try SystemAudioCapture(filter: filter)
        capture.audioBufferHandler = Self.makeSystemHandler(writer: writer)
        self.systemCapture = capture
        try await capture.start()
        log.info("System capture started")
    }

    private nonisolated static func makeSystemHandler(
        writer: AudioTrackWriter
    ) -> @Sendable (CMSampleBuffer) -> Void {
        return { sampleBuffer in
            guard let pcm = sampleBuffer.toPCMBuffer() else { return }
            do {
                try writer.write(pcm)
            } catch {
                log.error("System write error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Mic pipeline

    private func startMicPipeline(writer: AudioTrackWriter, inputDeviceUID: String?) throws {
        let engine = AVAudioEngine()
        self.micEngine = engine

        do {
            try AudioInputDeviceManager.applyInputDevice(uid: inputDeviceUID, to: engine)
        } catch {
            log.warning("Failed to set mic input device: \(error.localizedDescription, privacy: .public)")
        }

        let inputNode = engine.inputNode
        // Apple's Voice Processing IO provides real-time AEC, but it switches
        // AVAudioEngine into a VoIP mode that ducks system audio at the OS
        // level — so enabling it alongside ScreenCaptureKit causes empty
        // system-audio buffers. Restrict it to mic-only recording, where
        // there's no SCStream to conflict with. In mixed mode we perform
        // echo suppression offline via the system-track sidechain in
        // `RecordingFinalizer`.
        if aecEnabled && !hasSystemAudioPermission {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                log.info("Voice-processing AEC enabled (mic-only mode)")
            } catch {
                log.warning("Voice-processing AEC unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw AudioCaptureError.noMicrophoneAccess
        }
        log.info("Mic format: \(inputFormat.sampleRate, privacy: .public)Hz \(inputFormat.channelCount, privacy: .public)ch")

        let handler = Self.makeMicHandler(writer: writer)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: handler)

        try engine.start()
        log.info("Mic capture started")
    }

    private nonisolated static func makeMicHandler(
        writer: AudioTrackWriter
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        return { buffer, _ in
            do {
                try writer.write(buffer)
            } catch {
                log.error("Mic write error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Helpers

    private static func requestMicAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startTime = self.startTime else { return }
                self.duration = Date().timeIntervalSince(startTime) - self.pauseAccumulator
                self.peakLevel = max(self.micWriter?.peakLevel ?? 0, self.systemWriter?.peakLevel ?? 0)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
