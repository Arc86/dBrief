import SwiftUI

/// Rounded glass section for settings, matching modern macOS style.
struct SettingsSection<Content: View>: View {
    let title: String
    var searchSection: SettingsSectionID? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let searchSection {
                    SettingsSearchHeading(LocalizedStringKey(title), section: searchSection)
                } else {
                    Text(title)
                }
            }
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .secondarySystemFill))
            )
        }
    }
}
