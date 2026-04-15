import SwiftUI

struct TranscriptPlayerBar: View {
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(\.colorScheme) private var colorScheme

    let audioURL: URL
    @Binding var currentTime: TimeInterval

    @State private var waveformSamples: [Float] = []

    private var isThisFile: Bool { audioPlayer.currentFileURL == audioURL }
    private var displayTime: TimeInterval { isThisFile ? audioPlayer.currentTime : currentTime }
    private var duration: TimeInterval { isThisFile ? audioPlayer.duration : 0 }
    private var playbackFraction: Double {
        guard duration > 0 else { return 0 }
        return displayTime / duration
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                audioPlayer.togglePlayPause(url: audioURL)
            } label: {
                Image(systemName: isThisFile && audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
            }
            .buttonStyle(.borderless)

            Text(formatTime(displayTime))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(TranscriptDesignTokens.secondaryText(scheme: colorScheme))
                .frame(width: 40, alignment: .trailing)

            WaveformView(
                samples: waveformSamples,
                playbackFraction: playbackFraction,
                onSeek: { fraction in
                    let seekTime = (isThisFile ? audioPlayer.duration : 0) * fraction
                    if isThisFile { audioPlayer.seek(to: seekTime) }
                    currentTime = seekTime
                }
            )
            .frame(height: 36)

            Text(formatTime(isThisFile ? audioPlayer.duration : 0))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(TranscriptDesignTokens.secondaryText(scheme: colorScheme))
                .frame(width: 40, alignment: .leading)

            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0] as [Float], id: \.self) { speed in
                    Button(speedLabel(speed)) { audioPlayer.setRate(speed) }
                }
            } label: {
                Text(speedLabel(audioPlayer.playbackRate))
                    .font(.caption2.monospacedDigit())
                    .frame(width: 30)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            TranscriptDesignTokens.structureFill(scheme: colorScheme)
                .background(.ultraThinMaterial)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TranscriptDesignTokens.structureBorder(scheme: colorScheme))
                .frame(height: 1)
        }
        .task {
            guard waveformSamples.isEmpty else { return }
            waveformSamples = await WaveformGenerator.generate(from: audioURL)
        }
    }

    private func speedLabel(_ speed: Float) -> String {
        speed == 1.0 ? "1×" : String(format: "%g×", speed)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let total = Int(max(0, time))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
