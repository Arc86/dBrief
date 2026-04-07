import SwiftUI

struct TranscriptPlayerBar: View {
    @Environment(AudioPlayer.self) private var audioPlayer

    let audioURL: URL
    @Binding var currentTime: TimeInterval

    var body: some View {
        HStack(spacing: 8) {
            Button {
                audioPlayer.togglePlayPause(url: audioURL)
            } label: {
                Image(systemName: audioPlayer.currentFileURL == audioURL && audioPlayer.isPlaying
                    ? "pause.fill"
                    : "play.fill")
            }
            .buttonStyle(.borderless)

            Text(audioPlayer.currentFileURL == audioURL
                ? audioPlayer.formattedCurrentTime
                : formatTime(currentTime))
                .font(.caption.monospacedDigit())

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(.quaternary)
                    Rectangle()
                        .fill(.blue)
                        .frame(width: audioPlayer.currentFileURL == audioURL && audioPlayer.duration > 0
                            ? geo.size.width * (audioPlayer.currentTime / audioPlayer.duration)
                            : audioPlayer.duration > 0
                                ? geo.size.width * (currentTime / audioPlayer.duration)
                                : 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = max(0, min(1, value.location.x / geo.size.width))
                            let seekTime = audioPlayer.duration * fraction
                            if audioPlayer.currentFileURL == audioURL {
                                audioPlayer.seek(to: seekTime)
                            }
                            currentTime = seekTime
                        }
                )
            }
            .frame(height: 6)

            Text(audioPlayer.duration > 0 ? audioPlayer.formattedDuration : formatTime(audioPlayer.duration))
                .font(.caption.monospacedDigit())
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let total = Int(time)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
