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
            log.info("Audio playback started")
        } catch {
            log.error("Playback failed for the selected recording")
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
        // One timer at a time, even if resume() is called twice.
        stopTimer()
        timer = Self.scheduleTickTimer { [weak self] in
            // A player released while playing stops its timer instead of leaking it.
            guard let self else { return false }
            self.currentTime = self.player?.currentTime ?? 0
            if let limit = self.endLimit, self.currentTime >= limit {
                self.endLimit = nil
                self.playingTag = nil
                self.pause()
            }
            return true
        }
    }

    /// Schedules the 10 Hz playback tick on the main run loop in `.common` modes, so
    /// it keeps firing while menus track, scrollers drag and windows resize (a plain
    /// `scheduledTimer` only fires in `.default`). Main run-loop timers fire on the
    /// main thread, so no `Task` hop is needed per tick.
    /// `tick` returns false to stop the timer.
    static func scheduleTickTimer(interval: TimeInterval = 0.1,
                                  _ tick: @escaping @MainActor () -> Bool) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { timer in
            MainActor.assumeIsolated {
                if !tick() { timer.invalidate() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    var formattedCurrentTime: String { currentTime.formattedDuration }

    var formattedDuration: String { duration.formattedDuration }
}
