@preconcurrency import AVFoundation
import CoreGraphics
import CoreAudio
@preconcurrency import ScreenCaptureKit
import os

private let log = Logger.audio

@MainActor
@Observable
final class AudioCaptureManager {
    private(set) var isCapturing = false
    private(set) var duration: TimeInterval = 0
    private(set) var peakLevel: Float = 0

    private let systemLifecycle = SystemCaptureLifecycle()
    private var micSource: (any MicSource)?
    /// Shared by every mic source of one recording, so a switch's outage stays on the track.
    private let micTimeline = MicTimeline()
    private var micHealth = MicHealth(now: Date())
    private var micRecoveryAttempts = 0
    private static let maxMicRecoveryAttempts = 3
    /// A plan that started but delivered no audio and was replaced by its fallback.
    private var failedMicPlan: MicSourcePlan?
    /// The newest source's sink until its first buffer is journaled.
    private var micFirstBufferPending: (sink: MicCaptureSink, since: Date)?
    private var systemWriter: AudioTrackWriter?
    private var micWriter: AudioTrackWriter?

    private var timer: Timer?
    private var timerLifetime: CaptureCallbackLifetime?
    private var observerLifetime: CaptureCallbackLifetime?
    private var startTime: Date?
    private var pauseAccumulator: TimeInterval = 0
    private var pauseStartTime: Date?

    /// Raw `AppSettings.acousticEchoCancellation` (route-independent). VPIO is gated
    /// on this AND a real output echo path AND mic-only mode, recomputed on route change.
    private var aecSettingEnabled = true

    // MARK: - Mid-recording device/route reconfigure

    /// The user's chosen input UID (`""` == System Default), as last passed to
    /// `startRecording` / `switchMicrophoneDevice`. Drives the auto-follow decision.
    private var selectedInputUID: String = ""
    private var outputMonitor: DefaultOutputDeviceMonitor?
    private var inputMonitors: [DefaultOutputDeviceMonitor] = []
    private var reconfigureDebounceTask: Task<Void, Never>?
    private static let reconfigureDebounceInterval: Duration = .milliseconds(400)

    /// Invoked (on the main actor) after an automatic reconfigure with a short,
    /// user-facing note (e.g. "Switched to MacBook Microphone"). Set by `RecordingManager`.
    var statusNoteHandler: (@MainActor (String) -> Void)?

    /// Invoked (on the main actor) whenever the recording's mic source changes,
    /// with the device's name (nil once capture stops). Set by `RecordingManager`.
    var microphoneHandler: (@MainActor (String?) -> Void)?
    /// Name of the device the running mic source captures from.
    private(set) var activeMicrophoneName: String?

    /// Invoked (on the main actor) on each ~10 Hz meter tick with the current
    /// duration and peak level. Set by `RecordingManager` to push these into
    /// `AppState` — replacing a separate polling loop that mirrored the same two
    /// values, so there is one source of truth and one timer.
    var stateTickHandler: (@MainActor (_ duration: TimeInterval, _ peakLevel: Float) -> Void)?

    private(set) var hasSystemAudioPermission = false
    private(set) var hasMicrophonePermission = false
    private(set) var lastCaptureWriteDiagnostics = AudioCaptureWriteDiagnostics()
    private(set) var lastSystemCaptureFailure: DurabilityDiagnosticFailure?

    /// URLs of the two track files written during the last recording.
    /// Cleared only by the next `startRecording`.
    private(set) var trackURLs: CapturedTracks?

    /// Live audio sinks for real-time transcription. Non-nil only while live
    /// transcription is enabled for the current recording. The tap handlers
    /// yield deep-copied buffers here in addition to writing the CAF tracks.
    private var micLiveContinuation: AsyncStream<LiveAudioBuffer>.Continuation?
    private var systemLiveContinuation: AsyncStream<LiveAudioBuffer>.Continuation?

