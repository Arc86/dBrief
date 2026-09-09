import Foundation
import dBriefWire

/// Owns one capture attempt through startup, terminal hardware shutdown, durable
/// checkpoint and UI handoff. Hardware stays on MainActor; storage stays in its actor.
@MainActor @Observable
final class CaptureCoordinator {
    struct Request: Sendable {
        let id: UUID
        let startedAt: Date
        var inputDeviceUID: String? = nil
        var acousticEchoCancellation = true
        var echoSuppression = false
        var liveTranscription = false
        var language = ""
        var associatedApp: String? = nil
        var callBundleID: String? = nil
        var showMiniPlayer = false
        var prewarmWhisper: WhisperRuntimeConfig? = nil
        var privacyScope: RecordingPrivacyScope? = nil
    }
    struct LiveStreams: Sendable {
        let mic: AsyncStream<LiveAudioBuffer>
        let system: AsyncStream<LiveAudioBuffer>
    }
    enum Event {
        case prepared(Request, CaptureSessionStore.Session)
        case started(Request)
        case stopped(CaptureSessionStore.StoppedCapture, terminating: Bool)
        case failed(UUID)
        case paused(UUID)
        case resumed(UUID)
        case liveBegan(UUID)
        case liveEnded(UUID)
        case live(UUID, CaptureLivePreview.Event)
        case meter(UUID, Double, Float)
        case status(UUID, String?)
    }
    enum Failure: LocalizedError {
        case busy, terminating
        var errorDescription: String? {
            switch self {
            case .busy: "A recording is already starting, running or stopping."
            case .terminating: "The app is shutting down."
            }
        }
    }
    enum HardwareEvent: Sendable {
        case meter(Double, Float)
        case status(String)
    }
    typealias HardwareSink = @MainActor @Sendable (HardwareEvent) -> Void
    struct Permissions: Sendable {
        var refresh: @MainActor @Sendable () -> Void = {}
        var requestMicrophone: @MainActor @Sendable () async -> Bool = { false }
        var microphone: @MainActor @Sendable () -> Bool = { false }
        var systemAudio: @MainActor @Sendable () -> Bool = { false }
        var authorization: @MainActor @Sendable () -> PermissionAuthorizationState = { .notDetermined }
    }
    struct Hardware: Sendable {
        var start: @MainActor @Sendable (Request, URL) async throws -> LiveStreams?
        var stop: @MainActor @Sendable () async -> Void
        var snapshot: @MainActor @Sendable () -> CaptureSessionStore.CaptureState
        var pause: @MainActor @Sendable () -> Void
        var resume: @MainActor @Sendable () throws -> Void
        var switchInputDevice: @MainActor @Sendable (String?) throws -> Void
        var bindEvents: @MainActor @Sendable (HardwareSink?) -> Void = { _ in }
        var permissions = Permissions()

        static func live(_ audio: AudioCaptureManager) -> Self {
            var result = Self(start: { request, url in
                let streams = request.liveTranscription ? audio.makeLiveAudioStreams() : nil
                try await audio.startRecording(to: url, inputDeviceUID: request.inputDeviceUID,
                                               acousticEchoCancellationEnabled: request.acousticEchoCancellation)
                return streams.map { .init(mic: $0.mic, system: $0.system) }
            }, stop: { await audio.stopRecording() }, snapshot: {
                .init(tracks: audio.trackURLs, duration: audio.duration,
                      microphoneEnabled: audio.hasMicrophonePermission, systemAudioEnabled: audio.hasSystemAudioPermission,
                      writes: audio.lastCaptureWriteDiagnostics, failure: audio.lastSystemCaptureFailure)
            }, pause: { audio.pauseRecording() }, resume: { try audio.resumeRecording() },
            switchInputDevice: { try audio.switchMicrophoneDevice(to: $0) })
            result.bindEvents = { sink in
                if let sink {
                    audio.stateTickHandler = { duration, peak in sink(.meter(duration, peak)) }
                    audio.statusNoteHandler = { sink(.status($0)) }
                } else {
                    audio.stateTickHandler = nil
                    audio.statusNoteHandler = nil
                }
            }
            result.permissions = .init(refresh: { audio.refreshPermissions() },
                requestMicrophone: { await audio.requestMicrophonePermission() },
                microphone: { audio.hasMicrophonePermission }, systemAudio: { audio.hasSystemAudioPermission },
                authorization: { audio.microphoneAuthorizationState })
            return result
        }
    }
    struct Persistence: Sendable {
        var create: @Sendable (UUID, Date) async throws -> CaptureSessionStore.Session
        var began: @Sendable (CaptureSessionStore.Session, CaptureSessionStore.CaptureState) async throws -> Void
        var failedStart: @Sendable (CaptureSessionStore.Session, CaptureSessionStore.CaptureState, DurabilityDiagnosticFailure) async -> Void
        var stopped: @Sendable (CaptureSessionStore.Session, CaptureSessionStore.CaptureState, Bool) async -> CaptureSessionStore.StoppedCapture
        var termination: @Sendable (CaptureSessionStore.StoppedCapture) async -> Void
        var pauseResume: @Sendable (CaptureSessionStore.Session, CaptureSessionStore.CaptureState, Bool) async -> Void

