import SwiftUI

/// Shared labels for independent calendar and analysis CLI effort settings.
struct CLIReasoningEffortPicker: View {
    let title: String
    @Binding var selection: CLIReasoningEffort
    let recommendation: CLIReasoningEffort

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(CLIReasoningEffort.allCases, id: \.self) { effort in
                Text(label(for: effort)).tag(effort)
            }
        }
        .pickerStyle(.menu)
    }

    private func label(for effort: CLIReasoningEffort) -> String {
        let name: String = switch effort {
        case .cliDefault: "CLI default"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        case .max: "Maximum"
        }
        return effort == recommendation ? "\(name) · Recommended" : name
    }
}
