import SwiftUI

struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
    }
}

/// Switch toggle style that renders the switch at small control size
/// while letting the label get proper Form row styling via LabeledContent.
struct SmallSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        LabeledContent {
            Toggle(isOn: configuration.$isOn) {}
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        } label: {
            configuration.label
        }
    }
}

extension ToggleStyle where Self == SmallSwitchToggleStyle {
    static var smallSwitch: SmallSwitchToggleStyle { .init() }
}