    /// Bound on buffered live audio. Live transcription is an explicitly lossy
    /// preview, so we cap the queue and drop the oldest buffers rather than let
    /// it grow without bound — e.g. while a first-run language asset downloads,
    /// the consumer (`SpeechAnalyzer`) hasn't started yet and buffers would
    /// otherwise accumulate in RAM until it does. ~64 tap buffers (≈ a few
    /// seconds at 4096 frames) is plenty of slack for a real-time consumer.
    private static let liveBufferLimit = 64

    /// Creates fresh live audio streams (mic + system) for real-time transcription.
    /// MUST be called *before* `startRecording` so the tap handlers capture the sinks.
    /// The streams stay open across pause/resume and are finished by `stopRecording`.
    func makeLiveAudioStreams() -> (mic: AsyncStream<LiveAudioBuffer>, system: AsyncStream<LiveAudioBuffer>) {
        let mic = AsyncStream<LiveAudioBuffer>(bufferingPolicy: .bufferingNewest(Self.liveBufferLimit)) { continuation in
            self.micLiveContinuation = continuation
        }
        let system = AsyncStream<LiveAudioBuffer>(bufferingPolicy: .bufferingNewest(Self.liveBufferLimit)) { continuation in
            self.systemLiveContinuation = continuation
        }
        return (mic, system)
    }

    private func finishLiveStreams() {
        micLiveContinuation?.finish(); micLiveContinuation = nil
        systemLiveContinuation?.finish(); systemLiveContinuation = nil
    }

