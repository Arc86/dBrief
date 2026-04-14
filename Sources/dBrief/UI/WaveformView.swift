import SwiftUI

struct WaveformView: View {
    let samples: [Float]
    let playbackFraction: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard !samples.isEmpty else {
                    // Empty state: flat line
                    let midY = size.height / 2
                    context.stroke(
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: midY))
                            path.addLine(to: CGPoint(x: size.width, y: midY))
                        },
                        with: .color(Color.secondary.opacity(0.3)),
                        lineWidth: 1
                    )
                    return
                }

                let count = samples.count
                let barWidth = size.width / CGFloat(count)
                let midY = size.height / 2
                let playedX = size.width * CGFloat(max(0, min(1, playbackFraction)))

                for (i, sample) in samples.enumerated() {
                    let x = CGFloat(i) * barWidth
                    let halfHeight = max(1.5, CGFloat(sample) * midY * 0.92)
                    let rect = CGRect(
                        x: x,
                        y: midY - halfHeight,
                        width: max(1, barWidth - 0.5),
                        height: halfHeight * 2
                    )
                    let isPlayed = x < playedX
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 0.5),
                        with: .color(isPlayed ? Color.accentColor : Color.secondary.opacity(0.35))
                    )
                }

                // Playback indicator
                if playbackFraction > 0 && playbackFraction <= 1 {
                    let lineX = CGFloat(min(playedX, size.width - 1))
                    context.stroke(
                        Path { path in
                            path.move(to: CGPoint(x: lineX, y: 0))
                            path.addLine(to: CGPoint(x: lineX, y: size.height))
                        },
                        with: .color(Color.accentColor.opacity(0.9)),
                        lineWidth: 1.5
                    )
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = max(0, min(1, Double(value.location.x / geo.size.width)))
                        onSeek(fraction)
                    }
            )
        }
    }
}
