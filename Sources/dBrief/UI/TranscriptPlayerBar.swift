import SwiftUI

struct TranscriptPlayerBar: View {
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(\.viewerPalette) private var palette
    @Environment(\.viewerMode) private var mode

    let audioURL: URL
    @Binding var currentTime: TimeInterval
    var recordingDuration: TimeInterval = 0
    var segments: [RichSegment] = []
    var speakerLabels: [SpeakerLabel] = []

    @State private var audioFileExists = false
    @State private var waveformSamples: [Float] = []
    @State private var normalizedSpeakerRanges: [SpeakerTimeRange] = []
    @State private var sampledSpeakerIDs: [String?] = []
    @State private var speakerLegend: [SpeakerLegendEntry] = []
    @State private var waveformRequestID: UUID?
    @State private var loadedWaveformURL: URL?

    init(
        audioURL: URL,
        currentTime: Binding<TimeInterval>,
        recordingDuration: TimeInterval = 0,
        segments: [RichSegment] = [],
        speakerLabels: [SpeakerLabel] = []
    ) {
        self.audioURL = audioURL
        self._currentTime = currentTime
        self.recordingDuration = recordingDuration
        self.segments = segments
        self.speakerLabels = speakerLabels
        // Seed from the cache so a revisit's first frame already shows the waveform.
        // (The stat runs only when an entry exists.)
        let cache = WaveformCache.shared
        _waveformSamples = State(initialValue: cache.peek(audioURL) == nil ? [] :
            cache.seed(for: audioURL, modificationDate: WaveformCache.modificationDate(of: audioURL)) ?? [])
    }

    private var isThisFile: Bool { audioPlayer.currentFileURL == audioURL }

    /// Use the loaded player's duration once it owns this URL; otherwise use
    /// only finite, positive recording metadata.
    private var playbackDuration: TimeInterval {
        if isThisFile {
            return audioPlayer.duration.isFinite && audioPlayer.duration > 0 ? audioPlayer.duration : 0
        }
        return recordingDuration.isFinite && recordingDuration > 0 ? recordingDuration : 0
    }

    private var displayTime: TimeInterval {
        let value = isThisFile ? audioPlayer.currentTime : currentTime
        guard value.isFinite else { return 0 }
        return playbackDuration > 0 ? min(max(0, value), playbackDuration) : max(0, value)
    }

    private var playbackFraction: Double {
        guard playbackDuration.isFinite, playbackDuration > 0 else { return 0 }
        let fraction = displayTime / playbackDuration
        guard fraction.isFinite else { return 0 }
        return min(max(0, fraction), 1)
    }

    private var isSeekEnabled: Bool {
        audioFileExists && playbackDuration.isFinite && playbackDuration > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !speakerLegend.isEmpty {
                TranscriptSpeakerLegend(entries: speakerLegend, palette: palette, mode: mode)
            }

            TranscriptPlayerControls(
                isPlaying: isThisFile && audioPlayer.isPlaying,
                audioFileExists: audioFileExists,
                currentTime: formatTime(displayTime),
                duration: playbackDuration > 0 ? formatTime(playbackDuration) : "—",
                playbackRate: audioPlayer.playbackRate,
                palette: palette,
                onTogglePlayback: { audioPlayer.togglePlayPause(url: audioURL) },
                onSetRate: { audioPlayer.setRate($0) },
                waveform: { waveform }
            )
        }
        .padding(16)
        .modifier(ViewerCard())
        .task(id: audioURL) {
            guard loadedWaveformURL != audioURL else { return }
            let requestID = UUID()
            waveformRequestID = requestID
            let requestedURL = audioURL
            let exists = FileManager.default.fileExists(atPath: requestedURL.path)
            let modified = exists ? WaveformCache.modificationDate(of: requestedURL) : nil
            audioFileExists = exists

            if exists, let cached = WaveformCache.shared.samples(for: requestedURL, modificationDate: modified) {
                if waveformSamples != cached { waveformSamples = cached }
                loadedWaveformURL = requestedURL
                rebuildSpeakerTimelineCache()
                return
            }

            loadedWaveformURL = nil
            waveformSamples = []
            normalizedSpeakerRanges = []
            sampledSpeakerIDs = []
            rebuildSpeakerTimelineCache()
            guard exists else {
                loadedWaveformURL = requestedURL
                return
            }

            let samples = await WaveformGenerator.generate(from: requestedURL)
            guard !Task.isCancelled, waveformRequestID == requestID else { return }
            WaveformCache.shared.store(samples, for: requestedURL, modificationDate: modified)
            waveformSamples = samples
            loadedWaveformURL = requestedURL
            rebuildSpeakerTimelineCache()
        }
        .onAppear {
            rebuildSpeakerLegend()
            rebuildSpeakerTimelineCache()
        }
        .onChange(of: segments) { _, _ in
            rebuildSpeakerLegend()
            rebuildSpeakerTimelineCache()
        }
        .onChange(of: speakerLabels) { _, _ in rebuildSpeakerLegend() }
        .onChange(of: playbackDuration) { _, _ in rebuildSpeakerTimelineCache() }
        .onChange(of: waveformSamples.count) { _, _ in rebuildSpeakerTimelineCache() }
    }

    private var waveform: some View {
        WaveformView(
            samples: waveformSamples,
            speakerIDs: sampledSpeakerIDs,
            playbackFraction: playbackFraction,
            palette: palette,
            mode: mode,
            isSeekEnabled: isSeekEnabled,
            positionDescription: "\(formatTime(displayTime)) of \(playbackDuration > 0 ? formatTime(playbackDuration) : "unknown duration")",
            onSeek: seek(toFraction:)
        )
        .frame(height: 42)
    }

    private func rebuildSpeakerTimelineCache() {
        guard waveformSamples.count > 0,
              playbackDuration.isFinite,
              playbackDuration > 0 else {
            normalizedSpeakerRanges = []
            sampledSpeakerIDs = []
            return
        }

        let ranges = SpeakerTimeline.normalize(segments, duration: playbackDuration)
        normalizedSpeakerRanges = ranges
        sampledSpeakerIDs = SpeakerTimeline.sampledSpeakerIDs(
            in: ranges,
            duration: playbackDuration,
            count: waveformSamples.count
        )
    }

    private func rebuildSpeakerLegend() {
        var seen = Set<String>()
        let orderedIDs = segments.compactMap(\.speakerId).filter { id in
            !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert(id).inserted
        }
        speakerLegend = orderedIDs.map { id in
            SpeakerLegendEntry(
                speakerID: id,
                name: speakerLabels.first(where: { $0.id == id })?.displayName ?? id
            )
        }
    }

    private func seek(toFraction fraction: Double) {
        guard fraction.isFinite, audioFileExists else { return }
        let clampedFraction = min(max(fraction, 0), 1)

        // Loading through play(url:) preserves AudioPlayer's single-owner and
        // playback-rate behaviour. Seek only after it reports a real duration.
        if audioPlayer.currentFileURL != audioURL {
            audioPlayer.play(url: audioURL)
        }
        guard audioPlayer.currentFileURL == audioURL,
              audioPlayer.duration.isFinite,
              audioPlayer.duration > 0 else { return }

        let actualDuration = audioPlayer.duration
        let target = min(actualDuration, max(0, actualDuration * clampedFraction))
        audioPlayer.seek(to: target)
        currentTime = target
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "—" }
        let total = Int(min(max(0, time), Double(Int.max) / 2))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

