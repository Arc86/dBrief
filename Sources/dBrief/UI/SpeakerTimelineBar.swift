import SwiftUI

/// A stretch of the recording with one speaker (or neutral: silence, overlap,
/// unknown), as fractions of the recording's length.
struct SpeakerTimelineRun: Equatable {
    let start: Double
    let end: Double
    let speakerID: String?
}

enum SpeakerTimelineBarLayout {
    /// Samples across the bar; ~1.5 px per sample on the widest player.
    static let resolution = 600

    /// Merges consecutive equal samples into runs covering 0...1 without gaps.
    static func runs(sampledIDs: [String?]) -> [SpeakerTimelineRun] {
        guard !sampledIDs.isEmpty else { return [] }
        let count = Double(sampledIDs.count)
        var runs: [SpeakerTimelineRun] = []
        var runStart = 0
        for index in 1...sampledIDs.count {
            if index == sampledIDs.count || sampledIDs[index] != sampledIDs[runStart] {
                runs.append(SpeakerTimelineRun(
                    start: Double(runStart) / count,
                    end: index == sampledIDs.count ? 1 : Double(index) / count,
                    speakerID: sampledIDs[runStart]))
                runStart = index
            }
        }
        return runs
    }
}

/// The coloured bar, drawn once per timeline. It has no playback input, so
/// playback ticks never redraw it; the played part is a clipped copy.
struct SpeakerTimelineStrip: View, Equatable {
    let runs: [SpeakerTimelineRun]
    let colors: [String: Color]
    let neutral: Color
    let played: Bool

    var body: some View {
        Canvas { context, size in
            guard size.width.isFinite, size.width > 0 else { return }
            for run in runs {
                let rect = CGRect(x: size.width * run.start, y: 0,
                                  width: max(0.5, size.width * (run.end - run.start)), height: size.height)
                let color = run.speakerID.flatMap { colors[$0] } ?? neutral
                let opacity = run.speakerID == nil ? (played ? 0.70 : 0.34) : (played ? 0.94 : 0.48)
                context.fill(Path(rect), with: .color(color.opacity(opacity)))
            }
        }
    }
}

/// Who spoke when, as a slim coloured bar with a playhead. No audio decoding;
/// only the clip width and playhead move.
struct SpeakerTimelineBar: View {
    let runs: [SpeakerTimelineRun]
    let colors: [String: Color]
    let playbackFraction: Double
    let palette: ViewerPalette
    let mode: ViewerAppearanceMode
    let isSeekEnabled: Bool
    var positionDescription: String? = nil
    let onSeek: (Double) -> Void

    @FocusState private var hasKeyboardFocus: Bool

    private var fraction: Double {
        guard playbackFraction.isFinite else { return 0 }
        return min(max(playbackFraction, 0), 1)
    }

    private var neutral: Color { ViewerSpeakerPalette.color(for: nil, mode: mode).color }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                bar
                    .frame(height: 12)
                    .frame(maxHeight: .infinity)
                if isSeekEnabled {
                    Rectangle()
                        .fill(palette.accentText.color)
                        .frame(width: 1.5)
                        .offset(x: min(max(0, geometry.size.width - 1.5), geometry.size.width * fraction))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isSeekEnabled, geometry.size.width.isFinite, geometry.size.width > 0,
                              value.location.x.isFinite else { return }
                        onSeek(min(max(Double(value.location.x / geometry.size.width), 0), 1))
                    }
            )
            // The window is movable by its background; dragging here must seek, not move it.
            .preventsWindowDrag()
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(hasKeyboardFocus ? palette.accentText.color : .clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Speaker timeline")
        .accessibilityValue(isSeekEnabled ? (positionDescription ?? "\(Int(fraction * 100)) percent") : "Seeking unavailable")
        .accessibilityHint(isSeekEnabled ? "Use left and right arrow keys to seek." : "Audio position cannot be changed.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: seekBy(0.01)
            case .decrement: seekBy(-0.01)
            @unknown default: break
            }
        }
        .focusable(isSeekEnabled)
        .focused($hasKeyboardFocus)
        .onKeyPress(.leftArrow) { seekBy(-0.01) ? .handled : .ignored }
        .onKeyPress(.rightArrow) { seekBy(0.01) ? .handled : .ignored }
    }

    @ViewBuilder
    private var bar: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        if runs.isEmpty {
            shape.fill(neutral.opacity(0.34))
        } else {
            ZStack(alignment: .leading) {
                SpeakerTimelineStrip(runs: runs, colors: colors, neutral: neutral, played: false).equatable()
                SpeakerTimelineStrip(runs: runs, colors: colors, neutral: neutral, played: true).equatable()
                    .mask(alignment: .leading) {
                        GeometryReader { g in Rectangle().frame(width: g.size.width * fraction) }
                    }
            }
            .clipShape(shape)
        }
    }

    @discardableResult
    private func seekBy(_ delta: Double) -> Bool {
        guard isSeekEnabled else { return false }
        let next = min(max(fraction + delta, 0), 1)
        if next != fraction { onSeek(next) }
        return true
    }
}
