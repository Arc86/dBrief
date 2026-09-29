import SwiftUI

/// A waveform whose bar identity is sampled from transcript time ranges before
/// it reaches Canvas. Playback only changes bar opacity and the separate playhead.
struct WaveformView: View {
    let samples: [Float]
    let speakerIDs: [String?]
    let playbackFraction: Double
    let palette: ViewerPalette
    let mode: ViewerAppearanceMode
    let isSeekEnabled: Bool
    var positionDescription: String? = nil
    let onSeek: (Double) -> Void

    @FocusState private var hasKeyboardFocus: Bool

    private var clampedPlaybackFraction: Double {
        guard playbackFraction.isFinite else { return 0 }
        return min(max(playbackFraction, 0), 1)
    }

    private var neutralColor: Color {
        ViewerSpeakerPalette.color(for: nil, mode: mode).color
    }

    private var spokenPosition: String {
        positionDescription ?? "\(Int(clampedPlaybackFraction * 100)) percent"
    }

    var body: some View {
        // Resolve colors while SwiftUI evaluates the view, rather than mutating
        // State from onAppear. Canvas may be measured/recreated by ViewThatFits
        // before its selected child appears, which could otherwise leave its
        // captured color cache empty even after the timeline IDs arrive.
        let barColors = speakerIDs.map { speakerID in
            ViewerSpeakerPalette.color(for: speakerID, mode: mode).color
        }

        return GeometryReader { geometry in
            Canvas { context, size in
                guard size.width.isFinite, size.width > 0,
                      size.height.isFinite, size.height > 0 else { return }

                let midY = size.height / 2
                guard !samples.isEmpty else {
                    let baseline = Path { path in
                        path.move(to: CGPoint(x: 0, y: midY))
                        path.addLine(to: CGPoint(x: size.width, y: midY))
                    }
                    context.stroke(baseline, with: .color(neutralColor.opacity(0.38)), lineWidth: 1)
                    drawPlayhead(in: &context, size: size)
                    return
                }

                let count = samples.count
                let barWidth = size.width / CGFloat(count)
                for index in samples.indices {
                    let x = CGFloat(index) * barWidth
                    let sample = samples[index]
                    let amplitude = sample.isFinite ? min(max(sample, 0), 1) : 0
                    let halfHeight = max(1.5, CGFloat(amplitude) * midY * 0.92)
                    let rect = CGRect(
                        x: x,
                        y: midY - halfHeight,
                        width: max(1, barWidth - 0.5),
                        height: halfHeight * 2
                    )
                    let centerFraction = (Double(index) + 0.5) / Double(count)
                    let isPlayed = centerFraction <= clampedPlaybackFraction
                    let hasSpeaker = speakerIDs.indices.contains(index) && speakerIDs[index] != nil
                    let color = barColors.indices.contains(index) ? barColors[index] : neutralColor
                    let opacity = hasSpeaker
                        ? (isPlayed ? 0.94 : 0.48)
                        : (isPlayed ? 0.70 : 0.34)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: min(1.5, rect.width / 2)),
                        with: .color(color.opacity(opacity))
                    )
                }

                drawPlayhead(in: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isSeekEnabled,
                              geometry.size.width.isFinite,
                              geometry.size.width > 0,
                              value.location.x.isFinite else { return }
                        let fraction = Double(value.location.x / geometry.size.width)
                        onSeek(min(max(fraction, 0), 1))
                    }
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(hasKeyboardFocus ? palette.accentText.color : .clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Recording waveform")
        .accessibilityValue(isSeekEnabled ? spokenPosition : "Seeking unavailable")
        .accessibilityHint(isSeekEnabled ? "Use left and right arrow keys to seek." : "Audio position cannot be changed.")
        .accessibilityAdjustableAction { direction in
            guard isSeekEnabled else { return }
            switch direction {
            case .increment: seekByFraction(0.01)
            case .decrement: seekByFraction(-0.01)
            @unknown default: break
            }
        }
        .focusable(isSeekEnabled)
        .focused($hasKeyboardFocus)
        .onKeyPress(.leftArrow) { handleKeyboardSeek(-0.01) }
        .onKeyPress(.rightArrow) { handleKeyboardSeek(0.01) }
    }

    private func drawPlayhead(in context: inout GraphicsContext, size: CGSize) {
        guard isSeekEnabled, size.width > 1 else { return }
        let x = min(max(0, size.width - 1), size.width * CGFloat(clampedPlaybackFraction))
        let line = Path { path in
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(line, with: .color(palette.accentText.color), lineWidth: 1.5)
    }

    private func seekByFraction(_ delta: Double) {
        guard isSeekEnabled else { return }
        let next = min(max(clampedPlaybackFraction + delta, 0), 1)
        guard next != clampedPlaybackFraction else { return }
        onSeek(next)
    }

    private func handleKeyboardSeek(_ delta: Double) -> KeyPress.Result {
        guard isSeekEnabled else { return .ignored }
        seekByFraction(delta)
        return .handled
    }
}
