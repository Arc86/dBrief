import SwiftUI

/// Only surfaces profile scope when this page has overrides to explain.
/// Navigation selects an editor without activating the profile.
struct SettingsProfileScopeView: View {
    @Environment(AppSettings.self) private var settings
    let fields: [SettingsProfileScope.Field]
    let editProfile: (UUID) -> Void
    @State private var showOverrides = false

    var body: some View {
        let scope = SettingsProfileScope(settings: settings, fields: fields)
        let overrides = scope.summaries.filter(\.isOverridden)
        if !overrides.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    DisclosureGroup(isExpanded: $showOverrides) {
                        EmptyView()
                    } label: {
                        Text("\(scope.profile.name) overrides \(overrides.count) setting\(overrides.count == 1 ? "" : "s") on this page")
                    }
                    Spacer()
                    Button("Edit profile…") { editProfile(scope.profile.id) }
                }
                if showOverrides {
                    Text(scope.isAutomatic
                         ? "This profile is temporarily selected automatically. Controls below edit app defaults."
                         : "This is your saved profile. Controls below edit app defaults.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(overrides) { row in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.label).fontWeight(.medium)
                                    Text("App default: \(row.defaultValue)").lineLimit(2).help(row.defaultValue)
                                    Text("Profile setting: \(row.profileValue)").lineLimit(2).help(row.profileValue)
                                    if let note = row.note {
                                        Text(note).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .font(.caption)
                    }
                    .frame(maxHeight: 170)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
        }
    }
}
