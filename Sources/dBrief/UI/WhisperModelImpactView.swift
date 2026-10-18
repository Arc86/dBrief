import SwiftUI
import dBriefWire

struct WhisperModelImpactView: View {
    let modelID: String
    var identifySpeakers = false
    var physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory

    var body: some View {
        let entry = WhisperModelCatalog.entries[modelID]
        let total = entry.map { $0.runtimeGiB + (identifySpeakers ? 0.5 : 0) }
        let impact = WhisperModelImpact.evaluate(
            estimatedRuntimeBytes: total.map { UInt64($0 * 1_073_741_824) },
            physicalMemoryBytes: physicalMemoryBytes)
        VStack(alignment: .leading, spacing: 12) {
            if let total, let fraction = impact.fraction {
                HStack(spacing: 10) {
                    ProgressView(value: min(fraction, 1))
                        .tint(fraction <= 0.25 ? .green : fraction <= 0.5 ? .yellow : .orange)
                        .frame(width: 80)
                        .accessibilityLabel("Estimated share of installed RAM")
                        .accessibilityValue(Text("\(fraction * 100, specifier: "%.0f") percent"))
                    Group {
                        let installed = Double(physicalMemoryBytes) / 1_073_741_824
                        if identifySpeakers {
                            Text("~\(total, specifier: "%.1f") of \(installed, specifier: "%.0f") GiB RAM · includes speakers")
                        } else {
                            Text("~\(total, specifier: "%.1f") of \(installed, specifier: "%.0f") GiB RAM")
                        }
                    }
                        .uiFont(.caption).foregroundStyle(.secondary)
                }
                if fraction > 0.5 {
                    Label(impact.label, systemImage: "exclamationmark.triangle")
                        .uiFont(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("Memory estimate unavailable").uiFont(.caption).foregroundStyle(.secondary)
            }
            Group {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RAM is installed, not currently free. Model memory is an estimate, not download size or peak whole-app use.")
                    if identifySpeakers {
                        Text("Includes approximately 0.5 GiB for speaker identification.")
                    }
                    if let entry {
                        Text(entry.ratingMethod)
                        HStack {
                            Link("Rating source", destination: URL(string: entry.ratingEvidence)!)
                            Link("Core ML variants", destination: URL(string: entry.evidence)!)
                        }
                    }
                }
                .uiFont(.caption).foregroundStyle(.secondary)
                .padding(.top, 6)
            }
            .uiFont(.caption)
        }
    }

}