    var microphoneAuthorizationState: PermissionAuthorizationState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .granted
        @unknown default: .restricted
        }
    }

    /// Refreshes current TCC state without presenting a system prompt.
    func refreshPermissions() {
        hasMicrophonePermission = microphoneAuthorizationState.isGranted
        hasSystemAudioPermission = CGPreflightScreenCaptureAccess()
        if !hasSystemAudioPermission {
            log.warning("Screen recording permission not granted")
        }
    }

    /// Kept async for existing callers; unlike the old implementation this is a
    /// status refresh only and is safe to call during app initialization.
    func checkPermissions() async {
        refreshPermissions()
    }

    /// Explicit user-initiated microphone permission request.
    @discardableResult
    func requestMicrophonePermission() async -> Bool {
        let granted = await Self.requestMicAccess()
        hasMicrophonePermission = granted
        return granted
    }

    /// Starts recording. `baseURL` is WITHOUT extension — the manager appends
    /// `_system.caf` and `_mic.caf` internally.
    func startRecording(
        to baseURL: URL,
        inputDeviceUID: String? = nil,
        acousticEchoCancellationEnabled: Bool = true
    ) async throws {
        guard !isCapturing else { return }

        // A denied/failed new attempt must not report the previous capture's
        // tracks or diagnostics. Preserve live sinks installed before this call.
        trackURLs = nil
        startTime = nil
        pauseStartTime = nil
        pauseAccumulator = 0
        duration = 0
        peakLevel = 0
        lastCaptureWriteDiagnostics = AudioCaptureWriteDiagnostics()
        lastSystemCaptureFailure = nil
        systemLifecycle.resetFailure()

        refreshPermissions()
        // A recording action can serve as the explicit microphone request when
        // no other source is available. Do not prompt a user who deliberately
        // configured system-audio-only recording.
        if !hasSystemAudioPermission, microphoneAuthorizationState == .notDetermined {
            _ = await requestMicrophonePermission()
        }

        guard hasMicrophonePermission || hasSystemAudioPermission else {
            throw AudioCaptureError.noMicrophoneAccess
        }

        let stem = baseURL.deletingPathExtension()
        let systemURL = stem.appendingPathExtension("system.caf")
        let micURL = stem.appendingPathExtension("mic.caf")

        aecSettingEnabled = acousticEchoCancellationEnabled
        selectedInputUID = inputDeviceUID ?? ""
        trackURLs = CapturedTracks(
            systemURL: hasSystemAudioPermission ? systemURL : nil,
            micURL: hasMicrophonePermission ? micURL : nil
        )
        log.info("Starting recording — system=\(self.hasSystemAudioPermission, privacy: .public) mic=\(self.hasMicrophonePermission, privacy: .public)")

        do {
            if hasSystemAudioPermission {
                let writer = AudioTrackWriter(url: systemURL, role: .system)
                self.systemWriter = writer
                try await startSystemPipeline(writer: writer)
            }
            if hasMicrophonePermission {
                let writer = AudioTrackWriter(url: micURL, role: .mic)
                self.micWriter = writer
                try startMicPipeline()
            }
        } catch {
            // Capture setup is transactional. A system stream can already be
            // running when mic setup fails; close every partial pipeline so its
            // recovery files remain readable instead of leaking live resources.
            await stopRecording()
            throw error
        }

        isCapturing = true
        startTime = Date()
        startTimer()
        log.info("Recording started")
    }

    func stopRecording() async {
        guard isCapturing || systemLifecycle.isBusy || micSource != nil
                || systemWriter != nil || micWriter != nil
                || micLiveContinuation != nil || systemLiveContinuation != nil
        else { return }
        stopTimer()
        removeChangeObservers()

        // Compute the final duration directly from the wall clock rather than
        // trusting the last value the live timer happened to write — the timer
        // can be starved if the run loop is busy, leaving `duration` at 0.
        if let startTime {
            let now = Date()
            var elapsed = now.timeIntervalSince(startTime) - pauseAccumulator
            if let pauseStart = pauseStartTime {
                elapsed -= now.timeIntervalSince(pauseStart)
            }
            duration = max(0, elapsed)
        }

        // Includes any suspended restart and its stale-stream cleanup. Writers
        // must outlive every operation that can attach or start their stream.
        await systemLifecycle.stop().value
        lastSystemCaptureFailure = systemLifecycle.lastFailure
        // Stops delivery and drains the converter before the writer closes.
        retireMicSource()
        activeMicrophoneName = nil
        microphoneHandler?(nil)
        micTimeline.reset()
        failedMicPlan = nil
        micRecoveryAttempts = 0

        lastCaptureWriteDiagnostics = AudioCaptureWriteDiagnostics(
            system: systemWriter?.diagnostics ?? .init(),
            microphone: micWriter?.diagnostics ?? .init(),
            systemStreamFailures: lastSystemCaptureFailure == nil ? 0 : 1
        )
        systemWriter?.close(); systemWriter = nil
        micWriter?.close(); micWriter = nil

        finishLiveStreams()

        startTime = nil
        pauseStartTime = nil
        isCapturing = false
        peakLevel = 0
        log.info("Recording stopped")
    }

    func pauseRecording() {
        guard isCapturing, pauseStartTime == nil else { return }
        micSource?.pause()
        // Both tracks stop together, so the pause is not a gap to pad.
        micTimeline.reset()
        systemLifecycle.stop()
        pauseStartTime = Date()
        stopTimer()
    }

    func resumeRecording() throws {
        guard isCapturing, let pauseStart = pauseStartTime else { return }
        // Reconcile device changes made while paused before starting, so the
        // previous device is never restarted. Decide while still paused: a paused
        // source is not a failed one. A failed restart leaves the capture paused.
        let decision = micWriter == nil ? nil : computeDecision()
        pauseStartTime = nil
        do {
            if let decision, decision.needsReconfigure, let plan = decision.plan {
                try activateMicSource(plan)
            } else {
                try micSource?.start()
                micHealth.reset(now: Date(), buffers: micSource?.sink.buffersReceived ?? 0)
            }
        } catch {
            pauseStartTime = pauseStart
            throw error
        }
        pauseAccumulator += Date().timeIntervalSince(pauseStart)
        if hasSystemAudioPermission, let systemWriter {
            restartSystemCapture(writer: systemWriter, onFailure: { error in
                log.error("Failed to resume system capture: \(error.localizedDescription, privacy: .public)")
            })
        }
        startTimer()
        // Reconcile any device/route change that happened while paused.
        scheduleReconfigure()
    }

    // MARK: - System pipeline

    private func startSystemPipeline(writer: AudioTrackWriter) async throws {
        try await restartSystemCapture(writer: writer).value
    }

    @discardableResult
    private func restartSystemCapture(
        writer: AudioTrackWriter,
        onFailure: @escaping @MainActor (Error) -> Void = { _ in }
    ) -> Task<Void, Error> {
        // Freeze sinks and callbacks before the content-filter suspension.
        let liveSink = systemLiveContinuation
        let status = statusNoteHandler
        return systemLifecycle.start(make: { [weak self] id in
            let filter = try await SystemAudioCapture.createContentFilter()
            let capture = try SystemAudioCapture(filter: filter)
            capture.audioBufferHandler = Self.makeSystemHandler(writer: writer, liveSink: liveSink)
            capture.unexpectedStopHandler = { [weak self] failure in
                Task { @MainActor [weak self] in
                    guard let self, self.systemLifecycle.accepts(id) else { return }
                    self.systemLifecycle.reportFailure(failure, from: id)
                    self.lastSystemCaptureFailure = failure
                    DurabilityJournal.shared.record(.init(
                        name: "system_capture_stopped_unexpectedly", outcome: .failed, failure: failure))
                    status?("System audio capture stopped unexpectedly")
                }
            }
            return .init(id: id, start: {
                try await capture.start()
                log.info("System capture started")
            }, stop: {
                try? await capture.stop()
                return capture.unexpectedStopFailure
            })
        }, onFailure: onFailure)
    }

    private nonisolated static func makeSystemHandler(
        writer: AudioTrackWriter,
        liveSink: AsyncStream<LiveAudioBuffer>.Continuation?
    ) -> @Sendable (CMSampleBuffer) -> Void {
        return { sampleBuffer in
            guard let pcm = sampleBuffer.toPCMBuffer() else { return }
            do {
                try writer.write(pcm)
            } catch {
                log.error("System write error: \(error.localizedDescription, privacy: .public)")
            }
            // `toPCMBuffer()` already allocates a fresh buffer each callback and the
            // writer is done with it synchronously above, so it can be handed to the
            // live consumer directly — no second copy needed (unlike the mic tap,
            // whose buffer storage AVAudioEngine reuses across callbacks).
            if let liveSink { liveSink.yield(LiveAudioBuffer(pcm)) }
        }
    }

    // MARK: - Mic pipeline

    private func startMicPipeline() throws {
        micTimeline.reset()
        let decision = computeDecision()
        guard let plan = decision.plan else { throw AudioCaptureError.noMicrophoneAccess }
        try activateMicSource(plan)
        installChangeObservers()
        log.info("Mic capture started")
    }

    /// Switch the microphone input device mid-recording without losing the in-progress
    /// mic track. No-op when not recording or in a system-audio-only session; while
    /// paused the selection is applied on resume.
    func switchMicrophoneDevice(to newUID: String?) throws {
        guard isCapturing, micWriter != nil else { return }
        selectedInputUID = newUID ?? ""
        failedMicPlan = nil
        micRecoveryAttempts = 0
        guard pauseStartTime == nil else { return }
        // The menu offered this device, so treat it as present: an enumeration
        // race must not turn an explicit choice into the gone→default fallback.
        let decision = computeDecision(assumingPresent: selectedInputUID)
        guard decision.needsReconfigure, let plan = decision.plan else { return }
        try activateMicSource(plan)
        if let name = activeMicrophoneName { statusNoteHandler?("Recording from \(name)") }
    }

    /// Bridges the impure CoreAudio state into the pure `MicReconfigurePlanner`.
    private func computeDecision(assumingPresent uid: String = "") -> MicReconfigureDecision {
        var available = Set(AudioInputDeviceManager.availableInputDevices().map(\.uid))
        if !uid.isEmpty { available.insert(uid) }
        return MicReconfigurePlanner.decide(
            selectedUID: selectedInputUID,
            availableInputUIDs: available,
            defaultInputUID: AudioInputDeviceManager.defaultInputDeviceUID(),
            hasSystemAudioPermission: hasSystemAudioPermission,
            aecSettingEnabled: aecSettingEnabled,
            outputHasEchoPath: AudioOutputRoute.currentOutputHasEchoPath(),
            applied: micSource?.plan,
            sourceFailed: (micSource.map { !$0.isRunning } ?? false) && pauseStartTime == nil
        )
    }

    /// Replaces the running mic source with a new one for `plan`, keeping the
    /// in-progress track. If `plan` can't be built or started, its fallback is
    /// tried once; if that fails too, the previous source is restored where
    /// possible and the error is rethrown.
    private func activateMicSource(_ plan: MicSourcePlan) throws {
        let previous = micSource?.plan
        do {
            try replaceMicSource(with: plan)
        } catch {
            log.error("Mic source \(String(describing: plan.backend), privacy: .public) failed to start: \(error.localizedDescription, privacy: .public)")
            if let fallback = MicReconfigurePlanner.fallback(
                after: plan, defaultInputUID: AudioInputDeviceManager.defaultInputDeviceUID()
            ), (try? replaceMicSource(with: fallback)) != nil {
                failedMicPlan = plan
                return
            }
            if let previous, previous != plan { try? replaceMicSource(with: previous) }
            throw error
        }
    }

    private func replaceMicSource(with plan: MicSourcePlan) throws {
        guard let writer = micWriter else { return }
        retireMicSource()
        let sink = MicCaptureSink(writer: writer, timeline: micTimeline, liveSink: micLiveContinuation)
        // Engine route changes arrive on an AVFAudio thread; `scheduleReconfigure`
        // ignores them once the recording's observers are removed.
        let configurationChanged: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleReconfigure() }
        }
        let began = Date()
        let source: any MicSource
        do {
            source = try MicSourceFactory.make(plan, sink: sink, onConfigurationChange: configurationChanged)
            if pauseStartTime == nil {
                do {
                    try source.start()
                } catch {
                    source.stop()
                    throw error
                }
            }
        } catch {
            sink.finish()
            Self.journalMic("microphone_source_started", .failed, plan, since: began, error: error)
            throw error
        }
        micSource = source
        activeMicrophoneName = Self.deviceLabel(for: plan.deviceUID)
        microphoneHandler?(activeMicrophoneName)
        micHealth.reset(now: Date(), buffers: 0)
        micFirstBufferPending = (source.sink, Date())
        let silenced = AudioInputDeviceManager.isInputSilenced(uid: plan.deviceUID)
        Self.journalMic("microphone_source_started", .succeeded, plan, since: began,
                        extra: ["deviceSilenced": silenced ? 1 : 0])
        if silenced {
            log.error("Mic source device is muted or at zero input volume in macOS")
            statusNoteHandler?("\(Self.deviceLabel(for: plan.deviceUID)) is muted in macOS — check Sound settings")
        }
        log.notice("Mic source: \(String(describing: plan.backend), privacy: .public) device=\(plan.deviceUID, privacy: .public) vpio=\(plan.voiceProcessing, privacy: .public)")
    }

    /// Persisted (Application Support/Diagnostics) so a switching failure leaves
    /// evidence even where the unified log is unreadable. No device names or audio.
    private static func journalMic(
        _ name: String, _ outcome: DurabilityEvent.Outcome, _ plan: MicSourcePlan,
        since start: Date? = nil, error: Error? = nil, extra: [String: Int64] = [:]
    ) {
        var measurements = extra
        measurements["captureSession"] = plan.backend == .captureSession ? 1 : 0
        measurements["voiceProcessing"] = plan.voiceProcessing ? 1 : 0
        measurements["systemDefault"] = plan.deviceUID == AudioInputDeviceManager.defaultInputDeviceUID() ? 1 : 0
        if let start { measurements["milliseconds"] = Int64(Date().timeIntervalSince(start) * 1000) }
        DurabilityJournal.shared.record(.init(
            name: name, outcome: outcome, measurements: measurements, failure: error.map { .init(error: $0) }
        ))
    }

    private func retireMicSource() {
        micSource?.stop()
        micSource = nil
    }

    /// Runs on the meter tick. A source that never delivers is replaced by its
    /// fallback; one that stops delivering is rebuilt, a bounded number of times.
    private func checkMicHealth() {
        guard isCapturing, pauseStartTime == nil, let source = micSource,
              reconfigureDebounceTask == nil else { return }
        let buffers = source.sink.buffersReceived
        let now = Date()
        if buffers > 0, let pending = micFirstBufferPending, pending.sink === source.sink {
            micFirstBufferPending = nil
            Self.journalMic("microphone_first_buffer", .succeeded, source.plan, since: pending.since)
        }
        guard micHealth.isStalled(now: now, buffers: buffers) else {
            if buffers > 0 { micRecoveryAttempts = 0 }
            return
        }
        micHealth.reset(now: now, buffers: buffers)
        let plan = source.plan
        Self.journalMic("microphone_stall", .warning, plan, extra: ["buffers": buffers, "attempt": Int64(micRecoveryAttempts)])
        // A source that never delivered gets one alternative backend/device; a
        // fallback that fails in turn is only rebuilt, never cycled back.
        if buffers == 0, failedMicPlan == nil, let fallback = MicReconfigurePlanner.fallback(
            after: plan, defaultInputUID: AudioInputDeviceManager.defaultInputDeviceUID()
        ) {
            log.error("Mic source delivered no audio; falling back to \(String(describing: fallback.backend), privacy: .public)")
            failedMicPlan = plan
            do {
                try replaceMicSource(with: fallback)
                statusNoteHandler?("Recording from \(Self.deviceLabel(for: fallback.deviceUID))")
            } catch {
                log.error("Mic fallback failed: \(error.localizedDescription, privacy: .public)")
                statusNoteHandler?("Microphone isn't delivering audio — check input device")
            }
            return
        }
        guard micRecoveryAttempts < Self.maxMicRecoveryAttempts else { return }
        micRecoveryAttempts += 1
        log.error("Mic source stalled; rebuilding (attempt \(self.micRecoveryAttempts, privacy: .public))")
        do {
            try replaceMicSource(with: plan)
        } catch {
            log.error("Mic rebuild failed: \(error.localizedDescription, privacy: .public)")
        }
        if micRecoveryAttempts == Self.maxMicRecoveryAttempts {
            statusNoteHandler?("Microphone isn't delivering audio — check input device")
        }
    }

    // MARK: - Device/route change observers

    private func installChangeObservers() {
        removeChangeObservers()
        let lifetime = CaptureCallbackLifetime()
        observerLifetime = lifetime
        let changed = lifetime.handler { [weak self] in self?.scheduleReconfigure() }
        let monitor = DefaultOutputDeviceMonitor { changed() }
        monitor.start()
        outputMonitor = monitor
        inputMonitors = [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices].map { selector in
            let monitor = DefaultOutputDeviceMonitor(selector: selector) { changed() }
            monitor.start()
            return monitor
        }
    }

    private func removeChangeObservers() {
        observerLifetime?.invalidate()
        observerLifetime = nil
        outputMonitor?.stop()
        outputMonitor = nil
        inputMonitors.forEach { $0.stop() }
        inputMonitors.removeAll()
        reconfigureDebounceTask?.cancel()
        reconfigureDebounceTask = nil
    }

    /// Coalesces the burst of events a single device connect/disconnect produces,
    /// then reconfigures once if the desired state differs from what's running.
    private func scheduleReconfigure() {
        guard let lifetime = observerLifetime, lifetime.isValid else { return }
        reconfigureDebounceTask?.cancel()
        reconfigureDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.reconfigureDebounceInterval)
            guard !Task.isCancelled, lifetime.isValid, let self else { return }
            defer { self.reconfigureDebounceTask = nil }
            // Don't churn a paused capture — `resumeRecording` reconciles on resume.
            guard self.isCapturing, self.pauseStartTime == nil, self.micWriter != nil else { return }
            let decision = self.computeDecision()
            guard decision.needsReconfigure, let plan = decision.plan else { return }
            // A plan that just failed and was replaced by its fallback stays
            // replaced until the devices change or the user picks again.
            if plan == self.failedMicPlan, self.micSource?.isRunning == true { return }
            if plan != self.failedMicPlan { self.failedMicPlan = nil }
            let previous = self.micSource?.plan
            // Rebuilding the same plan means the source stopped itself (a route
            // change can stop the engine). Bound it so a route that keeps
            // stopping can't rebuild forever; delivery resets the budget.
            if plan == previous {
                guard self.micRecoveryAttempts < Self.maxMicRecoveryAttempts else { return }
                self.micRecoveryAttempts += 1
                if self.micRecoveryAttempts == Self.maxMicRecoveryAttempts {
                    self.statusNoteHandler?("Microphone isn't delivering audio — check input device")
                }
            }
            do {
                try self.activateMicSource(plan)
                self.emitStatusNote(from: previous, to: self.micSource?.plan)
            } catch {
                log.error("Auto reconfigure failed: \(error.localizedDescription, privacy: .public)")
                self.statusNoteHandler?("Microphone switch failed")
            }
        }
    }

    private func emitStatusNote(from previous: MicSourcePlan?, to current: MicSourcePlan?) {
        guard let current else { return }
        let note: String
        if current.deviceUID != previous?.deviceUID {
            note = "Switched to \(Self.deviceLabel(for: current.deviceUID))"
        } else if current.voiceProcessing != previous?.voiceProcessing {
            note = current.voiceProcessing
                ? "Echo cancellation re-enabled"
                : "Echo cancellation off — headphones detected"
        } else {
            return
        }
        statusNoteHandler?(note)
    }

    /// Human label for a device UID; resolves the actual default device name when empty.
    private static func deviceLabel(for uid: String) -> String {
        if uid.isEmpty {
            return AudioInputDeviceManager.defaultInputDeviceName() ?? "System Default"
        }
        return AudioInputDeviceManager.availableInputDevices().first { $0.uid == uid }?.displayName ?? "microphone"
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
        // Add the timer in `.common` modes so it keeps firing while the run loop
        // is in a tracking mode (e.g. the menu-bar popover is open) — otherwise
        // the live duration/peak readout freezes during recording.
        stopTimer()
        let lifetime = CaptureCallbackLifetime()
        timerLifetime = lifetime
        let tick = stateTickHandler
        let update = lifetime.handler { [weak self] in
            guard let self, let startTime = self.startTime else { return }
            self.duration = Date().timeIntervalSince(startTime) - self.pauseAccumulator
            self.peakLevel = max(self.micWriter?.consumePeakLevel() ?? 0, self.systemWriter?.consumePeakLevel() ?? 0)
            tick?(self.duration, self.peakLevel)
            self.checkMicHealth()
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in update() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timerLifetime?.invalidate()
        timerLifetime = nil
        timer?.invalidate()
        timer = nil
    }
}

/// A deep-copied PCM buffer carried over the live-audio `AsyncStream`. Wrapping it
/// makes the stream `Sendable` (so it can cross from the main actor into the
/// transcription actor without `sending` gymnastics): the buffer is freshly
/// allocated by `deepCopy()`, owned exclusively by the live consumer, and never
/// mutated after the copy — so `@unchecked Sendable` is sound.
struct LiveAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

extension AVAudioPCMBuffer {
    /// Allocates a new buffer with the same format and copies the raw frame data,
    /// so the copy can safely outlive a tap's reused storage. Handles both
    /// interleaved and non-interleaved layouts by copying each audio buffer.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        copy.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard src.count == dst.count else { return nil }
        for i in 0..<src.count {
            guard let s = src[i].mData, let d = dst[i].mData else { continue }
            memcpy(d, s, Int(src[i].mDataByteSize))
            dst[i].mDataByteSize = src[i].mDataByteSize
        }
        return copy
    }
}
