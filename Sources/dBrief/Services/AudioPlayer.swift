@preconcurrency import AVFoundation
import os

private let log = Logger.player

@MainActor
@Observable
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var currentFileURL: URL?
    private var timer: Timer?
    /// When set, playback auto-pauses once `currentTime` reaches it (snippet preview).
    private var endLimit: TimeInterval?
    /// Identifies the snippet currently playing (e.g. a speaker id), so a caller with
    /// several previews of the same file can tell which one is active. Cleared when
    /// playback stops or reaches the snippet end.
    private(set) var playingTag: String?

    private(set) var playbackRate: Float = 1.0

    func play(url: URL) {
        stop()

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.enableRate = true
            player?.rate = playbackRate
            player?.prepareToPlay()
            duration = player?.duration ?? 0
            currentFileURL = url
            player?.play()
            isPlaying = true
            startTimer()
            log.info("Playing \(url.lastPathComponent, privacy: .public)")
        } catch {
            log.error("Playback failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Plays `url` from `from`, automatically pausing at `to`. Used by the speaker
    /// review window to preview a single speaker's representative turn. `tag`
    /// identifies which preview is active (see `playingTag`). Starting a new range
    /// stops any current playback, so only one preview ever plays at a time.
    func playRange(url: URL, from: TimeInterval, to: TimeInterval, tag: String? = nil) {
        play(url: url)        // stop()s any current playback (clears playingTag)
        seek(to: from)
        endLimit = to
        playingTag = tag
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        player?.rate = rate
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func resume() {
        player?.play()
        isPlaying = true
        startTimer()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        currentFileURL = nil
        endLimit = nil
        playingTag = nil
        stopTimer()
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }

    func togglePlayPause(url: URL) {
        if currentFileURL == url && isPlaying {
            pause()
        } else if currentFileURL == url {
            resume()
        } else {
            play(url: url)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = 0
            self.endLimit = nil
            self.playingTag = nil
            self.stopTimer()
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = self.player?.currentTime ?? 0
                if let limit = self.endLimit, self.currentTime >= limit {
                    self.endLimit = nil
                    self.playingTag = nil
                    self.pause()
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    var formattedCurrentTime: String {
        formatTime(currentTime)
    }

    var formattedDuration: String {
        formatTime(duration)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let total = Int(time)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
