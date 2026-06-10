import SwiftUI

/// Model Performance panel in the transcript viewer. Aggregates every recorded
/// session (across all recordings) by model, filterable by time range, and shows
/// a card per transcription model and per AI-analysis model.
struct ModelPerformanceView: View {
    let store: ModelPerformanceStore

    @Environment(\.colorScheme) private var colorScheme

    @State private var records: [ModelPerformanceRecord] = []
    @State private var loaded = false
    @State private var range: PerformanceRange = .last30Days

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: TranscriptDesignTokens.cardGap)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task {
            records = await store.load()
            loaded = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Model Performance")
                .font(.headline)
            Spacer()
            Picker("", selection: $range) {
                ForEach(PerformanceRange.allCases) { r in
                    Text(r.label).tag(r)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let txStats = transcriptionStats
        let aiStats = aiStats

        if !loaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if txStats.isEmpty && aiStats.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !txStats.isEmpty {
                        section(title: "Transcription Models") {
                            LazyVGrid(columns: columns, spacing: TranscriptDesignTokens.cardGap) {
                                ForEach(txStats) { transcriptionCard($0) }
                            }
                        }
                    }
                    if !aiStats.isEmpty {
                        section(title: "AI Analysis Models") {
                            LazyVGrid(columns: columns, spacing: TranscriptDesignTokens.cardGap) {
                                ForEach(aiStats) { aiCard($0) }
                            }
                        }
                    }
                }
                .padding(TranscriptDesignTokens.scrollPadding)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "speedometer")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(records.isEmpty
                 ? "No performance data yet."
                 : "No sessions in this time range.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Metrics are recorded automatically each time a recording is transcribed or analyzed.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: TranscriptDesignTokens.cardGap) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(TranscriptDesignTokens.sectionLabel(scheme: colorScheme))
            content()
        }
    }

    // MARK: - Cards

    private func transcriptionCard(_ stat: TranscriptionStat) -> some View {
        card {
            VStack(spacing: 6) {
                modelTitle(stat.model, sessions: stat.sessions)

                Text(String(format: "%.1fx", stat.speedup))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(hex: "30d158"))
                Text("End-to-end · faster than real-time")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let inf = stat.inferenceSpeedup {
                    Text(stat.avgOverhead.map {
                        String(format: "%.1fx model · +%@ load/overhead", inf, Self.formatDuration($0))
                    } ?? String(format: "%.1fx model inference", inf))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }

                Divider().padding(.vertical, 2)

                HStack(alignment: .top, spacing: 0) {
                    metric(value: Self.formatDuration(stat.avgAudio),
                           label: "Avg. Audio",
                           color: Color(hex: "0a84ff"))
                    Divider().frame(height: 30)
                    metric(value: Self.formatDuration(stat.avgProcessing),
                           label: "Avg. Processing",
                           color: Color(hex: "30d158"))
                }
            }
        }
    }

    private func aiCard(_ stat: AIStat) -> some View {
        card {
            VStack(spacing: 6) {
                modelTitle(stat.model, sessions: stat.sessions)

                Text(Self.formatDuration(stat.avgTime))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(hex: "5e5ce6"))
                Text("Avg. Analysis Time")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func modelTitle(_ name: String, sessions: Int) -> some View {
        VStack(spacing: 2) {
            Text(name)
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: colorScheme))
            Text("\(sessions) \(sessions == 1 ? "session" : "sessions")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func metric(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(TranscriptDesignTokens.cardFill(scheme: colorScheme))
            .overlay(
                RoundedRectangle(cornerRadius: TranscriptDesignTokens.cardCornerRadius)
                    .stroke(TranscriptDesignTokens.cardBorder(scheme: colorScheme), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: TranscriptDesignTokens.cardCornerRadius))
    }

    // MARK: - Aggregation

    private var filtered: [ModelPerformanceRecord] {
        guard let cutoff = range.cutoff else { return records }
        return records.filter { $0.date >= cutoff }
    }

    private var transcriptionStats: [TranscriptionStat] {
        TranscriptionStat.aggregate(filtered)
    }

    private var aiStats: [AIStat] {
        let grouped = Dictionary(grouping: filtered.filter { $0.hasAI }) {
            $0.aiModel ?? "Unknown"
        }
        return grouped.map { model, recs -> AIStat in
            let times = recs.compactMap { $0.aiTime }
            let avg = times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count)
            return AIStat(model: model, sessions: recs.count, avgTime: avg)
        }
        .sorted { $0.sessions > $1.sessions }
    }

    // MARK: - Formatting

    /// "31s", "3.10s", or "2:29 mins" depending on magnitude.
    static func formatDuration(_ s: TimeInterval) -> String {
        if s >= 60 {
            let m = Int(s) / 60
            let sec = Int(s.rounded()) % 60
            return String(format: "%d:%02d mins", m, sec)
        } else if s >= 10 {
            return String(format: "%.0fs", s)
        } else {
            return String(format: "%.2fs", s)
        }
    }
}

