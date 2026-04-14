import SwiftUI

struct LiveTranscriptView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "waveform")
                    .foregroundStyle(.red)
                Text("Live Transcript")
                    .font(.headline)
                Spacer()
                Text("\(appState.liveTranscriptSegments.count) segments")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            if appState.liveTranscriptSegments.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                    Text("Waiting for transcript segments…")
                        .foregroundStyle(.secondary)
                    Text("Segments appear as WhisperKit processes each audio chunk.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(appState.liveTranscriptSegments) { segment in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(formatTimestamp(segment.start))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 50, alignment: .trailing)

                                    Text(segment.text)
                                        .font(.callout)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .id(segment.id)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .onChange(of: appState.liveTranscriptSegments.count) { _, _ in
                        if let lastId = appState.liveTranscriptSegments.last?.id {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 300)
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
