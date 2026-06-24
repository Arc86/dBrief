import SwiftUI

struct WaveformView: View {
    let samples: [Float]
    let playbackFraction: Double
    let onSeek: (Double) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var playedColors: [Color] {
        colorScheme == .dark
            ? [Color(hex: "b85aff"), Color(hex: "54e6ff")]
            : [Color(hex: "8b4dff"), Color(hex: "25abff")]
    }
    private var unplayedColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.16)
    }

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
                        with: .color(unplayedColor),
                        lineWidth: 1
                    )
                    return
                }

                let count = samples.count
                let barWidth = size.width / CGFloat(count)
                let midY = size.height / 2
                let playedX = size.width * CGFloat(max(0, min(1, playbackFraction)))
                let playedShading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: playedColors),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height))

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
                        Path(roundedRect: rect, cornerRadius: 1),
                        with: isPlayed ? playedShading : .color(unplayedColor)
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
                        with: .color(playedColors.last ?? .accentColor),
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
