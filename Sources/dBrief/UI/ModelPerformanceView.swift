import SwiftUI

/// Benchmark panel (Power User Mode → Settings → Benchmark). Aggregates every
/// recorded session by model and time range, then highlights the fastest
/// transcription model in a hero block and ranks all models in a leaderboard
/// with relative-speed bars. AI-analysis models get a small comparison group.
struct ModelPerformanceView: View {
    let store: ModelPerformanceStore

    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppSettings.self) private var appSettings

    @State private var records: [ModelPerformanceRecord] = []
    @State private var loaded = false
    @State private var range: PerformanceRange = .last30Days
    @State private var showClearConfirm = false

    @State private var txSort = [KeyPathComparator(\TranscriptionStat.headlineSpeed, order: .reverse)]
    @State private var aiSort = [KeyPathComparator(\AIStat.avgTime, order: .forward)]

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
        .confirmationDialog("Clear benchmark stats?",
                            isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear Stats", role: .destructive) {
                Task {
                    await store.clear()
                    records = []
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes all per-model benchmark history. The total minutes transcribed is kept.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Model Performance")
                    .font(.headline)
                Text("\(Self.formatTotalDuration(appSettings.lifetimeTranscribedSeconds)) transcribed by dBrief")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $range) {
                ForEach(PerformanceRange.allCases) { r in
                    Text(r.label).tag(r)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .help("Clear benchmark stats")
            .disabled(records.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let txStats = sortedTxStats
        let aiStats = sortedAIStats

        if !loaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if txStats.isEmpty && aiStats.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let fastest = txStats.max(by: { $0.headlineSpeed < $1.headlineSpeed }) {
                        heroCard(fastest)
                    }
                    if !txStats.isEmpty {
                        transcriptionLeaderboard(txStats)
                    }
                    if !aiStats.isEmpty {
                        aiComparison(aiStats)
                    }
                    let rows = recentRows
                    if !rows.isEmpty {
                        recentTranscriptions(rows)
                    }
                }
                .padding(TranscriptDesignTokens.scrollPadding)
            }
        }
    }

    // MARK: - Recent transcriptions (per-recording breakdown)

    private var recentRows: [RecordingPerformanceRow] {
        RecordingPerformanceBuilder.rows(from: filtered)
    }

    private func recentTranscriptions(_ rows: [RecordingPerformanceRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Recent Transcriptions")
            Text("Per-recording step timing — expand a row to see where the time went.")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(rows) { row in
                    RecentRecordingRow(row: row, colorScheme: colorScheme)
                }
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

    // MARK: - Hero (fastest model)

    private func heroCard(_ stat: TranscriptionStat) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Fastest Model", systemImage: "bolt.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Text("\(stat.sessions) \(stat.sessions == 1 ? "session" : "sessions")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(stat.model)
                    .font(.title3.weight(.semibold))

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(format: "%.1f×", stat.headlineSpeed))
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                    Text(stat.inferenceSpeedup != nil
                         ? "model speed, faster than real-time"
                         : "end-to-end, faster than real-time")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow {
                        LabeledContent("Avg. audio", value: Self.formatDuration(stat.avgAudio))
                        LabeledContent("Avg. processing", value: Self.formatDuration(stat.avgProcessing))
                    }
                    GridRow {
                        if stat.inferenceSpeedup != nil {
                            LabeledContent("End-to-end", value: String(format: "%.1f×", stat.speedup))
                        }
                        if let overhead = stat.avgOverhead {
                            LabeledContent("Load / overhead", value: "+\(Self.formatDuration(max(0, overhead)))")
                        }
                    }
                }
                .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: - Transcription leaderboard

    private func transcriptionLeaderboard(_ stats: [TranscriptionStat]) -> some View {
        let maxSpeed = stats.map(\.headlineSpeed).max() ?? 1
        let fastestModel = stats.max(by: { $0.headlineSpeed < $1.headlineSpeed })?.model
        let showBadges = stats.count > 1

        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Transcription Models")
            Table(stats, sortOrder: $txSort) {
                TableColumn("Model", value: \.model) { stat in
                    HStack(spacing: 6) {
                        Text(stat.model).lineLimit(2)
                        if showBadges && stat.model == fastestModel {
                            badge("FASTEST", accent: true)
                        }
                    }
                }
                TableColumn("Relative speed", value: \.headlineSpeed) { stat in
                    HStack(spacing: 8) {
                        Gauge(value: max(0, stat.headlineSpeed), in: 0...max(maxSpeed, 0.001)) {
                            EmptyView()
                        }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(.accentColor)
                        Text(String(format: "%.1f×", stat.headlineSpeed))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                TableColumn("Sessions", value: \.sessions) { stat in
                    Text("\(stat.sessions)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 70)
            }
            .scrollDisabled(true)
            .frame(height: tableHeight(stats.count))
        }
    }

    // MARK: - AI comparison

    private func aiComparison(_ stats: [AIStat]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("AI Analysis Models")
            Table(stats, sortOrder: $aiSort) {
                TableColumn("Model", value: \.model) { stat in
                    Text(stat.model).lineLimit(2)
                }
                TableColumn("Avg. analysis", value: \.avgTime) { stat in
                    Text(Self.formatDuration(stat.avgTime))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                TableColumn("Sessions", value: \.sessions) { stat in
                    Text("\(stat.sessions)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 70)
            }
            .scrollDisabled(true)
            .frame(height: tableHeight(stats.count))
        }
    }

    // MARK: - Small views

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: colorScheme))
    }

    private func badge(_ text: String, accent: Bool) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill((accent ? Color.accentColor : Color.secondary).opacity(0.18))
            )
            .foregroundStyle(accent ? Color.accentColor : Color.secondary)
            .accessibilityLabel("Fastest model")
    }

    /// Content-sized height so the (scroll-disabled) Table never fights the outer
    /// ScrollView. Header row + one row per model.
    private func tableHeight(_ rows: Int) -> CGFloat {
        CGFloat(max(rows, 1)) * 30 + 30
    }

    // MARK: - Aggregation

    private var filtered: [ModelPerformanceRecord] {
        guard let cutoff = range.cutoff else { return records }
        return records.filter { $0.date >= cutoff }
    }

    private var sortedTxStats: [TranscriptionStat] {
        TranscriptionStat.aggregate(filtered).sorted(using: txSort)
    }

    private var sortedAIStats: [AIStat] {
        AIStat.aggregate(filtered).sorted(using: aiSort)
    }

    // MARK: - Formatting

    /// Compact lifetime total: "0m", "45m", or "12h 34m".
    static func formatTotalDuration(_ s: TimeInterval) -> String {
        let totalMinutes = Int(s / 60)
        if totalMinutes >= 60 {
            return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
        }
        return "\(totalMinutes)m"
    }

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

// MARK: - Recent recording row

/// One expandable row in the "Recent Transcriptions" section: a collapsed summary
/// (title · date · ×realtime · total) that expands to a per-step timeline.
private struct RecentRecordingRow: View {
    let row: RecordingPerformanceRow
    let colorScheme: ColorScheme
    @State private var expanded = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if row.transcriptionModel != nil || row.audioDuration != nil {
                    Text(modelSubtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                ForEach(row.steps) { step in
                    stepRow(step)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 2)
        } label: {
            header
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(colorScheme == .dark ? 0.10 : 0.06))
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(row.label)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 6)
            if row.isSlowerThanUsual {
                Text("slower than usual")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.18)))
                    .foregroundStyle(.orange)
            }
            Text(headerContext)
                .font(.caption)
                .foregroundStyle(.secondary)
            speedBadge
            Text(ModelPerformanceView.formatDuration(row.total))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .trailing)
        }
    }

    /// Collapsed-header secondary text: date, plus audio length when transcription
    /// ran ("18 Jun · 10:50 audio") so the ×realtime/total read in context.
    private var headerContext: String {
        let date = Self.dateFormatter.string(from: row.date)
        if let audio = row.audioDuration, audio > 0 {
            return "\(date) · \(Self.audioLength(audio)) audio"
        }
        return date
    }

    /// Expanded model line: model name and audio length together.
    private var modelSubtitle: String {
        var parts: [String] = []
        if let model = row.transcriptionModel { parts.append(model) }
        if let audio = row.audioDuration, audio > 0 { parts.append("\(Self.audioLength(audio)) audio") }
        return parts.joined(separator: " · ")
    }

    /// Compact clock form of an audio length: "0:42", "10:50", or "1:02:30".
    private static func audioLength(_ s: TimeInterval) -> String {
        let total = Int(s.rounded())
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    @ViewBuilder
    private var speedBadge: some View {
        if let rt = row.transcriptionRealtime {
            HStack(spacing: 3) {
                switch row.speedTier {
                case .fast:
                    Image(systemName: "bolt.fill").foregroundStyle(.green)
                case .slow:
                    Image(systemName: "tortoise.fill").foregroundStyle(.orange)
                case .normal, .unknown:
                    EmptyView()
                }
                Text(String(format: "%.1f×", rt))
                    .font(.callout.monospacedDigit().weight(.semibold))
            }
            .help("Transcription speed relative to real-time (audio ÷ transcription time)")
        }
    }

    private func stepRow(_ step: RecordingPerformanceRow.Step) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Gauge(value: max(0, min(1, step.share))) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(Self.color(for: step.kind))
                .frame(width: 70)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(step.kind.title)
                        .font(.caption)
                    Spacer()
                    Text(ModelPerformanceView.formatDuration(step.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let caption = step.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private static func color(for kind: RecordingPerformanceRow.StepKind) -> Color {
        switch kind {
        case .finalize: .gray
        case .transcribe: .accentColor
        case .diarize: .purple
        case .ai: .teal
        case .vocab: .indigo
        case .title: .brown
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

    /// Ranking number: pure model inference when available, else end-to-end.
    var headlineSpeed: Double { inferenceSpeedup ?? speedup }

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

struct AIStat: Identifiable {
    let model: String
    let sessions: Int
    let avgTime: TimeInterval
    var id: String { model }

    static func aggregate(_ records: [ModelPerformanceRecord]) -> [AIStat] {
        let grouped = Dictionary(grouping: records.filter { $0.hasAI }) {
            $0.aiModel ?? "Unknown"
        }
        return grouped.map { model, recs -> AIStat in
            let times = recs.compactMap { $0.aiTime }
            let avg = times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count)
            return AIStat(model: model, sessions: recs.count, avgTime: avg)
        }
        .sorted { $0.sessions > $1.sessions }
    }
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
