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

    /// Animate follow-scrolls only for ordinary forward playback (ticks are
    /// 0.1 s apart). A seek or scrub jumps without animation, so overlapping
    /// List scroll animations can't stack and bounce.
    static func animatesFollowScroll(from old: TimeInterval, to new: TimeInterval) -> Bool {
        let delta = new - old
        return delta > 0 && delta < 0.5
    }
}

/// Observes `AudioPlayer` for the transcript list. Reading `currentTime` here —
/// not in `TranscriptDetailView.body` — keeps the 10 Hz ticks from re-running the
/// whole detail view; it writes `activeTurnID` only when the active turn changes.
struct PlaybackFollower: ViewModifier {
    let audioURL: URL?
    let turns: [SpeakerTurn]
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
            .onAppear { refresh(scroll: false, animated: false) }
            .onChange(of: audioPlayer.currentTime) { old, new in
                refresh(scroll: true, animated: PlaybackFocus.animatesFollowScroll(from: old, to: new))
            }
            .onChange(of: audioPlayer.isPlaying) { _, playing in
                refresh(scroll: false, animated: false)
                // Pressing Play after scrolling away jumps back to the active turn.
                if playing {
                    follow.resumeFollowing()
                    if let activeTurnID, follow.shouldFollow { proxy.scrollTo(activeTurnID, anchor: .center) }
                }
            }
            .onChange(of: audioPlayer.currentFileURL) { _, _ in refresh(scroll: false, animated: false) }
            .onChange(of: turns) { _, _ in refresh(scroll: false, animated: false) }
    }

    private func refresh(scroll: Bool, animated: Bool) {
        let playing = isThisFile && audioPlayer.isPlaying
        if isPlaying != playing { isPlaying = playing }
        let id = PlaybackFocus.activeTurnID(time: audioPlayer.currentTime, turns: turns,
                                            isThisFile: isThisFile, isPlaying: audioPlayer.isPlaying)
        guard id != activeTurnID else { return }
        activeTurnID = id
        guard scroll, let id, follow.shouldFollow else { return }
        if animated && !reduceMotion {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}
