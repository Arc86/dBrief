import AppKit
import dBriefWire

/// Opt-in launch/wake prewarm for the local Whisper model (VoiceInk-style),
/// gated by `AppSettings.prewarmWhisperOnLaunch`. Warms the model ~3 s after
/// launch and again on wake (sleep evicts GPU/ANE state, so wake uses
/// `refresh: true` to force a reload). All work is best-effort and no-ops unless
/// the setting is on and the effective transcription engine is local Whisper.
@MainActor
final class WhisperPrewarmCoordinator {
    private let appSettings: AppSettings
    private let plugin: LocalAIPluginService
    private var launchScheduled = false
    nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?

    init(appSettings: AppSettings, plugin: LocalAIPluginService) {
        self.appSettings = appSettings
        self.plugin = plugin
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.delayedPrewarm(refresh: true) }
        }
    }

    /// Call once, after the app is up. Warms the model ~3 s later if enabled.
    func scheduleLaunchPrewarm() {
        guard !launchScheduled else { return }
        launchScheduled = true
        Task { @MainActor [weak self] in await self?.delayedPrewarm(refresh: false) }
    }

    private func delayedPrewarm(refresh: Bool) async {
        try? await Task.sleep(for: .seconds(3))
        guard appSettings.prewarmWhisperOnLaunch,
              appSettings.effectiveTranscriptionEngine == .localWhisper else { return }
        await plugin.prewarmWhisper(config: appSettings.whisperRuntimeConfig, refresh: refresh)
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }
}
