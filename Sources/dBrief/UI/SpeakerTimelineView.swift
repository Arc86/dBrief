// Sources/dBrief/UI/SpeakerTimelineView.swift
import SwiftUI
import dBriefWire

/// Horizontal speaker timeline strip. Draws each transcript segment as a
/// coloured block proportional to audio duration; clicking or dragging seeks.
struct SpeakerTimelineView: View {
    let segments: [RichSegment]
    let duration: TimeInterval
    let currentTime: TimeInterval
    var onSeek: (TimeInterval) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                segmentCanvas(size: geo.size)
                playhead(width: geo.size.width)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = max(0, min(1, value.location.x / geo.size.width))
                        onSeek(fraction * duration)
                    }
            )
        }
        .frame(height: 18)
        .background(
            colorScheme == .dark
                ? Color.white.opacity(0.06)
                : Color.black.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 3)
        )
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func segmentCanvas(size: CGSize) -> some View {
        Canvas { context, _ in
            guard duration > 0 else { return }
            for segment in segments {
                guard segment.end > segment.start else { continue }
                let x = CGFloat(segment.start / duration) * size.width
                let w = max(1.5, CGFloat((segment.end - segment.start) / duration) * size.width)
                let color = TranscriptDesignTokens.speakerColor(for: segment.speakerId)
                context.fill(
                    Path(CGRect(x: x, y: 2, width: w, height: size.height - 4)),
                    with: .color(color.opacity(0.75))
                )
            }
        }
    }

    @ViewBuilder
    private func playhead(width: CGFloat) -> some View {
        if duration > 0 {
            let x = CGFloat(currentTime / duration) * width
            RoundedRectangle(cornerRadius: 1)
                .fill(colorScheme == .dark ? Color.white.opacity(0.9) : Color.black.opacity(0.75))
                .frame(width: 2, height: 14)
                .offset(x: x - 1)
                .shadow(color: .black.opacity(0.3), radius: 2)
                .animation(.linear(duration: 0.1), value: currentTime)
        }
    }
}
