import SwiftUI

/// Only surfaces profile scope when this page has overrides to explain.
/// Navigation selects an editor without activating the profile.
struct SettingsProfileScopeView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.viewerPalette) private var palette
    let fields: [SettingsProfileScope.Field]
    let editProfile: (UUID) -> Void
    @State private var showOverrides = false

    static func visibleOverrides(_ summaries: [SettingsProfileScope.Summary]) -> [SettingsProfileScope.Summary] {
        summaries.filter(\.isOverridden)
    }

    var body: some View {
        let scope = SettingsProfileScope(settings: settings, fields: fields)
        let overrides = Self.visibleOverrides(scope.summaries)
        if !overrides.isEmpty {
            SettingsNotice(Text("**\(scope.profile.name)** overrides \(overrides.count) setting\(overrides.count == 1 ? "" : "s") on this page.")) {
                Button("Show") { showOverrides.toggle() }
                    .buttonStyle(.settingsSecondary)
                    .popover(isPresented: $showOverrides, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(scope.isAutomatic
                                 ? "Selected automatically for now. Controls on this page edit app defaults."
                                 : "Your saved profile. Controls on this page edit app defaults.")
                                .uiFont(.system(size: 11.5))
                                .foregroundStyle(palette.secondary.color)
                            ForEach(overrides) { row in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.label)
                                        .uiFont(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(palette.heading.color)
                                    Text("App default: \(row.defaultValue)").lineLimit(2).help(row.defaultValue)
                                    Text("Profile: \(row.profileValue)").lineLimit(2).help(row.profileValue)
                                    if let note = row.note {
                                        Text(note).foregroundStyle(palette.secondary.color)
                                    }
                                }
                                .uiFont(.system(size: 11.5))
                                .foregroundStyle(palette.text.color)
                            }
                        }
                        .padding(14)
                        .frame(width: 300, alignment: .leading)
                        .presentationBackground(palette.surface.color)
                    }
                Button("Edit profile") { editProfile(scope.profile.id) }
                    .buttonStyle(.settingsSecondary)
            }
        }
    }
}
