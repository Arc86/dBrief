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

    private let systemLifecycle = SystemCaptureLifecycle()
    private var micEngine: AVAudioEngine?
    private var systemWriter: AudioTrackWriter?
    private var micWriter: AudioTrackWriter?
    private var micSink: MicCaptureSink?

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
    /// What the engine currently has applied — the idempotency snapshot fed to the planner.
    private var appliedInputUID: String = ""
    private var appliedVoiceProcessing = false

    private var configChangeObserver: NSObjectProtocol?
    private var outputMonitor: DefaultOutputDeviceMonitor?
    private var reconfigureDebounceTask: Task<Void, Never>?
    private static let reconfigureDebounceInterval: Duration = .milliseconds(400)

    /// Invoked (on the main actor) after an automatic reconfigure with a short,
    /// user-facing note (e.g. "Switched to MacBook Microphone"). Set by `RecordingManager`.
    var statusNoteHandler: (@MainActor (String) -> Void)?

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
                try startMicPipeline(writer: writer, inputDeviceUID: inputDeviceUID)
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
        guard isCapturing || systemLifecycle.isBusy || micEngine != nil
                || systemWriter != nil || micWriter != nil || micSink != nil
                || micLiveContinuation != nil || systemLiveContinuation != nil
        else { return }
        stopTimer()
        // Tear down observers before the engine is nilled (the config-change token
        // is bound to `micEngine`).
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
        if let micEngine {
            micEngine.inputNode.removeTap(onBus: 0)
            micEngine.stop()
            self.micEngine = nil
        }

        micSink?.finish()
        micSink = nil

        lastCaptureWriteDiagnostics = AudioCaptureWriteDiagnostics(
            system: systemWriter?.diagnostics ?? .init(),
            microphone: micWriter?.diagnostics ?? .init(),
            systemStreamFailures: lastSystemCaptureFailure == nil ? 0 : 1
        )
        systemWriter?.close(); systemWriter = nil
        micWriter?.close(); micWriter = nil

        finishLiveStreams()

        appliedInputUID = ""
        appliedVoiceProcessing = false
        startTime = nil
        pauseStartTime = nil
        isCapturing = false
        peakLevel = 0
        log.info("Recording stopped")
    }

    func pauseRecording() {
        guard isCapturing, pauseStartTime == nil else { return }
        micEngine?.pause()
        systemLifecycle.stop()
        pauseStartTime = Date()
        stopTimer()
    }

    func resumeRecording() throws {
        guard isCapturing, let pauseStart = pauseStartTime else { return }
        // A failed microphone restart leaves the capture logically paused.
        try micEngine?.start()
        pauseAccumulator += Date().timeIntervalSince(pauseStart)
        pauseStartTime = nil
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
        // `RecordingFinalizer`. It's further gated on a real speaker→mic echo
        // path (no-op on headphones, where it would just lower output volume).
        let wantVoiceProcessing = aecSettingEnabled
            && !hasSystemAudioPermission
            && AudioOutputRoute.currentOutputHasEchoPath()
        var achievedVoiceProcessing = false
        if wantVoiceProcessing {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                achievedVoiceProcessing = true
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

        let handler = try makeMicHandler(writer: writer, newFormat: inputFormat)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: handler)

        try engine.start()

        // Record the state actually achieved (the device may differ if a pinned UID
        // was missing) so the auto-reconfigure path is idempotent.
        appliedInputUID = (AudioInputDeviceManager.deviceID(forUID: selectedInputUID) != nil) ? selectedInputUID : ""
        appliedVoiceProcessing = achievedVoiceProcessing
        installChangeObservers()
        log.info("Mic capture started")
    }

    /// Retain each tap's sink so its converter can be drained before replacement
    /// or writer closure. The previous sink must be retired before installing this one.
    private func makeMicHandler(
        writer: AudioTrackWriter,
        newFormat: AVAudioFormat
    ) throws -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        var converter: MicFormatConverter?
        if let established = writer.establishedFormat,
           (established.sampleRate != newFormat.sampleRate || established.channelCount != newFormat.channelCount) {
            guard let created = MicFormatConverter(from: newFormat, to: established) else {
                throw AudioConversionError.unsupportedFormat
            }
            converter = created
        }
        let sink = MicCaptureSink(writer: writer, converter: converter, liveSink: micLiveContinuation)
        micSink = sink
        return { buffer, _ in sink.receive(buffer) }
    }

    /// Switch the microphone input device mid-recording without losing the in-progress
    /// mic track. Routes through the shared reconfigure path (re-point device, keep the
    /// established-format tap, optionally toggle VPIO). No-op when not recording or in a
    /// system-audio-only session.
    func switchMicrophoneDevice(to newUID: String?) throws {
        guard isCapturing, micEngine != nil, micWriter != nil else { return }
        selectedInputUID = newUID ?? ""
        // The user explicitly chose this device — treat it as present so a CoreAudio
        // enumeration race can't trigger the "device gone → default" fallback.
        try applyReconfigure(computeDecision(treatSelectedAsPresent: true))
    }

    /// Bridges the impure CoreAudio state into the pure `MicReconfigurePlanner`.
    private func computeDecision(treatSelectedAsPresent: Bool = false) -> MicReconfigureDecision {
        var available = Set(AudioInputDeviceManager.availableInputDevices().map(\.uid))
        if treatSelectedAsPresent, !selectedInputUID.isEmpty { available.insert(selectedInputUID) }
        return MicReconfigurePlanner.decide(
            selectedUID: selectedInputUID,
            availableInputUIDs: available,
            hasSystemAudioPermission: hasSystemAudioPermission,
            aecSettingEnabled: aecSettingEnabled,
            outputHasEchoPath: AudioOutputRoute.currentOutputHasEchoPath(),
            currentlyAppliedUID: appliedInputUID,
            currentlyVoiceProcessing: appliedVoiceProcessing
        )
    }

    /// Re-point the mic engine and/or toggle VPIO to reach `decision`, keeping the
    /// in-progress mic track continuous. Idempotent no-op unless a change is needed.
    /// Throws (after attempting to restore) only on a hard invalid-format failure.
    private func applyReconfigure(_ decision: MicReconfigureDecision) throws {
        guard isCapturing, let engine = micEngine, let writer = micWriter else { return }
        guard decision.needsReconfigure else { return }

        // Whether the engine SHOULD be running after reconfigure — based on user
        // pause state, NOT `engine.isRunning` (a config-change may have already
        // stopped it, but we still want to restart unless the user paused).
        let shouldRun = pauseStartTime == nil
        let vpioChanged = decision.voiceProcessingEnabled != appliedVoiceProcessing

        // Toggling VPIO requires a fully stopped engine; a device-only change can
        // use the cheaper pause.
        if vpioChanged { engine.stop() } else { engine.pause() }

        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        micSink?.finish()
        micSink = nil

        let targetUIDOrNil = decision.targetDeviceUID.isEmpty ? nil : decision.targetDeviceUID
        var deviceApplied = true
        do {
            try AudioInputDeviceManager.applyInputDevice(uid: targetUIDOrNil, to: engine)
        } catch {
            deviceApplied = false
            log.warning("Reconfigure: applyInputDevice failed: \(error.localizedDescription, privacy: .public)")
        }

        if vpioChanged {
            do {
                try inputNode.setVoiceProcessingEnabled(decision.voiceProcessingEnabled)
            } catch {
                log.warning("Reconfigure: setVoiceProcessingEnabled failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        let newFormat = inputNode.outputFormat(forBus: 0)
        guard newFormat.sampleRate > 0 else {
            log.error("Reconfigure: new device reports invalid format; attempting to restore")
            if shouldRun { try? engine.start() }
            throw AudioCaptureError.noMicrophoneAccess
        }

        let handler = try makeMicHandler(writer: writer, newFormat: newFormat)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: newFormat, block: handler)
        if shouldRun { try engine.start() }

        // Record the achieved state so the snapshot stays truthful AND the
        // reconfigure converges — a snapshot that can never match the desired state
        // would re-fire a full engine restart on every later benign config event.
        //
        // Device: only adopt the target if the switch actually took; on failure the
        // engine kept its previous device, so leave the snapshot unchanged.
        if deviceApplied { appliedInputUID = decision.targetDeviceUID }
        // VPIO: if the toggle refused (the route can't do Voice Processing), record
        // the DESIRED value rather than the stuck readback, so benign config events
        // don't keep retrying an impossible toggle. A genuine route change recomputes
        // a fresh target and retries then (turning VPIO *off* always succeeds).
        let achievedVPIO = inputNode.isVoiceProcessingEnabled
        if vpioChanged, achievedVPIO != decision.voiceProcessingEnabled {
            log.warning("Reconfigure: VPIO stuck at \(achievedVPIO, privacy: .public); suppressing retry until route changes")
        }
        appliedVoiceProcessing = vpioChanged ? decision.voiceProcessingEnabled : achievedVPIO
        log.info("Reconfigure: applied device=\(self.appliedInputUID.isEmpty ? "default" : self.appliedInputUID, privacy: .public) vpio=\(self.appliedVoiceProcessing, privacy: .public)")
    }

    // MARK: - Device/route change observers

    private func installChangeObservers() {
        guard let engine = micEngine else { return }
        removeChangeObservers()
        let lifetime = CaptureCallbackLifetime()
        observerLifetime = lifetime
        let changed = lifetime.handler { [weak self] in self?.scheduleReconfigure() }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in changed() }

        let monitor = DefaultOutputDeviceMonitor { changed() }
        monitor.start()
        outputMonitor = monitor
    }

    private func removeChangeObservers() {
        observerLifetime?.invalidate()
        observerLifetime = nil
        if let token = configChangeObserver {
            NotificationCenter.default.removeObserver(token)
            configChangeObserver = nil
        }
        outputMonitor?.stop()
        outputMonitor = nil
        reconfigureDebounceTask?.cancel()
        reconfigureDebounceTask = nil
    }

    /// Coalesces the burst of events a single device connect/disconnect produces,
    /// then reconfigures once if the desired state differs from what's applied.
    private func scheduleReconfigure() {
        guard let lifetime = observerLifetime, lifetime.isValid else { return }
        reconfigureDebounceTask?.cancel()
        reconfigureDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.reconfigureDebounceInterval)
            guard !Task.isCancelled, lifetime.isValid, let self else { return }
            // Don't churn a paused engine — `resumeRecording` reconciles on resume.
            guard self.isCapturing, self.pauseStartTime == nil else { return }
            let decision = self.computeDecision()
            guard decision.needsReconfigure else { return }
            let previousUID = self.appliedInputUID
            let previousVPIO = self.appliedVoiceProcessing
            do {
                try self.applyReconfigure(decision)
                self.emitStatusNote(from: previousUID, previousVPIO: previousVPIO, decision: decision)
            } catch {
                log.error("Auto reconfigure failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func emitStatusNote(from previousUID: String, previousVPIO: Bool, decision: MicReconfigureDecision) {
        let note: String
        if decision.targetDeviceUID != previousUID {
            note = "Switched to \(Self.deviceLabel(for: decision.targetDeviceUID))"
        } else if decision.voiceProcessingEnabled != previousVPIO {
            note = decision.voiceProcessingEnabled
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