        static func live(_ store: CaptureSessionStore) -> Self {
            .init(create: { try await store.create(id: $0, startedAt: $1) },
                  began: { try await store.began($0, state: $1) },
                  failedStart: { await store.failedStart($0, state: $1, failure: $2) },
                  stopped: { await store.stopped($0, state: $1, terminating: $2) },
                  termination: { await store.recordTermination($0) },
                  pauseResume: { await store.pauseResume($0, state: $1, paused: $2) })
        }
    }
    @MainActor private final class Attempt {
        let request: Request
        var session: CaptureSessionStore.Session?
        var startup: Task<Void, Error>?
        var terminal: Task<Void, Never>?
        var checkpoints: Task<Void, Never>?
        var preview: CaptureLivePreview.Session?
        var previewStart: Task<Void, Never>?
        var previewStop: Task<Void, Never>?
        var statusClear: Task<Void, Never>?
        var isActive = false
        var isPaused = false
        var wantsStop = false
        var hardwareDispatched = false
        var failure: Error?
        init(_ request: Request) { self.request = request }
    }

    private let hardware: Hardware
    private let persistence: Persistence
    private let preview: CaptureLivePreview
    private let sleep: @Sendable (Duration) async throws -> Void
    private let onEvent: (Event) -> Void
    @ObservationIgnored private var attempt: Attempt?
    private(set) var recordingID: UUID?
    private(set) var isStopping = false
    /// Once quit begins, background call detection may not start another capture.
    private(set) var isTerminating = false
    var isBusy: Bool { recordingID != nil || isTerminating }

    init(hardware: Hardware, persistence: Persistence,
         preview: CaptureLivePreview = .live(),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         onEvent: @escaping (Event) -> Void) {
        self.hardware = hardware
        self.persistence = persistence
        self.onEvent = onEvent
        self.preview = preview
        self.sleep = sleep
    }

    func refreshPermissions() { hardware.permissions.refresh() }
    func requestMicrophonePermission() async -> Bool { await hardware.permissions.requestMicrophone() }
    var hasMicrophonePermission: Bool { hardware.permissions.microphone() }
    var hasSystemAudioPermission: Bool { hardware.permissions.systemAudio() }
    var microphoneAuthorizationState: PermissionAuthorizationState { hardware.permissions.authorization() }

    func start(_ request: Request) async throws {
        try Task.checkCancellation()
        guard !isTerminating else { throw Failure.terminating }
        guard attempt == nil else { throw Failure.busy }
        let owned = Attempt(request)
        attempt = owned
        recordingID = request.id
        let startup = Task { @MainActor in
            do { try await self.startOwned(owned) }
            catch { owned.failure = error; throw error }
        }
        owned.startup = startup
        do {
            try await withTaskCancellationHandler {
                try await startup.value
            } onCancel: {
                // The token is captured before suspension. A late cancellation
                // handler can never target a replacement attempt.
                Task { @MainActor [weak self] in
                    guard let self, self.attempt === owned else { return }
                    _ = self.terminalTask(owned)
                }
            }
            if Task.isCancelled || owned.wantsStop {
                await terminalTask(owned).value
                try Task.checkCancellation()
            }
        } catch {
            await terminalTask(owned).value
            try Task.checkCancellation()
            throw error
        }
    }

    func stop(terminating: Bool = false) async {
        if terminating { isTerminating = true }
        guard let owned = attempt else { return }
        await terminalTask(owned).value
    }

    func pause() {
        guard let owned = controllableAttempt, !owned.isPaused else { return }
        hardware.pause()
        owned.isPaused = true
        enqueueCheckpoint(owned, paused: true)
        onEvent(.paused(owned.request.id))
    }

    func resume() throws {
        guard let owned = controllableAttempt, owned.isPaused else { return }
        try hardware.resume()
        owned.isPaused = false
        enqueueCheckpoint(owned, paused: false)
        onEvent(.resumed(owned.request.id))
    }

    func switchInputDevice(to uid: String?) throws {
        guard controllableAttempt != nil else { return }
        try hardware.switchInputDevice(uid)
    }

    private var controllableAttempt: Attempt? {
        guard let owned = attempt, owned.isActive, !owned.wantsStop, !isTerminating else { return nil }
        return owned
    }

    private func enqueueCheckpoint(_ owned: Attempt, paused: Bool) {
        guard let session = owned.session else { return }
        let previous = owned.checkpoints, state = hardware.snapshot(), persistence = persistence
        owned.checkpoints = Task {
            await previous?.value
            await persistence.pauseResume(session, state, paused)
        }
    }

