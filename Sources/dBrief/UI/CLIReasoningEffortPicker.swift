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
        case .cliDefault: String(localized: "CLI default")
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        case .xhigh: String(localized: "Extra high")
        case .max: String(localized: "Maximum")
        }
        return effort == recommendation ? String(localized: "\(name) · Recommended") : name
    }
}
