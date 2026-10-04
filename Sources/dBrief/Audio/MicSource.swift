@preconcurrency import AVFoundation
import NativeMic
import os

private let log = Logger.audio

/// One running microphone capture for one `MicSourcePlan`. A device switch never
/// re-points a source: the old one is stopped and a new one built for the new plan.
/// All native operations go through the NativeMic wrappers, so an AVFAudio
/// NSException surfaces as a Swift error instead of unwinding Swift frames.
@MainActor
protocol MicSource: AnyObject {
    var plan: MicSourcePlan { get }
    var sink: MicCaptureSink { get }
    /// False once the source has stopped on its own (e.g. a route change stopped
    /// the engine) while it should be running.
    var isRunning: Bool { get }
    func start() throws
    func pause()
    /// Terminal and idempotent: stops delivery, then drains the sink.
    func stop()
}

@MainActor
enum MicSourceFactory {
    static func make(
        _ plan: MicSourcePlan,
        sink: MicCaptureSink,
        onConfigurationChange: @escaping @Sendable () -> Void
    ) throws -> any MicSource {
        switch plan.backend {
        case .engine:
            try EngineMicSource(plan: plan, sink: sink, onConfigurationChange: onConfigurationChange)
        case .captureSession:
            try CaptureSessionMicSource(plan: plan, sink: sink)
        }
    }

    /// Tap/sample callbacks run on audio threads; build them outside the main actor.
    nonisolated static func makeHandler(sink: MicCaptureSink) -> AVAudioNodeTapBlock {
        { buffer, time in sink.receive(buffer, hostTime: time.isHostTimeValid ? time.hostTime : nil) }
    }
}

/// A fresh AVAudioEngine on the macOS default input. It never writes
/// kAudioOutputUnitProperty_CurrentDevice: that binding is what produced zero
/// callbacks and stale-format exceptions on device switches.
@MainActor
final class EngineMicSource: MicSource {
    let plan: MicSourcePlan
    let sink: MicCaptureSink
    private let engine: NativeMicEngine
    private var isStopped = false

    /// Stopped engines can still have AVFAudio route-change callbacks queued;
    /// releasing one then races AVAudioEngine.dealloc. Keep the last few alive
    /// — by the time one is dropped it has been stopped for several switches.
    private static var retired: [NativeMicEngine] = []
    private static let retiredLimit = 4

    init(plan: MicSourcePlan, sink: MicCaptureSink,
         onConfigurationChange: @escaping @Sendable () -> Void) throws {
        self.plan = plan
        self.sink = sink
        let engine = try NativeMicEngine.make()
        self.engine = engine
        do {
            if plan.voiceProcessing {
                do {
                    try engine.setVoiceProcessing(enabled: true)
                } catch {
                    log.warning("Voice-processing AEC unavailable: \(error.localizedDescription, privacy: .public)")
                }
            }
            // Tap the hardware-side format — the recipe that passed on Bluetooth and
            // built-in defaults (2026-09-21 acceptance) — except with VPIO, which
            // replaces the client format; read that after enabling it.
            let format = plan.voiceProcessing ? try engine.outputFormat() : try engine.inputFormat()
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw AudioCaptureError.noMicrophoneAccess
            }
            log.notice("Mic engine format: \(format.sampleRate, privacy: .public)Hz \(format.channelCount, privacy: .public)ch")
            try engine.installTap(bufferSize: 4096, format: format,
                                  handler: MicSourceFactory.makeHandler(sink: sink))
            try engine.setConfigurationChangeHandler(onConfigurationChange)
        } catch {
            retire()
            throw error
        }
    }

    var isRunning: Bool { !isStopped && ((try? engine.isRunning().boolValue) ?? false) }

    func start() throws { try engine.start() }

    func pause() { try? engine.pause() }

    func stop() {
        guard !isStopped else { return }
        retire()
        sink.finish()
    }

    private func retire() {
        isStopped = true
        try? engine.setConfigurationChangeHandler(nil)
        try? engine.stop()
        try? engine.removeTap()
        Self.retired.append(engine)
        if Self.retired.count > Self.retiredLimit { Self.retired.removeFirst() }
    }
}

/// AVCaptureSession on an exact device UID, for a microphone that is not the
/// macOS default. No voice processing.
@MainActor
final class CaptureSessionMicSource: MicSource {
    let plan: MicSourcePlan
    let sink: MicCaptureSink
    private let session: NativeMicCaptureSession
    private var isStarted = false
    private var isStopped = false

    init(plan: MicSourcePlan, sink: MicCaptureSink) throws {
        self.plan = plan
        self.sink = sink
        session = try NativeMicCaptureSession.make(deviceUID: plan.deviceUID)
    }

    var isRunning: Bool { isStarted && !isStopped && session.captureError == nil }

    func start() throws {
        try session.start(handler: MicSourceFactory.makeHandler(sink: sink))
        isStarted = true
    }

    /// Stops the session; `start()` restarts it. Stopping drains its callback queue.
    func pause() {
        try? session.stop()
        isStarted = false
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        try? session.stop()
        sink.finish()
    }
}

/// Tracks delivered buffers rather than sound level: a quiet microphone is
/// healthy while it keeps delivering; a dead route delivers nothing.
struct MicHealth {
    static let timeout: TimeInterval = 4
    private(set) var lastBuffers: Int64 = 0
    private(set) var lastProgress: Date

    init(now: Date) { lastProgress = now }

    mutating func reset(now: Date, buffers: Int64) {
        lastProgress = now
        lastBuffers = buffers
    }

    mutating func isStalled(now: Date, buffers: Int64) -> Bool {
        if buffers > lastBuffers {
            reset(now: now, buffers: buffers)
            return false
        }
        return now.timeIntervalSince(lastProgress) >= Self.timeout
    }
}