// MARK: - Aggregated stat types

struct TranscriptionStat: Identifiable {
    let model: String
    let sessions: Int
    let avgAudio: TimeInterval
    let avgProcessing: TimeInterval
    /// Average end-to-end realtime ratio (audio / total transcription step time).
    let speedup: Double
    /// Average pure-inference realtime ratio, or nil when no record reported it.
    let inferenceSpeedup: Double?
    /// Average (transcriptionTime − inferenceTime) over records with both, or nil.
    let avgOverhead: TimeInterval?
    var id: String { model }

    /// Pure aggregation over already-filtered records, grouped by model.
    static func aggregate(_ records: [ModelPerformanceRecord]) -> [TranscriptionStat] {
        let grouped = Dictionary(grouping: records.filter { $0.hasTranscription }) {
            $0.transcriptionModel ?? "Unknown"
        }
        return grouped.map { model, recs -> TranscriptionStat in
            let audios = recs.compactMap { $0.audioDuration }
            let procs = recs.compactMap { $0.transcriptionTime }
            let avgAudio = audios.isEmpty ? 0 : audios.reduce(0, +) / Double(audios.count)
            let avgProc = procs.isEmpty ? 0 : procs.reduce(0, +) / Double(procs.count)

            let e2eRatios = recs.compactMap { r -> Double? in
                guard let a = r.audioDuration, let p = r.transcriptionTime, p > 0 else { return nil }
                return a / p
            }
            let speed = e2eRatios.isEmpty ? 0 : e2eRatios.reduce(0, +) / Double(e2eRatios.count)

            let infRatios = recs.compactMap { r -> Double? in
                guard let a = r.audioDuration, let i = r.inferenceTime, i > 0 else { return nil }
                return a / i
            }
            let infSpeed = infRatios.isEmpty ? nil : infRatios.reduce(0, +) / Double(infRatios.count)

            let overheads = recs.compactMap { r -> TimeInterval? in
                guard let p = r.transcriptionTime, let i = r.inferenceTime else { return nil }
                return p - i
            }
            let avgOverhead = overheads.isEmpty ? nil : overheads.reduce(0, +) / Double(overheads.count)

            return TranscriptionStat(
                model: model, sessions: recs.count,
                avgAudio: avgAudio, avgProcessing: avgProc,
                speedup: speed, inferenceSpeedup: infSpeed, avgOverhead: avgOverhead
            )
        }
        .sorted { $0.sessions > $1.sessions }
    }
}

private struct AIStat: Identifiable {
    let model: String
    let sessions: Int
    let avgTime: TimeInterval
    var id: String { model }
}

// MARK: - Time range

enum PerformanceRange: String, CaseIterable, Identifiable {
    case last7Days
    case last30Days
    case lastYear
    case allTime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .last7Days: "Last 7 Days"
        case .last30Days: "Last 30 Days"
        case .lastYear: "Last Year"
        case .allTime: "All Time"
        }
    }

    /// Earliest date included, or nil for all time.
    var cutoff: Date? {
        let calendar = Calendar.current
        let now = Date()
        switch self {
        case .last7Days: return calendar.date(byAdding: .day, value: -7, to: now)
        case .last30Days: return calendar.date(byAdding: .day, value: -30, to: now)
        case .lastYear: return calendar.date(byAdding: .year, value: -1, to: now)
        case .allTime: return nil
        }
    }
}