    private func startOwned(_ owned: Attempt) async throws {
        let session = try await persistence.create(owned.request.id, owned.request.startedAt)
        owned.session = session
        onEvent(.prepared(owned.request, session))
        guard !owned.wantsStop else { return }
        hardware.bindEvents { [weak self, weak owned] event in
            guard let self, let owned else { return }
            self.receiveHardware(event, owned: owned)
        }
        owned.hardwareDispatched = true
        let streams = try await hardware.start(owned.request, session.files.captureBaseURL)
        guard !owned.wantsStop else { return }
        let state = hardware.snapshot()
        try await persistence.began(session, state)
        guard !owned.wantsStop else { return }
        owned.isActive = true
        onEvent(.started(owned.request))
        guard !owned.wantsStop else { return }
        if owned.request.liveTranscription, let streams { startPreview(owned, streams: streams, state: state) }
    }

    private func acceptsEvents(_ owned: Attempt) -> Bool {
        attempt === owned && !owned.wantsStop
    }

    private func receiveHardware(_ event: HardwareEvent, owned: Attempt) {
        guard acceptsEvents(owned) else { return }
        switch event {
        case .meter(let duration, let peak):
            guard owned.isActive, !owned.isPaused else { return }
            onEvent(.meter(owned.request.id, duration, peak))
        case .status(let message):
            owned.statusClear?.cancel()
            let sleep = sleep
            owned.statusClear = Task { @MainActor [weak self, weak owned] in
                do { try await sleep(.seconds(4)) } catch { return }
                guard !Task.isCancelled, let self, let owned, self.acceptsEvents(owned) else { return }
                self.onEvent(.status(owned.request.id, nil))
            }
            onEvent(.status(owned.request.id, message))
        }
    }

    private func startPreview(_ owned: Attempt, streams: LiveStreams, state: CaptureSessionStore.CaptureState) {
        let session = preview.make(), prepare = preview.prepare
        let input = CaptureLivePreview.Inputs(mic: state.microphoneEnabled ? streams.mic : nil,
            system: state.systemAudioEnabled ? streams.system : nil, language: owned.request.language)
        owned.preview = session
        owned.previewStart = Task { @MainActor [weak self, weak owned] in
            guard !Task.isCancelled, let self, let owned, self.acceptsEvents(owned) else { return }
            let context = await prepare(owned.request)
            guard !Task.isCancelled, self.acceptsEvents(owned) else { return }
            await PrivacyTrace.$context.withValue(context) {
                await session.start(input) { [weak self, weak owned] event in
                    Task { @MainActor [weak self, weak owned] in
                        guard let self, let owned, self.acceptsEvents(owned) else { return }
                        self.onEvent(.live(owned.request.id, event))
                    }
                }
            }
        }
        onEvent(.liveBegan(owned.request.id))
    }

    /// Installed synchronously before any await. All callers await this same task;
    /// startup never awaits it, so stop-during-start cannot form an await cycle.
    private func terminalTask(_ owned: Attempt) -> Task<Void, Never> {
        if let terminal = owned.terminal { return terminal }
        guard attempt === owned else { return Task {} }
        owned.wantsStop = true
        isStopping = true
        hardware.bindEvents(nil)
        owned.statusClear?.cancel()
        owned.statusClear = nil
        owned.previewStart?.cancel()
        if let preview = owned.preview {
            // Latch the service stopped promptly, even if receipt preparation is
            // cancellation-ignoring. Join both below before releasing admission.
            owned.previewStop = Task { await preview.stop() }
            onEvent(.liveEnded(owned.request.id))
        }
        onEvent(.status(owned.request.id, nil))
        let terminal = Task { @MainActor in
            _ = await owned.startup?.result
            if owned.hardwareDispatched { await self.hardware.stop() }
            let state = owned.hardwareDispatched ? self.hardware.snapshot() : .init()
            await owned.previewStart?.value
            await owned.previewStop?.value
            owned.previewStart = nil
            owned.previewStop = nil
            owned.preview = nil
            // Close hardware promptly, freeze its final facts, then let all
            // earlier control writes settle before the finalizing manifest.
            await owned.checkpoints?.value
            owned.checkpoints = nil
            if let failure = owned.failure {
                if let session = owned.session {
                    await self.persistence.failedStart(session, state, .init(error: failure))
                }
                self.onEvent(.failed(owned.request.id))
            } else if let session = owned.session {
                let terminating = self.isTerminating
                let stopped = await self.persistence.stopped(session, state, terminating)
                if !terminating, self.isTerminating { await self.persistence.termination(stopped) }
                self.onEvent(.stopped(stopped, terminating: self.isTerminating))
            }
            if self.attempt === owned {
                self.attempt = nil
                self.recordingID = nil
                self.isStopping = false
            }
        }
        owned.terminal = terminal
        return terminal
    }
}
