import SwiftUI

struct TranscriptPlayerBar: View {
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(\.colorScheme) private var colorScheme

    let audioURL: URL
    @Binding var currentTime: TimeInterval
    /// Proportional speaker-coloured timeline shown above the waveform.
    var speakerStrip: [SpeakerStripSegment] = []

    @State private var waveformSamples: [Float] = []

    private var isThisFile: Bool { audioPlayer.currentFileURL == audioURL }
    private var displayTime: TimeInterval { isThisFile ? audioPlayer.currentTime : currentTime }
    private var duration: TimeInterval { isThisFile ? audioPlayer.duration : 0 }
    private var playbackFraction: Double {
        guard duration > 0 else { return 0 }
        return displayTime / duration
    }

    var body: some View {
        VStack(spacing: 9) {
            if !speakerStrip.isEmpty {
                SpeakerActivityStrip(segments: speakerStrip)
                    .frame(height: 5)
            }
            HStack(spacing: 14) {
                Button {
                    audioPlayer.togglePlayPause(url: audioURL)
                } label: {
                    Image(systemName: isThisFile && audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(TranscriptDesignTokens.brandGradient, in: Circle())
                        .shadow(color: Color(hex: "8b4dff").opacity(0.6), radius: 10, x: 0, y: 4)
                }
                .buttonStyle(.plain)

                Text(formatTime(displayTime))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(TranscriptDesignTokens.secondaryText(scheme: colorScheme))
                    .frame(width: 44, alignment: .trailing)

                WaveformView(
                    samples: waveformSamples,
                    playbackFraction: playbackFraction,
                    onSeek: { fraction in
                        let seekTime = (isThisFile ? audioPlayer.duration : 0) * fraction
                        if isThisFile { audioPlayer.seek(to: seekTime) }
                        currentTime = seekTime
                    }
                )
                .frame(height: 30)

                Text(formatTime(isThisFile ? audioPlayer.duration : 0))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(TranscriptDesignTokens.timestampText(scheme: colorScheme))
                    .frame(width: 44, alignment: .leading)

                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0] as [Float], id: \.self) { speed in
                        Button(speedLabel(speed)) { audioPlayer.setRate(speed) }
                    }
                } label: {
                    Text(speedLabel(audioPlayer.playbackRate))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: colorScheme))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(TranscriptDesignTokens.chipFill(scheme: colorScheme))
                                .overlay(RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(TranscriptDesignTokens.chipBorder(scheme: colorScheme), lineWidth: 1))
                        }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
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

/// One run of speaker activity for the audio-bar timeline strip.
struct SpeakerStripSegment: Identifiable {
    let id = UUID()
    let colorKey: String
    let color: Color
    var weight: Double
}

/// A thin proportional timeline of who spoke when, coloured by speaker.
struct SpeakerActivityStrip: View {
    let segments: [SpeakerStripSegment]

    var body: some View {
        GeometryReader { geo in
            let total = max(0.0001, segments.reduce(0) { $0 + $1.weight })
            HStack(spacing: 0) {
                ForEach(segments) { seg in
                    Rectangle()
                        .fill(seg.color.opacity(0.85))
                        .frame(width: geo.size.width * seg.weight / total)
                }
            }
        }
        .clipShape(Capsule())
    }
}