private struct SpeakerLegendEntry: Identifiable, Equatable {
    let speakerID: String
    let name: String
    var id: String { speakerID }
}

private struct TranscriptPlayerControls<WaveformContent: View>: View {
    let isPlaying: Bool
    let audioFileExists: Bool
    let currentTime: String
    let duration: String
    let playbackRate: Float
    let palette: ViewerPalette
    let onTogglePlayback: () -> Void
    let onSetRate: (Float) -> Void
    let waveform: () -> WaveformContent

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                playButton
                currentTimeLabel
                waveform()
                    .frame(minWidth: 220, maxWidth: .infinity)
                durationLabel
                speedMenu
            }

            VStack(spacing: 9) {
                HStack(spacing: 12) {
                    playButton
                    currentTimeLabel
                    Spacer(minLength: 6)
                    durationLabel
                    speedMenu
                }
                waveform()
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var playButton: some View {
        Button(action: onTogglePlayback) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(palette.accentText.color)
                .frame(width: 17, height: 17)
                .frame(width: 38, height: 38)
                .background(palette.surface.color, in: Circle())
                .overlay(Circle().strokeBorder(palette.accentText.color.opacity(0.48), lineWidth: 1.2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!audioFileExists)
        .accessibilityLabel(isPlaying ? "Pause recording" : "Play recording")
        .accessibilityHint(audioFileExists ? "Starts or pauses audio playback" : "Audio file is unavailable")
    }

    private var currentTimeLabel: some View {
        Text(currentTime)
            .uiFont(.system(size: 12).monospacedDigit())
            .foregroundStyle(palette.secondary.color)
            .frame(width: 46, alignment: .trailing)
            .accessibilityLabel("Elapsed time \(currentTime)")
    }

    private var durationLabel: some View {
        Text(duration)
            .uiFont(.system(size: 12).monospacedDigit())
            .foregroundStyle(palette.secondary.color)
            .frame(width: 46, alignment: .leading)
            .accessibilityLabel(duration == "—" ? "Duration unavailable" : "Duration \(duration)")
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0] as [Float], id: \.self) { speed in
                Button(speedLabel(speed)) { onSetRate(speed) }
            }
        } label: {
            Text(speedLabel(playbackRate))
                .uiFont(.system(size: 12).monospacedDigit())
                .foregroundStyle(palette.text.color)
                .padding(.horizontal, 9)
                .frame(minHeight: 30)
                .background(palette.surface.color, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(palette.divider.color, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.typographyBorderless)
        .fixedSize()
        .accessibilityLabel("Playback speed")
        .accessibilityValue(speedLabel(playbackRate))
    }

    private func speedLabel(_ speed: Float) -> String {
        speed == 1.0 ? "1×" : String(format: "%g×", speed)
    }
}

private struct TranscriptSpeakerLegend: View {
    let entries: [SpeakerLegendEntry]
    let palette: ViewerPalette
    let mode: ViewerAppearanceMode

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text("Recording")
                    .uiFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.heading.color)

                HStack(spacing: 9) {
                    ForEach(entries) { entry in
                        legendEntry(entry)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            FlowLayout(spacing: 9) {
                ForEach(entries) { entry in
                    legendEntry(entry)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Speakers")
    }

    private func legendEntry(_ entry: SpeakerLegendEntry) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ViewerSpeakerPalette.color(for: entry.speakerID, mode: mode).color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(entry.name)
                .uiFont(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.secondary.color)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}
