import SwiftUI

/// Benchmark settings page (Power User Mode): hosts the model performance panel,
/// which aggregates transcription/AI timings across every recording. The data is
/// global, not tied to a single transcript, so it lives here rather than in the
/// transcript window toolbar.
struct SettingsBenchmarkTab: View {
    @Environment(AppContext.self) private var context

    var body: some View {
        ModelPerformanceView(store: context.modelPerformanceStore)
    }
}
