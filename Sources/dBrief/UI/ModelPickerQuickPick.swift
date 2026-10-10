import SwiftUI

/// "Quick pick": up to three suggestion tiles plus the "Currently using" row.
struct ModelPickerQuickPick: View {
    let suggestions: [ModelSuggestion]
    let currentID: String
    let cached: [String: Bool]
    let language: String
    let installedRAMGiB: Double
    let modernApple: Bool
    @Binding var selectedID: String
    let showAllModels: () -> Void
    @FocusState private var focusedID: String?
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status

    private var languageName: String { ModelSuggestions.languageName(language) ?? "Auto-detect" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Suggested for \(Text(languageName).bold()) on this \(Int(installedRAMGiB.rounded())) GB Mac")
                .uiFont(.caption).foregroundStyle(palette.secondary.color)
            if suggestions.isEmpty {
                VStack(spacing: 10) {
                    Text("No suggestions for \(languageName) on this Mac")
                        .foregroundStyle(palette.secondary.color)
                    Button("Show all models", action: showAllModels).buttonStyle(.settingsSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(suggestions, id: \.modelID) { tile($0) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Suggested models")
            }
            if !suggestions.contains(where: { $0.modelID == currentID }) { currentRow }
        }
        .onAppear {
            if suggestions.contains(where: { $0.modelID == selectedID }) { focusedID = selectedID }
        }
    }

    private func tile(_ suggestion: ModelSuggestion) -> some View {
        let id = suggestion.modelID
        let selected = id == selectedID
        let profile = LocalTranscriptionChoice.profile(id, modernApple: modernApple)
        let ram = profile?.runtimeGiB.map { String(format: "%.1f GB RAM", $0) } ?? ""
        let download = cached[id] == true ? "✓ Downloaded" : "Not downloaded"
        return VStack(alignment: .leading, spacing: 7) {
            Label(suggestion.intent.title.uppercased(), systemImage: suggestion.intent.symbol)
                .uiFont(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.secondary.color)
            Text(LocalTranscriptionChoice.shortTitle(id))
                .uiFont(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.heading.color)
            ModelRatingMeter(kind: .speed, value: profile?.speed)
            ModelRatingMeter(kind: .accuracy, value: profile?.accuracy)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile?.languageLabel ?? "")
                Text("\(ram) · \(Text(download).foregroundStyle(cached[id] == true ? status.success.color : palette.secondary.color))")
            }
            .uiFont(.system(size: 11)).foregroundStyle(palette.secondary.color)
            Text(suggestion.reason)
                .uiFont(.system(size: 11)).foregroundStyle(palette.text.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(selected ? palette.selected.color : palette.surface.color,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? palette.primary.color : palette.divider.color, lineWidth: selected ? 2 : 1)
        }
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(palette.primary.color)
                    .padding(9)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { selectedID = id; focusedID = id }
        .focusable()
        // Arrow keys move selection with focus, so the selected border already marks focus.
        .focusEffectDisabled()
        .focused($focusedID, equals: id)
        .onKeyPress(.leftArrow) { step(-1, from: id); return .handled }
        .onKeyPress(.rightArrow) { step(1, from: id); return .handled }
        .onKeyPress(.space) { selectedID = id; return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(suggestion.intent.title): \(LocalTranscriptionChoice.shortTitle(id))")
        .accessibilityValue("\(profile?.languageLabel ?? ""), \(ram), \(cached[id] == true ? "downloaded" : "not downloaded")")
        .accessibilityHint(suggestion.reason)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selectedID = id }
    }

    private var currentRow: some View {
        let selected = selectedID == currentID
        return HStack(spacing: 8) {
            Circle()
                .fill(selected ? palette.primary.color : palette.secondary.color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text("Currently using \(Text(LocalTranscriptionChoice.shortTitle(currentID)).bold())")
                .foregroundStyle(palette.text.color)
            Spacer()
            if !selected {
                Button("Keep") { selectedID = currentID }
                    .buttonStyle(.typographyBorderless)
                    .accessibilityLabel("Keep \(LocalTranscriptionChoice.shortTitle(currentID))")
            }
        }
        .uiFont(.system(size: 12))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(selected ? palette.selected.color : palette.surface.color,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(palette.primary.color, lineWidth: 2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func step(_ offset: Int, from id: String) {
        guard let next = SettingsListNavigation.step(offset, in: suggestions.map(\.modelID), from: id) else { return }
        selectedID = next
        focusedID = next
    }
}
