import Foundation

/// Pure decision: should confirm-first pause the pipeline for this recording?
/// Holds only when the mode is `.confirmFirst` AND there is something to resolve
/// — at least two diarized speakers, or a non-empty voice library to match against.
/// Solo memos with no library skip the hold.
enum SpeakerReviewGate {
    static func shouldHold(mode: AppSettings.SpeakerIdMode, speakerCount: Int, libraryCount: Int) -> Bool {
        mode == .confirmFirst && (speakerCount >= 2 || libraryCount > 0)
    }
}
