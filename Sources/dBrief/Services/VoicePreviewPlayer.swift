import Foundation
import dBriefWire

/// Auditions a TTS voice from Settings: synthesizes a short, language-appropriate
/// sample with the chosen voice/language/model/style via the TTS helper, then
/// plays the WAV directly (no transcode — preview audio is throwaway). Uses a
/// private `AudioPlayer` so it never commandeers the app's shared playback.
@MainActor
@Observable
final class VoicePreviewPlayer {
    enum State: Equatable {
        case idle
        case preparingVoice(progress: Double?)
        case synthesizing
        case playing
        case failed(message: String)
    }

    private(set) var state: State = .idle

    private let player = AudioPlayer()
    private var task: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var tempURL: URL?

    /// True while preparing/synthesizing/playing — drives the button's busy UI.
    var isBusy: Bool {
        switch state {
        case .idle, .failed: false
        default: true
        }
    }

    var isPlaying: Bool { state == .playing }

    /// Synthesize the sample for `language` with the given voice settings and play
    /// it. Calling again (or `stop()`) cancels any in-flight work first.
    func preview(
        voice: TTSVoice,
        language: TTSLanguage,
        model: TTSModelSize,
        instruction: String,
        plugin: LocalAIPluginService?
    ) {
        stop()
        guard let plugin else {
            state = .failed(message: "Local AI plugin not available.")
            return
        }
        let text = language.sampleText
        observeModelState(plugin: plugin)
        state = .preparingVoice(progress: nil)
        task = Task { [weak self] in
            guard let self else { return }
            let outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("dbrief-voicepreview-\(UUID().uuidString).wav")
            self.tempURL = outURL
            do {
                self.state = .synthesizing
                _ = try await plugin.synthesizeSpeech(
                    text: text,
                    outputPath: outURL.path,
                    voice: voice.rawValue,
                    language: language.rawValue,
                    instruction: instruction,
                    model: model.rawValue
                )
                try Task.checkCancellation()
                self.stopObservingModelState()
                self.player.play(url: outURL)
                self.state = .playing
                self.watchForPlaybackEnd()
            } catch is CancellationError {
                self.discardTemp()
            } catch {
                self.stopObservingModelState()
                self.discardTemp()
                self.state = .failed(message: error.localizedDescription)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        finishTask?.cancel()
        finishTask = nil
        stopObservingModelState()
        player.stop()
        discardTemp()
        state = .idle
    }

    // MARK: - Private

    /// Poll the private player so we drop back to `.idle` when the sample ends
    /// (AudioPlayer has no completion callback; `isPlaying` flips on finish).
    private func watchForPlaybackEnd() {
        finishTask = Task { [weak self] in
            while let self, self.player.isPlaying {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.discardTemp()
            if case .playing = self.state { self.state = .idle }
        }
    }

    private func observeModelState(plugin: LocalAIPluginService) {
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            for await event in plugin.stateStream {
                guard let self else { return }
                if case let .downloading(progress, _) = event {
                    self.state = .preparingVoice(progress: progress)
                }
            }
        }
    }

    private func stopObservingModelState() {
        stateTask?.cancel()
        stateTask = nil
    }

    private func discardTemp() {
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        tempURL = nil
    }
}
