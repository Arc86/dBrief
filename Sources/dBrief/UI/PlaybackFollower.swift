import SwiftUI

/// Playback decisions for the transcript, kept pure so they are testable.
enum PlaybackFocus {
    /// The turn to light up. Only while this recording's audio is loaded and has
    /// actually started: a fresh or finished player sits at 0 and must not light
    /// the first turn. Overlapping turns resolve to the first match.
    static func activeTurnID(time: TimeInterval, turns: [SpeakerTurn],
                             isThisFile: Bool, isPlaying: Bool) -> UUID? {
        guard isThisFile, time.isFinite, isPlaying || time > 0 else { return nil }
        return turns.first { time >= $0.startTime && time < $0.endTime }?.id
    }

    /// Animate follow-scrolls only for ordinary playback ticks (0.1 s × rate
    /// apart). Any seek or scrub — even a small forward one, or any while paused —
    /// jumps without animation, so overlapping List scroll animations can't stack.
    static func animatesFollowScroll(from old: TimeInterval, to new: TimeInterval,
                                     isPlaying: Bool, rate: Float) -> Bool {
        guard isPlaying else { return false }
        let delta = new - old
        return delta > 0 && delta <= 0.25 * max(Double(rate), 0.5)
    }
}

/// Observes `AudioPlayer` for the transcript list. Reading `currentTime` here —
/// not in `TranscriptDetailView.body` — keeps the 10 Hz ticks from re-running the
/// whole detail view; it writes `activeTurnID` only when the active turn changes.
/// While the transcript tab is mounted but hidden it keeps the lit turn current
/// but never scrolls; it catches up when the tab is shown.
struct PlaybackFollower: ViewModifier {
    let audioURL: URL?
    let turns: [SpeakerTurn]
    let isVisible: Bool
    let proxy: ScrollViewProxy
    let follow: TranscriptScrollFollowController
    @Binding var activeTurnID: UUID?
    @Binding var isPlaying: Bool

    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isThisFile: Bool {
        audioURL != nil && audioPlayer.currentFileURL == audioURL
    }

    func body(content: Content) -> some View {
        content
            .onAppear { revealWhilePlaying(refresh(scroll: false, animated: false)) }
            .onChange(of: isVisible) { _, visible in
                if visible { revealWhilePlaying(activeTurnID) }
            }
            .onChange(of: audioPlayer.currentTime) { old, new in
                refresh(scroll: true, animated: PlaybackFocus.animatesFollowScroll(
                    from: old, to: new, isPlaying: audioPlayer.isPlaying, rate: audioPlayer.playbackRate))
            }
            .onChange(of: audioPlayer.isPlaying) { _, playing in
                let active = refresh(scroll: false, animated: false)
                // Pressing Play after scrolling away jumps back to the active turn.
                // Uses the id just resolved, not the binding read back.
                if playing, isVisible {
                    follow.resumeFollowing()
                    if let active, follow.shouldFollow { proxy.scrollTo(active, anchor: .center) }
                }
            }
            .onChange(of: audioPlayer.currentFileURL) { _, _ in refresh(scroll: false, animated: false) }
            .onChange(of: turns) { _, _ in refresh(scroll: false, animated: false) }
    }

    /// Updates the bindings and returns the resolved active turn.
    @discardableResult
    private func refresh(scroll: Bool, animated: Bool) -> UUID? {
        let playing = isThisFile && audioPlayer.isPlaying
        if isPlaying != playing { isPlaying = playing }
        let id = PlaybackFocus.activeTurnID(time: audioPlayer.currentTime, turns: turns,
                                            isThisFile: isThisFile, isPlaying: audioPlayer.isPlaying)
        guard id != activeTurnID else { return id }
        activeTurnID = id
        guard scroll, isVisible, let id, follow.shouldFollow else { return id }
        if animated && !reduceMotion {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
        return id
    }

    /// Opening the transcript (or switching to its tab) mid-playback jumps to the
    /// playing turn. Deferred to the next main-queue pass so the list has laid
    /// out and the tab switch has resumed following. Paused, the reader's scroll
    /// position stays.
    private func revealWhilePlaying(_ id: UUID?) {
        guard let id, isVisible, isThisFile, audioPlayer.isPlaying else { return }
        let proxy = proxy, follow = follow
        DispatchQueue.main.async {
            guard follow.shouldFollow else { return }
            proxy.scrollTo(id, anchor: .center)
        }
    }
}
